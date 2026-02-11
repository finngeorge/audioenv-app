import Foundation
import os.log

/// Manages temporary plugin installations by creating symlinks from
/// standard plugin locations to downloaded backup plugins.
@MainActor
class TempRestoreService: ObservableObject {

    @Published var activeSession: TempRestoreSession?
    @Published var isRestoring: Bool = false
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var restoredPlugins: [RestoredPluginInfo] = []

    private static let logger = Logger(subsystem: "com.audioenv.app", category: "TempRestore")
    private static let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".audioenv/temp-sessions")

    var hasActiveSession: Bool { activeSession != nil }

    // MARK: - Session Model

    struct TempRestoreSession: Codable, Identifiable {
        let id: String
        let startedAt: Date
        var expectedEndAt: Date?
        var symlinks: [SymlinkRecord]
        var pluginCount: Int
        var backupName: String
    }

    struct SymlinkRecord: Codable {
        let symlinkPath: String
        let targetPath: String
        let pluginName: String
        let pluginFormat: String
        let previouslyExisted: Bool
    }

    struct RestoredPluginInfo: Identifiable {
        var id: String { name + format }
        let name: String
        let format: String
        let symlinkPath: String
        let status: RestoreStatus
    }

    enum RestoreStatus {
        case pending
        case installed
        case failed(String)
        case removed
    }

    // MARK: - Plugin Paths

    /// User-level plugin directories (no admin required).
    private static func userPluginDirectory(for format: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch format.uppercased() {
        case "AU", "AUDIOUNIT":
            return "\(home)/Library/Audio/Plug-Ins/Components"
        case "VST3":
            return "\(home)/Library/Audio/Plug-Ins/VST3"
        case "VST":
            return "\(home)/Library/Audio/Plug-Ins/VST"
        case "AAX":
            return "\(home)/Library/Application Support/Avid/Audio/Plug-Ins"
        default:
            return nil
        }
    }

    // MARK: - Start Temp Restore

    /// Start a temporary restore session from a backup manifest.
    func startTempRestore(
        manifest: BackupManifest,
        destination: BackupDestination,
        backupName: String,
        timeoutHours: Int = 24
    ) async {
        guard activeSession == nil else {
            statusMessage = "A temporary session is already active. End it first."
            return
        }

        isRestoring = true
        progress = 0
        statusMessage = "Preparing temporary restore..."
        restoredPlugins = []

        let sessionId = UUID().uuidString
        let sessionDir = Self.sessionsDir.appendingPathComponent(sessionId)
        let pluginsDir = sessionDir.appendingPathComponent("plugins")

        do {
            try FileManager.default.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

            var session = TempRestoreSession(
                id: sessionId,
                startedAt: Date(),
                expectedEndAt: timeoutHours > 0
                    ? Date().addingTimeInterval(TimeInterval(timeoutHours * 3600))
                    : nil,
                symlinks: [],
                pluginCount: manifest.plugins.count,
                backupName: backupName
            )

            // Save initial manifest for crash recovery
            try saveSessionManifest(session, at: sessionDir)

            let totalPlugins = manifest.plugins.count

            for (index, plugin) in manifest.plugins.enumerated() {
                statusMessage = "Downloading \(plugin.name)..."

                let pluginData = try await destination.download(key: plugin.s3Key)
                let zipFileName = URL(fileURLWithPath: plugin.s3Key).lastPathComponent
                let zipPath = pluginsDir.appendingPathComponent(zipFileName)
                try pluginData.write(to: zipPath)

                progress = Double(index + 1) / Double(totalPlugins) * 0.5

                // Extract plugin
                statusMessage = "Extracting \(plugin.name)..."
                let extractDir = pluginsDir.appendingPathComponent(plugin.name)
                try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-xk", zipPath.path, extractDir.path]
                try process.run()
                process.waitUntilExit()

                try? FileManager.default.removeItem(at: zipPath)

                // Find extracted plugin bundle
                let extractedItems = try FileManager.default.contentsOfDirectory(atPath: extractDir.path)
                guard let bundleName = extractedItems.first(where: { item in
                    let ext = (item as NSString).pathExtension.lowercased()
                    return ["component", "vst", "vst3", "aaxplugin", "aax"].contains(ext)
                }) else {
                    restoredPlugins.append(RestoredPluginInfo(
                        name: plugin.name, format: plugin.format,
                        symlinkPath: "", status: .failed("No plugin bundle in archive")
                    ))
                    continue
                }

                let extractedBundlePath = extractDir.appendingPathComponent(bundleName).path

                // Create symlink in user plugin directory
                statusMessage = "Installing \(plugin.name) temporarily..."
                guard let targetDir = Self.userPluginDirectory(for: plugin.format) else {
                    restoredPlugins.append(RestoredPluginInfo(
                        name: plugin.name, format: plugin.format,
                        symlinkPath: "", status: .failed("Unknown format: \(plugin.format)")
                    ))
                    continue
                }

                try FileManager.default.createDirectory(atPath: targetDir, withIntermediateDirectories: true)

                let symlinkPath = (targetDir as NSString).appendingPathComponent(bundleName)
                let previouslyExisted = FileManager.default.fileExists(atPath: symlinkPath)

                if previouslyExisted {
                    restoredPlugins.append(RestoredPluginInfo(
                        name: plugin.name, format: plugin.format,
                        symlinkPath: symlinkPath, status: .failed("Already exists at target")
                    ))
                    continue
                }

                // Record BEFORE creating symlink (crash recovery)
                let record = SymlinkRecord(
                    symlinkPath: symlinkPath,
                    targetPath: extractedBundlePath,
                    pluginName: plugin.name,
                    pluginFormat: plugin.format,
                    previouslyExisted: previouslyExisted
                )
                session.symlinks.append(record)
                try saveSessionManifest(session, at: sessionDir)

                try FileManager.default.createSymbolicLink(
                    atPath: symlinkPath, withDestinationPath: extractedBundlePath
                )

                restoredPlugins.append(RestoredPluginInfo(
                    name: plugin.name, format: plugin.format,
                    symlinkPath: symlinkPath, status: .installed
                ))

                progress = 0.5 + Double(index + 1) / Double(totalPlugins) * 0.5
            }

            activeSession = session
            try saveSessionManifest(session, at: sessionDir)

            let installedCount = restoredPlugins.filter {
                if case .installed = $0.status { return true }; return false
            }.count
            statusMessage = "Temporary restore complete. \(installedCount) plugins installed."
            Self.logger.info("Temp restore session \(sessionId) started with \(session.symlinks.count) symlinks")

        } catch {
            statusMessage = "Restore failed: \(error.localizedDescription)"
            Self.logger.error("Temp restore failed: \(error.localizedDescription)")
            await cleanupSession(id: sessionId)
        }

        progress = 1.0
        isRestoring = false
    }

    // MARK: - End Session

    /// End the active session — remove all symlinks and temp files.
    func endSession() async {
        guard let session = activeSession else { return }

        isRestoring = true
        statusMessage = "Cleaning up temporary plugins..."

        await cleanupSession(id: session.id)

        activeSession = nil
        restoredPlugins = []
        statusMessage = "Temporary session ended. All plugins removed."
        isRestoring = false

        Self.logger.info("Temp restore session \(session.id) ended")
    }

    // MARK: - Orphan Detection

    /// Check for orphaned sessions on launch (from crashes/force-quits).
    func checkForOrphanedSessions() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.sessionsDir.path),
              let contents = try? fm.contentsOfDirectory(atPath: Self.sessionsDir.path)
        else { return }

        for sessionId in contents where !sessionId.hasPrefix(".") {
            let sessionDir = Self.sessionsDir.appendingPathComponent(sessionId)
            let manifestPath = sessionDir.appendingPathComponent("manifest.json")

            guard let data = fm.contents(atPath: manifestPath.path),
                  let session = try? JSONDecoder().decode(TempRestoreSession.self, from: data)
            else { continue }

            Self.logger.warning("Found orphaned temp session: \(sessionId)")
            activeSession = session
            restoredPlugins = session.symlinks.map { record in
                let exists = fm.fileExists(atPath: record.symlinkPath)
                return RestoredPluginInfo(
                    name: record.pluginName,
                    format: record.pluginFormat,
                    symlinkPath: record.symlinkPath,
                    status: exists ? .installed : .removed
                )
            }
            statusMessage = "Found orphaned temp session from \(Self.dateFormatter.string(from: session.startedAt)). Clean up recommended."
            break
        }
    }

    /// Emergency cleanup — remove all temp sessions and symlinks.
    func emergencyCleanup() async {
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.sessionsDir.path),
              let contents = try? fm.contentsOfDirectory(atPath: Self.sessionsDir.path)
        else { return }

        for sessionId in contents where !sessionId.hasPrefix(".") {
            await cleanupSession(id: sessionId)
        }

        activeSession = nil
        restoredPlugins = []
        statusMessage = "Emergency cleanup complete."
    }

    // MARK: - Private Helpers

    private func cleanupSession(id: String) async {
        let fm = FileManager.default
        let sessionDir = Self.sessionsDir.appendingPathComponent(id)
        let manifestPath = sessionDir.appendingPathComponent("manifest.json")

        if let data = fm.contents(atPath: manifestPath.path),
           let session = try? JSONDecoder().decode(TempRestoreSession.self, from: data) {
            for record in session.symlinks {
                if let attrs = try? fm.attributesOfItem(atPath: record.symlinkPath),
                   attrs[.type] as? FileAttributeType == .typeSymbolicLink {
                    try? fm.removeItem(atPath: record.symlinkPath)
                    Self.logger.info("Removed symlink: \(record.symlinkPath)")
                }
            }
        }

        try? fm.removeItem(at: sessionDir)
    }

    private func saveSessionManifest(_ session: TempRestoreSession, at dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(session)
        try data.write(to: dir.appendingPathComponent("manifest.json"))
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
