import CryptoKit
import Foundation
import os.log

// MARK: – Pluggable backup destination

/// Conform to this protocol to wire in a concrete backup backend (e.g. AWS S3).
///
/// The upload / list / delete methods are `async` so implementations can
/// perform real network I/O without blocking the main thread.
protocol BackupDestination: AnyObject {
    /// Human-readable label for the UI (e.g. "S3 – my-audio-bucket").
    var displayName: String { get }

    /// Upload the file at *localPath* to the remote store at key *remotePath*.
    func upload(localPath: String, remotePath: String) async throws

    /// List objects whose key starts with *prefix*.
    func list(prefix: String) async throws -> [RemoteObject]

    /// Delete the remote object identified by *key*.
    func delete(key: String) async throws

    /// Download the remote object identified by *key*.
    func download(key: String) async throws -> Data
}

// MARK: – Remote object descriptor

/// Lightweight metadata for an object already stored remotely.
struct RemoteObject: Identifiable {
    let id:           String     /// full remote key
    let size:         UInt64     /// bytes
    let lastModified: Date
}

// MARK: – Log types

/// Outcome of a single upload attempt.
enum BackupStatus {
    case success
    case failed(String)
}

/// One entry in the per-session upload log.
struct BackupLogEntry: Identifiable {
    let id:     UUID = UUID()
    let path:   String           /// local file that was (or was not) uploaded
    let remote: String           /// target key in the remote store
    let status: BackupStatus
}

// MARK: – Backup Manifest

/// Metadata manifest uploaded with each backup to enable restore workflow
struct BackupManifest: Codable {
    let backupId: String
    let userId: String
    let backupName: String
    let scopeDescription: String
    let createdAt: Date
    let pluginCount: Int
    let projectCount: Int
    let sessionCount: Int
    let bounceCount: Int
    let totalSizeBytes: UInt64
    let appVersion: String
    let plugins: [PluginBackupItem]
    let projects: [ProjectBackupItem]
    let bounces: [BounceBackupItem]

    // Backwards-compatible decoding for manifests without bounces
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        backupId = try container.decode(String.self, forKey: .backupId)
        userId = try container.decode(String.self, forKey: .userId)
        backupName = try container.decode(String.self, forKey: .backupName)
        scopeDescription = try container.decode(String.self, forKey: .scopeDescription)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        pluginCount = try container.decode(Int.self, forKey: .pluginCount)
        projectCount = try container.decode(Int.self, forKey: .projectCount)
        sessionCount = try container.decode(Int.self, forKey: .sessionCount)
        bounceCount = try container.decodeIfPresent(Int.self, forKey: .bounceCount) ?? 0
        totalSizeBytes = try container.decode(UInt64.self, forKey: .totalSizeBytes)
        appVersion = try container.decode(String.self, forKey: .appVersion)
        plugins = try container.decode([PluginBackupItem].self, forKey: .plugins)
        projects = try container.decode([ProjectBackupItem].self, forKey: .projects)
        bounces = try container.decodeIfPresent([BounceBackupItem].self, forKey: .bounces) ?? []
    }

    init(backupId: String, userId: String, backupName: String, scopeDescription: String,
         createdAt: Date, pluginCount: Int, projectCount: Int, sessionCount: Int,
         bounceCount: Int = 0, totalSizeBytes: UInt64, appVersion: String,
         plugins: [PluginBackupItem], projects: [ProjectBackupItem],
         bounces: [BounceBackupItem] = []) {
        self.backupId = backupId
        self.userId = userId
        self.backupName = backupName
        self.scopeDescription = scopeDescription
        self.createdAt = createdAt
        self.pluginCount = pluginCount
        self.projectCount = projectCount
        self.sessionCount = sessionCount
        self.bounceCount = bounceCount
        self.totalSizeBytes = totalSizeBytes
        self.appVersion = appVersion
        self.plugins = plugins
        self.projects = projects
        self.bounces = bounces
    }
}

/// Individual plugin in a backup
struct PluginBackupItem: Codable {
    let name: String
    let format: String
    let originalPath: String    // Where it was on the source machine
    let s3Key: String           // Where it is in S3
    let bundleId: String?
    let version: String?
    let manufacturer: String?
    let checksum: String?       // SHA-256 hex digest
}

/// Individual project in a backup
struct ProjectBackupItem: Codable {
    let projectName: String
    let format: String              // "Ableton Live", "Logic Pro", "Pro Tools"
    let originalPath: String        // Full path to project folder
    let s3Key: String              // S3 path to uploaded zip
    let lastModified: Date         // Folder modification timestamp
    let totalSizeBytes: UInt64     // Complete folder size
    let sessionCount: Int          // Number of session files
    let sessions: [SessionBackupItem]
    let structureHash: String?     // SHA-256 of sorted relative file paths (for version detection)
    let contentHash: String?       // SHA-256 of the zip file (for exact duplicate detection)
}

/// Individual session file in a backup
struct SessionBackupItem: Codable {
    let name: String
    let format: String
    let originalPath: String
    let s3Key: String
}

/// Individual bounce file in a backup
struct BounceBackupItem: Codable {
    let fileName: String
    let format: String
    let s3Key: String
    let fileSizeBytes: Int
    let durationSeconds: Double?
}

/// Backup list item for UI display
struct BackupListItem: Identifiable, Hashable {
    let id: String              // backupId
    let name: String            // backup name
    let createdAt: Date
    let pluginCount: Int
    let projectCount: Int
    let totalSize: UInt64
    let s3Prefix: String        // For downloading

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: createdAt)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: BackupListItem, rhs: BackupListItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: – Service

/// Observable service that drives plugin- and session-backup workflows.
///
/// Usage:
///   1. Call `configure(destination:)` to attach an S3 (or other) backend.
///   2. Call `backupPlugins(_:)` or `backupSession(_:)` to start a transfer.
///
/// All `@Published` state is mutated on the main actor; the destination's
/// `upload` call suspends off-main automatically via `await`.
@MainActor
class BackupService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Backup")

    // MARK: – Published state

    @Published private(set) var destination:    BackupDestination? = nil
    @Published private(set) var isUploading:    Bool               = false
    @Published private(set) var uploadProgress: Double             = 0      /// 0 … 1
    @Published var lastError:      String?            = nil
    @Published private(set) var uploadLog:      [BackupLogEntry]   = []
    @Published private(set) var currentBackupId: String?           = nil
    @Published private(set) var currentBackupName: String?          = nil    /// Name of in-progress backup (for sidebar display)
    @Published private(set) var lastSuccessfulBackup: String?      = nil    /// Backup name of last successful upload
    @Published private(set) var availableBackups: [BackupListItem] = []     /// List of backups in S3
    @Published private(set) var isLoadingBackups: Bool             = false
    @Published private(set) var pluginBackupIndex: [String: [String]] = [:] /// pluginKey -> [backupId]

    /// Current authenticated user ID (set by authentication service)
    var userId: String?

    /// Callback invoked with the manifest after a successful backup upload.
    /// Set by the app layer to sync manifests to the backend.
    var onManifestUploaded: ((BackupManifest) -> Void)?

    // MARK: – Computed Properties

    /// Total storage used across all backups
    var totalStorageUsed: UInt64 {
        availableBackups.reduce(0) { $0 + $1.totalSize }
    }

    /// Formatted total storage for display
    var formattedTotalStorage: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalStorageUsed), countStyle: .file)
    }

    // MARK: – Configuration

    /// Attach (or detach when `nil`) the active backup backend.
    func configure(destination: BackupDestination?) {
        self.destination = destination
        lastError        = nil
    }

    // MARK: – Plugin backup

    /// Upload every bundle in *plugins* to the destination using proper S3 path structure.
    /// Each plugin is zipped individually and uploaded to its own S3 key.
    /// A metadata.json manifest is created to track original paths for restore.
    func backupPlugins(_ plugins: [AudioPlugin], backupName: String = "Plugin Backup", scopeDescription: String = "") async {
        guard let dest = destination else {
            lastError = "No backup destination configured."
            return
        }

        guard let userId = userId else {
            lastError = "User not authenticated. Please log in to backup plugins."
            return
        }

        isUploading    = true
        uploadProgress = 0
        lastError      = nil
        uploadLog      = []
        currentBackupName = backupName

        // Generate unique backup ID for this session
        let backupId = BackupPath.generateBackupId()
        currentBackupId = backupId

        // Track successfully uploaded plugins for metadata
        var uploadedPlugins: [(plugin: AudioPlugin, s3Key: String, checksum: String?)] = []

        let total = max(plugins.count, 1)
        for (i, plugin) in plugins.enumerated() {
            let checksum = Self.sha256Checksum(forPluginAt: plugin.path)

            let remote = BackupPath.pluginKey(
                userId: userId,
                backupId: backupId,
                checksum: checksum ?? UUID().uuidString,
                pluginName: plugin.name
            )

            do {
                try await dest.upload(localPath: plugin.path, remotePath: remote)
                uploadLog.append(BackupLogEntry(path: plugin.path, remote: remote, status: .success))
                uploadedPlugins.append((plugin, remote, checksum))
            } catch {
                uploadLog.append(BackupLogEntry(path: plugin.path, remote: remote, status: .failed(error.localizedDescription)))
                lastError = error.localizedDescription
            }
            uploadProgress = Double(i + 1) / Double(total)
        }

        // Upload metadata.json manifest
        if !uploadedPlugins.isEmpty {
            await uploadMetadata(
                userId: userId,
                backupId: backupId,
                backupName: backupName,
                scopeDescription: scopeDescription,
                uploadedPlugins: uploadedPlugins,
                destination: dest
            )
        }

        // Set success message
        if uploadedPlugins.count == plugins.count {
            lastSuccessfulBackup = backupName
            lastError = nil // Clear any previous errors
        }

        isUploading = false
        currentBackupId = nil
        currentBackupName = nil
    }

    // MARK: – Unified backup

    /// Backup plugins, projects, and bounces in a single operation.
    /// Progress is split dynamically across non-empty phases.
    func backupAll(
        plugins: [AudioPlugin],
        projects: [SessionProject],
        bounces: [Bounce] = [],
        backupName: String = "Complete Backup",
        scopeDescription: String = ""
    ) async {
        guard let dest = destination else {
            lastError = "No backup destination configured."
            return
        }

        guard let userId = userId else {
            lastError = "User not authenticated. Please log in to backup."
            return
        }

        isUploading = true
        uploadProgress = 0
        lastError = nil
        uploadLog = []
        currentBackupName = backupName

        // Generate unique backup ID for this session
        let backupId = BackupPath.generateBackupId()
        currentBackupId = backupId

        // Track successfully uploaded items
        var uploadedPlugins: [(plugin: AudioPlugin, s3Key: String, checksum: String?)] = []
        var uploadedProjects: [(project: SessionProject, path: String, s3Key: String, size: UInt64, modDate: Date, structureHash: String?)] = []
        var uploadedBounces: [(bounce: Bounce, s3Key: String)] = []

        // Calculate progress splits based on which phases are non-empty
        let phaseCount = [!plugins.isEmpty, !projects.isEmpty, !bounces.isEmpty].filter { $0 }.count
        let phaseWeight = phaseCount > 0 ? 1.0 / Double(phaseCount) : 1.0
        var currentPhase = 0

        // Phase 1: Upload plugins
        if !plugins.isEmpty {
            let offset = Double(currentPhase) * phaseWeight
            let total = max(plugins.count, 1)
            for (i, plugin) in plugins.enumerated() {
                let checksum = Self.sha256Checksum(forPluginAt: plugin.path)
                let remote = BackupPath.pluginKey(
                    userId: userId,
                    backupId: backupId,
                    checksum: checksum ?? UUID().uuidString,
                    pluginName: plugin.name
                )

                do {
                    try await dest.upload(localPath: plugin.path, remotePath: remote)
                    uploadLog.append(BackupLogEntry(path: plugin.path, remote: remote, status: .success))
                    uploadedPlugins.append((plugin, remote, checksum))
                } catch {
                    let detail = Self.detailedErrorMessage(error)
                    uploadLog.append(BackupLogEntry(path: plugin.path, remote: remote, status: .failed(detail)))
                    lastError = detail
                }
                uploadProgress = offset + phaseWeight * Double(i + 1) / Double(total)
            }
            currentPhase += 1
        }

        // Phase 2: Upload projects
        if !projects.isEmpty {
            let offset = Double(currentPhase) * phaseWeight
            uploadedProjects = await backupProjects(
                projects,
                userId: userId,
                backupId: backupId,
                destination: dest,
                progressOffset: offset,
                progressScale: phaseWeight
            )
            currentPhase += 1
        }

        // Phase 3: Upload bounces
        if !bounces.isEmpty {
            let offset = Double(currentPhase) * phaseWeight
            uploadedBounces = await backupBounces(
                bounces,
                userId: userId,
                backupId: backupId,
                destination: dest,
                progressOffset: offset,
                progressScale: phaseWeight
            )
        }

        // Upload unified metadata
        if !uploadedPlugins.isEmpty || !uploadedProjects.isEmpty || !uploadedBounces.isEmpty {
            await uploadUnifiedMetadata(
                userId: userId,
                backupId: backupId,
                backupName: backupName,
                scopeDescription: scopeDescription,
                uploadedPlugins: uploadedPlugins,
                uploadedProjects: uploadedProjects,
                uploadedBounces: uploadedBounces,
                destination: dest
            )
        }

        // Set success message
        let allPluginsOk = uploadedPlugins.count == plugins.count
        let allProjectsOk = uploadedProjects.count == projects.count
        let allBouncesOk = uploadedBounces.count == bounces.count
        if allPluginsOk && allProjectsOk && allBouncesOk {
            lastSuccessfulBackup = backupName
            lastError = nil
        }

        isUploading = false
        currentBackupId = nil
        currentBackupName = nil
    }

    // MARK: – Project backup

    /// Upload project folders to the destination
    /// Each project is zipped and uploaded individually
    /// Returns metadata for uploaded projects
    func backupProjects(
        _ projects: [SessionProject],
        userId: String,
        backupId: String,
        destination: BackupDestination,
        progressOffset: Double = 0.5,
        progressScale: Double = 0.5
    ) async -> [(project: SessionProject, path: String, s3Key: String, size: UInt64, modDate: Date, structureHash: String?)] {
        var uploadedProjects: [(SessionProject, String, String, UInt64, Date, String?)] = []

        let total = max(projects.count, 1)
        for (i, project) in projects.enumerated() {
            // Get first session to extract project folder path
            guard let firstSession = project.sessions.first else {
                logger.warning("Skipping project '\(project.name)' - no sessions found")
                continue
            }

            // Extract project folder path
            let projectPath = FileSystemHelpers.getProjectFolderPath(from: firstSession)

            // Verify path exists
            guard FileManager.default.fileExists(atPath: projectPath) else {
                logger.warning("Skipping project '\(project.name)' - path not found: \(projectPath)")
                uploadLog.append(BackupLogEntry(
                    path: projectPath,
                    remote: "",
                    status: .failed("Path not found")
                ))
                continue
            }

            // Calculate folder size and modification date
            let folderSize = FileSystemHelpers.calculateDirectorySize(projectPath)
            guard let modDate = FileSystemHelpers.getDirectoryModificationDate(projectPath) else {
                logger.warning("Skipping project '\(project.name)' - cannot read modification date")
                continue
            }

            // Compute structure hash for version tracking
            let structureHash = FileSystemHelpers.computeStructureHash(projectPath)

            // Generate S3 key
            let s3Key = BackupPath.projectZipKey(
                userId: userId,
                backupId: backupId,
                projectName: project.name
            )

            do {
                // Upload entire project folder (S3BackupDestination will zip it)
                try await destination.upload(localPath: projectPath, remotePath: s3Key)
                uploadLog.append(BackupLogEntry(path: projectPath, remote: s3Key, status: .success))
                uploadedProjects.append((project, projectPath, s3Key, folderSize, modDate, structureHash))
            } catch {
                let detail = Self.detailedErrorMessage(error)
                uploadLog.append(BackupLogEntry(path: projectPath, remote: s3Key, status: .failed(detail)))
                lastError = "Project upload failed: \(detail)"
                logger.error("Failed to upload project '\(project.name)': \(error)")
            }

            // Update progress
            uploadProgress = progressOffset + (progressScale * Double(i + 1) / Double(total))
        }

        return uploadedProjects
    }

    // MARK: – Bounce backup

    /// Upload bounce files to the destination.
    /// Returns metadata for uploaded bounces.
    func backupBounces(
        _ bounces: [Bounce],
        userId: String,
        backupId: String,
        destination: BackupDestination,
        progressOffset: Double = 0.0,
        progressScale: Double = 1.0
    ) async -> [(bounce: Bounce, s3Key: String)] {
        var uploadedBounces: [(Bounce, String)] = []

        let total = max(bounces.count, 1)
        for (i, bounce) in bounces.enumerated() {
            guard bounce.isLocallyAvailable else {
                logger.warning("Skipping bounce '\(bounce.fileName)' - not locally available")
                uploadLog.append(BackupLogEntry(
                    path: bounce.filePath,
                    remote: "",
                    status: .failed("File not locally available")
                ))
                continue
            }

            let s3Key = BackupPath.bounceKey(
                userId: userId,
                backupId: backupId,
                format: bounce.format,
                fileName: bounce.fileName
            )

            do {
                try await destination.upload(localPath: bounce.filePath, remotePath: s3Key)
                uploadLog.append(BackupLogEntry(path: bounce.filePath, remote: s3Key, status: .success))
                uploadedBounces.append((bounce, s3Key))
            } catch {
                let detail = Self.detailedErrorMessage(error)
                uploadLog.append(BackupLogEntry(path: bounce.filePath, remote: s3Key, status: .failed(detail)))
                lastError = "Bounce upload failed: \(detail)"
                logger.error("Failed to upload bounce '\(bounce.fileName)': \(error)")
            }

            uploadProgress = progressOffset + (progressScale * Double(i + 1) / Double(total))
        }

        return uploadedBounces
    }

    // MARK: – Orphaned backup cleanup

    /// Clean up orphaned backups that have objects but no metadata.json.
    /// Called as a side-effect of loadAvailableBackups().
    func cleanupOrphanedBackups() async {
        guard let dest = destination, let userId = userId else { return }

        do {
            let prefix = BackupPath.userBackupsPrefix(userId: userId)
            let objects = try await dest.list(prefix: prefix)

            // Group objects by backup ID (3rd path component: users/{uid}/backups/{backupId}/...)
            var objectsByBackupId: [String: [RemoteObject]] = [:]
            for obj in objects {
                let components = obj.id.split(separator: "/")
                guard components.count >= 4 else { continue }
                let backupId = String(components[3])
                objectsByBackupId[backupId, default: []].append(obj)
            }

            // Find backup IDs with objects but no metadata.json
            for (backupId, backupObjects) in objectsByBackupId {
                let hasMetadata = backupObjects.contains { $0.id.hasSuffix("metadata.json") }
                if !hasMetadata {
                    logger.warning("Found orphaned backup \(backupId) with \(backupObjects.count) objects — cleaning up")
                    for obj in backupObjects {
                        do {
                            try await dest.delete(key: obj.id)
                            logger.info("Deleted orphaned object: \(obj.id)")
                        } catch {
                            logger.error("Failed to delete orphaned object \(obj.id): \(error)")
                        }
                    }
                }
            }
        } catch {
            logger.error("Failed to list objects for orphan cleanup: \(error)")
        }
    }

    // MARK: – Error helpers

    /// Extract detailed error message including HTTP status and S3 error body when available.
    static func detailedErrorMessage(_ error: Error) -> String {
        if let backupError = error as? BackupError {
            return backupError.errorDescription ?? error.localizedDescription
        }
        return error.localizedDescription
    }

    /// Calculate the size of a plugin bundle or file
    private func calculatePluginSize(_ path: String) -> UInt64 {
        let fileManager = FileManager.default
        var totalSize: UInt64 = 0
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(atPath: path) else { return 0 }
            for case let file as String in enumerator {
                let filePath = (path as NSString).appendingPathComponent(file)
                if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                   let fileSize = attrs[.size] as? UInt64,
                   attrs[.type] as? FileAttributeType == .typeRegular {
                    totalSize += fileSize
                }
            }
        } else {
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                totalSize = size
            }
        }
        return totalSize
    }

    /// Compute SHA-256 of a plugin at the given path.
    /// For bundles, hashes the main executable binary; for single files, hashes the file directly.
    /// Returns the hex digest or nil if the file cannot be read.
    static func sha256Checksum(forPluginAt path: String) -> String? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }

        let fileToHash: String
        if isDirectory.boolValue {
            // Bundle: hash the main executable inside Contents/MacOS/
            let macosDir = (path as NSString).appendingPathComponent("Contents/MacOS")
            if let contents = try? fm.contentsOfDirectory(atPath: macosDir),
               let binary = contents.first(where: { !$0.hasPrefix(".") }) {
                fileToHash = (macosDir as NSString).appendingPathComponent(binary)
            } else {
                // Fallback: hash the Info.plist
                let plist = (path as NSString).appendingPathComponent("Contents/Info.plist")
                guard fm.fileExists(atPath: plist) else { return nil }
                fileToHash = plist
            }
        } else {
            fileToHash = path
        }

        guard let data = fm.contents(atPath: fileToHash) else { return nil }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Upload metadata.json manifest for this backup
    private func uploadMetadata(
        userId: String,
        backupId: String,
        backupName: String,
        scopeDescription: String,
        uploadedPlugins: [(plugin: AudioPlugin, s3Key: String, checksum: String?)],
        destination: BackupDestination
    ) async {
        // Create metadata
        let pluginItems = uploadedPlugins.map { item in
            PluginBackupItem(
                name: item.plugin.name,
                format: item.plugin.format.rawValue,
                originalPath: item.plugin.path,
                s3Key: item.s3Key,
                bundleId: item.plugin.bundleID,
                version: item.plugin.version,
                manufacturer: item.plugin.manufacturer,
                checksum: item.checksum
            )
        }

        let totalSize = uploadedPlugins.reduce(UInt64(0)) { total, item in
            total + calculatePluginSize(item.plugin.path)
        }

        let metadata = BackupManifest(
            backupId: backupId,
            userId: userId,
            backupName: backupName,
            scopeDescription: scopeDescription,
            createdAt: Date(),
            pluginCount: uploadedPlugins.count,
            projectCount: 0,
            sessionCount: 0,
            totalSizeBytes: totalSize,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            plugins: pluginItems,
            projects: []
        )

        // Serialize to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(metadata) else {
            logger.error("Failed to encode metadata")
            return
        }

        // Write to temp file
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-metadata.json")

        do {
            try jsonData.write(to: tempFile)

            // Upload to S3
            let metadataKey = BackupPath.metadataKey(userId: userId, backupId: backupId)
            try await destination.upload(localPath: tempFile.path, remotePath: metadataKey)

            uploadLog.append(BackupLogEntry(
                path: tempFile.path,
                remote: metadataKey,
                status: .success
            ))

            // Sync manifest to backend
            onManifestUploaded?(metadata)

            // Cleanup
            try? FileManager.default.removeItem(at: tempFile)
        } catch {
            logger.error("Failed to upload metadata: \(error)")
            lastError = "Metadata upload failed: \(error.localizedDescription)"
        }
    }

    /// Upload unified metadata.json manifest including plugins, projects, and bounces
    private func uploadUnifiedMetadata(
        userId: String,
        backupId: String,
        backupName: String,
        scopeDescription: String,
        uploadedPlugins: [(plugin: AudioPlugin, s3Key: String, checksum: String?)],
        uploadedProjects: [(project: SessionProject, path: String, s3Key: String, size: UInt64, modDate: Date, structureHash: String?)],
        uploadedBounces: [(bounce: Bounce, s3Key: String)] = [],
        destination: BackupDestination
    ) async {
        // Build plugin items
        let pluginItems = uploadedPlugins.map { item in
            PluginBackupItem(
                name: item.plugin.name,
                format: item.plugin.format.rawValue,
                originalPath: item.plugin.path,
                s3Key: item.s3Key,
                bundleId: item.plugin.bundleID,
                version: item.plugin.version,
                manufacturer: item.plugin.manufacturer,
                checksum: item.checksum
            )
        }

        // Build project items
        let projectItems = uploadedProjects.map { item in
            let (project, path, s3Key, size, modDate, structureHash) = item

            // Build session items for this project
            let sessionItems = project.sessions.map { session in
                SessionBackupItem(
                    name: session.name,
                    format: session.format.rawValue,
                    originalPath: session.path,
                    s3Key: "" // Projects are uploaded as complete zips, not individual sessions
                )
            }

            // Determine DAW format string
            let formatString: String
            if let firstSession = project.sessions.first {
                switch firstSession.format {
                case .ableton:
                    formatString = "Ableton Live"
                case .logic:
                    formatString = "Logic Pro"
                case .proTools:
                    formatString = "Pro Tools"
                }
            } else {
                formatString = "Unknown"
            }

            return ProjectBackupItem(
                projectName: project.name,
                format: formatString,
                originalPath: path,
                s3Key: s3Key,
                lastModified: modDate,
                totalSizeBytes: size,
                sessionCount: project.sessions.count,
                sessions: sessionItems,
                structureHash: structureHash,
                contentHash: nil  // Zip is created and cleaned up during upload; content hash requires pipeline changes
            )
        }

        // Build bounce items
        let bounceItems = uploadedBounces.map { item in
            BounceBackupItem(
                fileName: item.bounce.fileName,
                format: item.bounce.format,
                s3Key: item.s3Key,
                fileSizeBytes: item.bounce.fileSizeBytes,
                durationSeconds: item.bounce.durationSeconds
            )
        }

        // Calculate total sizes
        let pluginSize = uploadedPlugins.reduce(UInt64(0)) { total, item in
            total + calculatePluginSize(item.plugin.path)
        }
        let projectSize = uploadedProjects.reduce(UInt64(0)) { total, item in
            total + item.size
        }
        let bounceSize = uploadedBounces.reduce(UInt64(0)) { total, item in
            total + UInt64(item.bounce.fileSizeBytes)
        }
        let totalSize = pluginSize + projectSize + bounceSize

        // Calculate total session count
        let sessionCount = uploadedProjects.reduce(0) { total, item in
            total + item.project.sessions.count
        }

        let metadata = BackupManifest(
            backupId: backupId,
            userId: userId,
            backupName: backupName,
            scopeDescription: scopeDescription,
            createdAt: Date(),
            pluginCount: uploadedPlugins.count,
            projectCount: uploadedProjects.count,
            sessionCount: sessionCount,
            bounceCount: uploadedBounces.count,
            totalSizeBytes: totalSize,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
            plugins: pluginItems,
            projects: projectItems,
            bounces: bounceItems
        )

        // Serialize to JSON
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let jsonData = try? encoder.encode(metadata) else {
            logger.error("Failed to encode unified metadata")
            return
        }

        // Write to temp file
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-metadata.json")

        do {
            try jsonData.write(to: tempFile)

            // Upload to S3
            let metadataKey = BackupPath.metadataKey(userId: userId, backupId: backupId)
            try await destination.upload(localPath: tempFile.path, remotePath: metadataKey)

            uploadLog.append(BackupLogEntry(
                path: tempFile.path,
                remote: metadataKey,
                status: .success
            ))

            // Sync manifest to backend
            onManifestUploaded?(metadata)

            // Cleanup
            try? FileManager.default.removeItem(at: tempFile)
        } catch {
            logger.error("Failed to upload unified metadata: \(error)")
            lastError = "Metadata upload failed: \(error.localizedDescription)"
        }
    }

    /// Download and parse metadata.json from S3
    /// Returns nil on failure to allow graceful degradation
    private func downloadAndParseMetadata(key: String, destination: BackupDestination) async -> BackupManifest? {
        do {
            let data = try await destination.download(key: key)

            let decoder = FlexibleISO8601.makeAPIDecoder()
            let manifest = try decoder.decode(BackupManifest.self, from: data)
            return manifest
        } catch {
            logger.warning("Failed to download/parse metadata from \(key): \(error)")
            return nil
        }
    }

    // MARK: – Session backup

    /// Upload a single session file to the destination.
    func backupSession(_ session: AudioSession) async {
        guard let dest = destination else {
            lastError = "No backup destination configured."
            return
        }
        isUploading    = true
        uploadProgress = 0
        lastError      = nil

        let ext: String
        switch session.format {
        case .ableton:  ext = ".als"
        case .logic:    ext = ".logicx"
        case .proTools: ext = ".ptx"
        }
        let remote = "sessions/\(session.format.rawValue)/\(session.name)\(ext)"
        do {
            try await dest.upload(localPath: session.path, remotePath: remote)
            uploadLog.append(BackupLogEntry(path: session.path, remote: remote, status: .success))
        } catch {
            uploadLog.append(BackupLogEntry(path: session.path, remote: remote, status: .failed(error.localizedDescription)))
            lastError = error.localizedDescription
        }

        uploadProgress = 1.0
        isUploading    = false
    }

    /// Upload a single bounce audio file to S3.
    func backupBounce(_ bounce: Bounce) async {
        guard let dest = destination else {
            lastError = "No backup destination configured."
            return
        }
        guard bounce.isLocallyAvailable else {
            lastError = "Bounce is not locally available."
            return
        }
        isUploading    = true
        uploadProgress = 0
        lastError      = nil

        let remote = "bounces/\(bounce.format)/\(bounce.fileName)"
        do {
            try await dest.upload(localPath: bounce.filePath, remotePath: remote)
            uploadLog.append(BackupLogEntry(path: bounce.filePath, remote: remote, status: .success))
        } catch {
            uploadLog.append(BackupLogEntry(path: bounce.filePath, remote: remote, status: .failed(error.localizedDescription)))
            lastError = error.localizedDescription
        }

        uploadProgress = 1.0
        isUploading    = false
    }

    // MARK: – Backup Listing

    /// Load list of available backups from S3
    func loadAvailableBackups() async {
        guard let dest = destination else {
            lastError = "No backup destination configured"
            return
        }

        guard let userId = userId else {
            lastError = "User not authenticated"
            return
        }

        isLoadingBackups = true
        lastError = nil // Clear previous errors
        pluginBackupIndex = [:] // Reset index

        // Clean up any orphaned backups from failed uploads
        await cleanupOrphanedBackups()

        do {
            // List all objects in user's backup folder
            let prefix = BackupPath.userBackupsPrefix(userId: userId)
            let objects = try await dest.list(prefix: prefix)

            // Filter for metadata.json files
            let metadataFiles = objects.filter { $0.id.hasSuffix("metadata.json") }

            // Download and parse metadata files in batches of 5
            var backups: [BackupListItem] = []
            let batchSize = 5

            for batch in stride(from: 0, to: metadataFiles.count, by: batchSize) {
                let endIndex = min(batch + batchSize, metadataFiles.count)
                let batchFiles = Array(metadataFiles[batch..<endIndex])

                // Process batch in parallel
                await withTaskGroup(of: (BackupListItem, [String])?.self) { group in
                    for metadataObj in batchFiles {
                        group.addTask {
                            // Download and parse metadata
                            guard let manifest = await self.downloadAndParseMetadata(
                                key: metadataObj.id,
                                destination: dest
                            ) else {
                                return nil
                            }

                            // Extract backup ID from path for s3Prefix
                            let pathComponents = metadataObj.id.split(separator: "/")
                            guard pathComponents.count >= 4,
                                  let backupId = pathComponents.dropLast().last.map(String.init) else {
                                return nil
                            }

                            let s3Prefix = "users/\(userId)/backups/\(backupId)"

                            let backupItem = BackupListItem(
                                id: manifest.backupId,
                                name: manifest.backupName,
                                createdAt: manifest.createdAt,
                                pluginCount: manifest.pluginCount,
                                projectCount: manifest.projectCount,
                                totalSize: manifest.totalSizeBytes,
                                s3Prefix: s3Prefix
                            )

                            let pluginKeys = manifest.plugins.map { $0.bundleId ?? $0.name }

                            return (backupItem, pluginKeys)
                        }
                    }

                    var tempIndex: [String: [String]] = [:]
                    for await result in group {
                        if let (backup, pluginKeys) = result {
                            backups.append(backup)
                            for pluginKey in pluginKeys {
                                tempIndex[pluginKey, default: []].append(backup.id)
                            }
                        }
                    }
                    // Update plugin index after batch
                    pluginBackupIndex.merge(tempIndex) { existing, new in existing + new }
                }
            }

            // Sort by date, newest first
            availableBackups = backups.sorted { $0.createdAt > $1.createdAt }

        } catch {
            logger.error("Failed to load backups: \(error)")
            lastError = "Failed to load backup list: \(error.localizedDescription)"
        }

        isLoadingBackups = false
    }

    /// Delete a backup from S3
    func deleteBackup(_ backup: BackupListItem) async throws {
        guard let dest = destination else {
            throw NSError(domain: "BackupService", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "No S3 destination configured"])
        }

        guard userId != nil else {
            throw NSError(domain: "BackupService", code: 2,
                         userInfo: [NSLocalizedDescriptionKey: "Not authenticated"])
        }

        // List all objects in this backup's prefix
        let objects = try await dest.list(prefix: backup.s3Prefix)

        // Delete all objects (plugins, metadata, etc.)
        for object in objects {
            try await dest.delete(key: object.id)
        }

        // Remove from local cache
        await MainActor.run {
            availableBackups.removeAll { $0.id == backup.id }
            // Also remove from plugin index
            pluginBackupIndex = pluginBackupIndex.mapValues { backupIds in
                backupIds.filter { $0 != backup.id }
            }
        }
    }

    /// Get the number of backups containing a specific plugin
    func backupCount(for plugin: AudioPlugin) -> Int {
        let key = plugin.bundleID ?? plugin.name
        return pluginBackupIndex[key]?.count ?? 0
    }

    /// Get all backups containing a specific plugin
    func backupsContaining(plugin: AudioPlugin) -> [BackupListItem] {
        let key = plugin.bundleID ?? plugin.name
        guard let backupIds = pluginBackupIndex[key] else { return [] }
        return availableBackups.filter { backupIds.contains($0.id) }
    }

    /// Detect plugins appearing in 4+ backups
    func consolidationCandidates() -> [(plugin: String, count: Int, backups: [BackupListItem])] {
        var candidates: [(String, Int, [BackupListItem])] = []

        for (pluginKey, backupIds) in pluginBackupIndex where backupIds.count >= 4 {
            let backups = availableBackups.filter { backupIds.contains($0.id) }
            candidates.append((pluginKey, backupIds.count, backups))
        }

        return candidates.sorted { $0.1 > $1.1 } // Most duplicated first
    }
}
