import Foundation
import AppKit
import CoreAudio
import Darwin
import os.log

/// Passively monitors running DAWs and watches their active project files for saves.
///
/// Architecture:
/// - NSWorkspace notifications detect DAW launch/quit
/// - FSEvents (via DispatchSource) watch project directories for file changes
/// - Save detection uses mod-time + file-size changes, throttled to 1 per 5s
/// - Re-parse triggers fire into ScannerService's existing parsers
@MainActor
class SessionMonitorService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "SessionMonitor")

    // MARK: - Published State

    /// Currently running DAW processes.
    @Published private(set) var runningDAWs: [DAWProcessInfo] = []

    /// Active (open) live sessions being monitored.
    @Published private(set) var activeSessions: [LiveSession] = []

    /// Historical sessions from this app launch (closed sessions).
    @Published private(set) var recentSessions: [LiveSession] = []

    /// Whether monitoring is active.
    @Published private(set) var isMonitoring: Bool = false

    /// Enable/disable monitoring (persisted).
    @Published var monitoringEnabled: Bool {
        didSet {
            UserDefaults.standard.set(monitoringEnabled, forKey: Self.monitoringEnabledKey)
            if monitoringEnabled {
                startMonitoring()
            } else {
                stopMonitoring()
            }
        }
    }

    // MARK: - Auto-Backup Settings

    /// Auto-backup on DAW close.
    @Published var autoBackupOnClose: Bool {
        didSet { UserDefaults.standard.set(autoBackupOnClose, forKey: Self.autoBackupOnCloseKey) }
    }

    /// Auto-backup every Nth save (0 = disabled).
    @Published var autoBackupSaveInterval: Int {
        didSet { UserDefaults.standard.set(autoBackupSaveInterval, forKey: Self.autoBackupSaveIntervalKey) }
    }

    /// Auto-backup every N minutes (0 = disabled).
    @Published var autoBackupTimeInterval: Int {
        didSet {
            UserDefaults.standard.set(autoBackupTimeInterval, forKey: Self.autoBackupTimeIntervalKey)
        }
    }

    // MARK: - DAW Bundle ID Mapping

    static let dawBundleIDs: [String: SessionFormat] = [
        "com.ableton.live": .ableton,
        "com.apple.logic10": .logic,
        "com.avid.ProTools": .proTools,
    ]

    // MARK: - Private State

    private weak var scanner: ScannerService?
    private weak var backup: BackupService?
    private weak var sync: SyncService?
    private weak var auth: AuthenticationService?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var fileWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var directoryWatchers: [String: DispatchSourceFileSystemObject] = [:]
    private var lastParseTime: [String: Date] = [:]
    private var lastModTimes: [String: Date] = [:]
    private var lastFileSizes: [String: Int64] = [:]
    private var debounceWorkItems: [String: DispatchWorkItem] = [:]
    private var pollTimer: Timer?

    private static let monitoringEnabledKey = "AudioEnv.sessionMonitorEnabled"
    private static let autoBackupOnCloseKey = "AudioEnv.autoBackupOnClose"
    private static let autoBackupSaveIntervalKey = "AudioEnv.autoBackupSaveInterval"
    private static let autoBackupTimeIntervalKey = "AudioEnv.autoBackupTimeInterval"
    private var autoBackupTimers: [String: Timer] = [:]
    private static let reparseThrottleSeconds: TimeInterval = 5
    private static let maxParseSizeBytes: Int64 = 200 * 1024 * 1024
    private static let pollIntervalSeconds: TimeInterval = 3

    // Session file extensions per format
    private static let sessionExtensions: [SessionFormat: Set<String>] = [
        .ableton: ["als"],
        .logic: ["logicx", "logicpro"],
        .proTools: ["ptx", "ptf"],
    ]

    // MARK: - Init

    init() {
        let defaults = UserDefaults.standard
        self.monitoringEnabled = defaults.object(forKey: Self.monitoringEnabledKey) != nil
            ? defaults.bool(forKey: Self.monitoringEnabledKey)
            : true // Default to enabled
        self.autoBackupOnClose = defaults.bool(forKey: Self.autoBackupOnCloseKey)
        self.autoBackupSaveInterval = defaults.integer(forKey: Self.autoBackupSaveIntervalKey)
        self.autoBackupTimeInterval = defaults.integer(forKey: Self.autoBackupTimeIntervalKey)
    }

    // MARK: - Configuration

    func configure(scanner: ScannerService, backup: BackupService? = nil, sync: SyncService? = nil, auth: AuthenticationService? = nil) {
        self.scanner = scanner
        self.backup = backup
        self.sync = sync
        self.auth = auth
        if monitoringEnabled {
            startMonitoring()
        }
    }

    // MARK: - Monitoring Lifecycle

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        logger.info("Session monitoring started")

        // Check for already-running DAWs
        detectRunningDAWs()

        // Watch for DAW launches and quits
        let workspace = NSWorkspace.shared
        let nc = workspace.notificationCenter

        let launchObserver = nc.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let userInfo = notification.userInfo
            Task { @MainActor in
                self.handleAppLaunched(userInfo: userInfo)
            }
        }
        workspaceObservers.append(launchObserver)

        let terminateObserver = nc.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let userInfo = notification.userInfo
            Task { @MainActor in
                self.handleAppTerminated(userInfo: userInfo)
            }
        }
        workspaceObservers.append(terminateObserver)

        // Start polling timer for file change detection (supplements FSEvents)
        startPollTimer()
    }

    func stopMonitoring() {
        isMonitoring = false
        logger.info("Session monitoring stopped")

        // Remove workspace observers
        let nc = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            nc.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        // Close all file watchers
        stopAllFileWatchers()

        // Stop poll timer
        pollTimer?.invalidate()
        pollTimer = nil

        // Close all active sessions
        for i in activeSessions.indices {
            activeSessions[i].closedAt = Date()
        }
        recentSessions.append(contentsOf: activeSessions)
        activeSessions.removeAll()
        runningDAWs.removeAll()
    }

    // MARK: - DAW Detection

    private func detectRunningDAWs() {
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard let bundleID = app.bundleIdentifier,
                  let format = Self.dawBundleIDs[bundleID]
            else { continue }

            let info = DAWProcessInfo(
                bundleID: bundleID,
                format: format,
                pid: app.processIdentifier,
                name: app.localizedName ?? format.rawValue
            )

            if !runningDAWs.contains(where: { $0.pid == info.pid }) {
                runningDAWs.append(info)
                logger.info("Detected running DAW: \(info.name) (PID \(info.pid))")
                startWatchingForProjects(daw: info)
            }
        }
    }

    private func handleAppLaunched(userInfo: [AnyHashable: Any]?) {
        guard let app = userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              let format = Self.dawBundleIDs[bundleID]
        else { return }

        let info = DAWProcessInfo(
            bundleID: bundleID,
            format: format,
            pid: app.processIdentifier,
            name: app.localizedName ?? format.rawValue
        )

        logger.info("DAW launched: \(info.name) (PID \(info.pid))")
        runningDAWs.append(info)
        startWatchingForProjects(daw: info)
    }

    private func handleAppTerminated(userInfo: [AnyHashable: Any]?) {
        guard let app = userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier,
              Self.dawBundleIDs[bundleID] != nil
        else { return }

        let pid = app.processIdentifier
        logger.info("DAW terminated: \(bundleID) (PID \(pid))")

        // Close all sessions associated with this DAW
        let closingIndices = activeSessions.indices.filter { activeSessions[$0].dawPID == pid }
        for i in closingIndices.reversed() {
            var session = activeSessions.remove(at: i)
            session.closedAt = Date()
            logger.info("Session closed: \(session.projectName) — \(session.saveCount) saves, \(session.duration.formatted)s")

            // Auto-backup on close
            if autoBackupOnClose && session.saveCount > 0 {
                triggerAutoBackup(projectPath: session.projectPath, reason: "session closed")
            }

            // Sync session activity to API
            syncSessionToAPI(session)

            // Cancel any auto-backup timer for this project
            autoBackupTimers[session.projectPath]?.invalidate()
            autoBackupTimers.removeValue(forKey: session.projectPath)

            recentSessions.insert(session, at: 0)
        }

        // Remove DAW from running list
        runningDAWs.removeAll { $0.pid == pid }

        // Clean up watchers for this DAW's projects
        stopWatchersForPID(pid)
    }

    // MARK: - Project Discovery & Watching

    /// Start watching directories where the given DAW's projects might live.
    private func startWatchingForProjects(daw: DAWProcessInfo) {
        let projectPaths = discoverProjectPaths(for: daw)

        for path in projectPaths {
            startWatchingProjectFile(path: path, daw: daw)
        }
    }

    /// Discover project paths to watch for a given DAW.
    /// Uses scanner's known sessions and common DAW project locations.
    private func discoverProjectPaths(for daw: DAWProcessInfo) -> [String] {
        var paths: [String] = []
        let fm = FileManager.default

        // 1. Use scanner's known session paths for this format
        if let scanner = scanner {
            let knownPaths = scanner.sessions
                .filter { $0.format == daw.format && !$0.isBackup }
                .sorted { $0.modifiedDate > $1.modifiedDate }
                .prefix(50) // Watch the 50 most recent projects
                .map { $0.path }
            paths.append(contentsOf: knownPaths)
        }

        // 2. Add common project directories
        let home = fm.homeDirectoryForCurrentUser.path
        switch daw.format {
        case .ableton:
            let abletonDir = "\(home)/Music/Ableton"
            if fm.fileExists(atPath: abletonDir) {
                paths.append(contentsOf: findSessionFiles(in: abletonDir, extensions: ["als"]))
            }
        case .logic:
            // Logic projects could be anywhere but commonly in ~/Music
            let musicDir = "\(home)/Music"
            if fm.fileExists(atPath: musicDir) {
                paths.append(contentsOf: findSessionFiles(in: musicDir, extensions: ["logicx", "logicpro"]))
            }
        case .proTools:
            let docsDir = "\(home)/Documents"
            if fm.fileExists(atPath: docsDir) {
                paths.append(contentsOf: findSessionFiles(in: docsDir, extensions: ["ptx", "ptf"]))
            }
        }

        // Deduplicate
        return Array(Set(paths))
    }

    /// Find session files in a directory (non-recursive, fast scan).
    private nonisolated func findSessionFiles(in directory: String, extensions: [String]) -> [String] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        var results: [String] = []
        for item in contents {
            let ext = (item as NSString).pathExtension.lowercased()
            if extensions.contains(ext) {
                results.append((directory as NSString).appendingPathComponent(item))
            }
            // Check one level of subdirectories (project folders)
            let subpath = (directory as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: subpath, isDirectory: &isDir), isDir.boolValue {
                if let subContents = try? fm.contentsOfDirectory(atPath: subpath) {
                    for subItem in subContents {
                        let subExt = (subItem as NSString).pathExtension.lowercased()
                        if extensions.contains(subExt) {
                            results.append((subpath as NSString).appendingPathComponent(subItem))
                        }
                    }
                }
            }
        }
        return results
    }

    // MARK: - File Watching (DispatchSource)

    private func startWatchingProjectFile(path: String, daw: DAWProcessInfo) {
        // Don't double-watch
        guard fileWatchers[path] == nil else { return }

        let watchPath: String
        let isBundle: Bool

        // For Logic (.logicx bundles), watch the ProjectData file inside
        if daw.format == .logic {
            let candidates = [
                (path as NSString).appendingPathComponent("Alternatives/000/ProjectData"),
                (path as NSString).appendingPathComponent("ProjectData"),
            ]
            watchPath = candidates.first { FileManager.default.fileExists(atPath: $0) } ?? path
            isBundle = true
        } else {
            watchPath = path
            isBundle = false
        }

        // Record initial state
        if let attrs = try? FileManager.default.attributesOfItem(atPath: watchPath) {
            lastModTimes[path] = attrs[.modificationDate] as? Date
            lastFileSizes[path] = (attrs[.size] as? Int64) ?? 0
        }

        // Create DispatchSource for the file
        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open file for watching: \(watchPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .attrib],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.handleFileChange(projectPath: path, daw: daw)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchers[path] = source

        // Also watch parent directory for new audio files / bounces
        let parentDir: String
        if isBundle {
            parentDir = path // The .logicx bundle itself
        } else {
            parentDir = (path as NSString).deletingLastPathComponent
        }
        startWatchingDirectory(parentDir, projectPath: path, daw: daw)

        logger.debug("Watching project file: \(path)")
    }

    private func startWatchingDirectory(_ dirPath: String, projectPath: String, daw: DAWProcessInfo) {
        guard directoryWatchers[dirPath] == nil else { return }

        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.detectNewFiles(in: dirPath, projectPath: projectPath, daw: daw)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        directoryWatchers[dirPath] = source
    }

    private func stopAllFileWatchers() {
        for (_, source) in fileWatchers {
            source.cancel()
        }
        fileWatchers.removeAll()

        for (_, source) in directoryWatchers {
            source.cancel()
        }
        directoryWatchers.removeAll()

        debounceWorkItems.values.forEach { $0.cancel() }
        debounceWorkItems.removeAll()
        lastParseTime.removeAll()
        lastModTimes.removeAll()
        lastFileSizes.removeAll()
    }

    private func stopWatchersForPID(_ pid: Int32) {
        let sessionPaths = activeSessions.filter { $0.dawPID == pid }.map { $0.projectPath }
            + recentSessions.filter { $0.dawPID == pid }.map { $0.projectPath }

        for path in sessionPaths {
            if let source = fileWatchers.removeValue(forKey: path) {
                source.cancel()
            }
            let parentDir = (path as NSString).deletingLastPathComponent
            if let source = directoryWatchers.removeValue(forKey: parentDir) {
                source.cancel()
            }
            debounceWorkItems[path]?.cancel()
            debounceWorkItems.removeValue(forKey: path)
        }
    }

    // MARK: - Change Detection

    private func handleFileChange(projectPath: String, daw: DAWProcessInfo) {
        let fm = FileManager.default

        // Get current file attributes
        let checkPath: String
        if daw.format == .logic {
            let candidates = [
                (projectPath as NSString).appendingPathComponent("Alternatives/000/ProjectData"),
                (projectPath as NSString).appendingPathComponent("ProjectData"),
            ]
            checkPath = candidates.first { fm.fileExists(atPath: $0) } ?? projectPath
        } else {
            checkPath = projectPath
        }

        guard let attrs = try? fm.attributesOfItem(atPath: checkPath) else { return }
        let newModTime = attrs[.modificationDate] as? Date ?? Date()
        let newSize = (attrs[.size] as? Int64) ?? 0

        let oldModTime = lastModTimes[projectPath]
        let oldSize = lastFileSizes[projectPath]

        // Only treat as a save if mod time AND size actually changed
        // (avoids false positives from lock file operations)
        guard newModTime != oldModTime, newSize != oldSize else { return }

        lastModTimes[projectPath] = newModTime
        lastFileSizes[projectPath] = newSize

        // Debounce: cancel any pending work and schedule a new one
        debounceWorkItems[projectPath]?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.processSaveEvent(projectPath: projectPath, daw: daw, fileSize: newSize)
            }
        }
        debounceWorkItems[projectPath] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reparseThrottleSeconds, execute: workItem)
    }

    private func processSaveEvent(projectPath: String, daw: DAWProcessInfo, fileSize: Int64) {
        // Throttle: skip if we parsed too recently
        if let lastParse = lastParseTime[projectPath],
           Date().timeIntervalSince(lastParse) < Self.reparseThrottleSeconds {
            return
        }

        logger.info("Save detected: \(projectPath) (\(fileSize) bytes)")

        // Find or create the live session
        if let index = activeSessions.firstIndex(where: { $0.projectPath == projectPath }) {
            // Update existing session
            activeSessions[index].saveCount += 1
            activeSessions[index].lastSaveAt = Date()
            activeSessions[index].currentFileSize = fileSize
        } else {
            // Create new session — this project was opened while the DAW was running
            let name = Self.projectName(from: projectPath)
            var session = LiveSession(
                projectPath: projectPath,
                projectName: name,
                format: daw.format,
                dawPID: daw.pid
            )
            session.saveCount = 1
            session.lastSaveAt = Date()
            session.currentFileSize = fileSize
            activeSessions.append(session)
            logger.info("New session discovered via save: \(name)")
        }

        lastParseTime[projectPath] = Date()

        // Trigger re-parse on a background thread and create a snapshot
        if fileSize < Self.maxParseSizeBytes {
            let format = daw.format
            let path = projectPath
            Task.detached(priority: .utility) {
                let snapshot = Self.reparseAndSnapshot(path: path, format: format, fileSize: fileSize)
                await MainActor.run { [weak self] in
                    guard let self,
                          let index = self.activeSessions.firstIndex(where: { $0.projectPath == path })
                    else { return }
                    if let snapshot {
                        self.activeSessions[index].snapshots.append(snapshot)
                        self.logger.info("Snapshot captured for \(self.activeSessions[index].projectName): \(snapshot.pluginCount ?? 0) plugins, \(snapshot.trackCount ?? 0) tracks")
                    }
                }
            }
        }

        // Post notification for other services (menu bar, auto-backup)
        let saveCount = activeSessions.first(where: { $0.projectPath == projectPath })?.saveCount ?? 1
        NotificationCenter.default.post(
            name: .sessionSaveDetected,
            object: nil,
            userInfo: [
                "projectPath": projectPath,
                "format": daw.format.rawValue,
                "fileSize": fileSize,
                "saveCount": saveCount,
            ]
        )

        // Check auto-backup on Nth save
        if autoBackupSaveInterval > 0, saveCount > 0, saveCount % autoBackupSaveInterval == 0 {
            triggerAutoBackup(projectPath: projectPath, reason: "every \(autoBackupSaveInterval) saves")
        }
    }

    // MARK: - Re-parse & Snapshot

    /// Re-parse a project file and create a snapshot of its current state.
    /// Runs off the main actor — pure I/O + parsing.
    private nonisolated static func reparseAndSnapshot(path: String, format: SessionFormat, fileSize: Int64) -> SessionSnapshot? {
        switch format {
        case .ableton:
            guard let project = AbletonParser.parse(path: path) else { return nil }
            return SessionSnapshot(
                fileSize: fileSize,
                pluginCount: project.usedPlugins.count,
                trackCount: project.tracks.count,
                tempo: project.tempo
            )

        case .logic:
            guard let project = LogicParser.parse(path: path) else { return nil }
            var keySignature: String? = nil
            if let key = project.songKey {
                keySignature = project.songScale != nil ? "\(key) \(project.songScale!)" : key
            }
            var timeSignature: String? = nil
            if let num = project.timeSignatureNumerator, let den = project.timeSignatureDenominator {
                timeSignature = "\(num)/\(den)"
            }
            return SessionSnapshot(
                fileSize: fileSize,
                pluginCount: project.pluginHints.count,
                trackCount: project.trackCount,
                tempo: project.tempo,
                keySignature: keySignature,
                timeSignature: timeSignature
            )

        case .proTools:
            guard let project = ProToolsParser.parse(path: path) else { return nil }
            return SessionSnapshot(
                fileSize: fileSize,
                pluginCount: project.pluginNames.count
            )
        }
    }

    // MARK: - New File Detection

    private func detectNewFiles(in dirPath: String, projectPath: String, daw: DAWProcessInfo) {
        guard let index = activeSessions.firstIndex(where: { $0.projectPath == projectPath }) else { return }

        let fm = FileManager.default

        // Check for new audio files
        let audioSubdirs: [String]
        switch daw.format {
        case .ableton:
            audioSubdirs = ["Samples/Recorded", "Samples/Processed"]
        case .logic:
            audioSubdirs = ["Media", "Audio Files"]
        case .proTools:
            audioSubdirs = ["Audio Files"]
        }

        for subdir in audioSubdirs {
            let audioDir = (dirPath as NSString).appendingPathComponent(subdir)
            guard let files = try? fm.contentsOfDirectory(atPath: audioDir) else { continue }
            let audioExts: Set<String> = ["wav", "aif", "aiff", "mp3", "flac", "m4a"]
            for file in files {
                let ext = (file as NSString).pathExtension.lowercased()
                if audioExts.contains(ext) && !activeSessions[index].newAudioFiles.contains(file) {
                    activeSessions[index].newAudioFiles.append(file)
                }
            }
        }

        // Check for new bounces
        let bounceSubdirs: [String]
        switch daw.format {
        case .ableton:
            bounceSubdirs = ["Bounces"]
        case .logic:
            bounceSubdirs = ["Bounces"]
        case .proTools:
            bounceSubdirs = ["Bounced Files"]
        }

        for subdir in bounceSubdirs {
            let bounceDir = (dirPath as NSString).appendingPathComponent(subdir)
            guard let files = try? fm.contentsOfDirectory(atPath: bounceDir) else { continue }
            for file in files {
                if !activeSessions[index].newBounces.contains(file) {
                    activeSessions[index].newBounces.append(file)
                }
            }
        }
    }

    // MARK: - Poll Timer (Fallback)

    /// Polling supplements FSEvents for cases where DispatchSource misses changes
    /// (e.g., atomic writes that replace the file descriptor).
    private func startPollTimer() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollIntervalSeconds, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pollForChanges()
            }
        }
    }

    private func pollForChanges() {
        guard isMonitoring else { return }

        let fm = FileManager.default

        // Re-check that DAWs are still running
        let runningPIDs = Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
        let terminatedDAWs = runningDAWs.filter { !runningPIDs.contains($0.pid) }
        for daw in terminatedDAWs {
            logger.info("DAW no longer running (poll): \(daw.name) PID \(daw.pid)")
            runningDAWs.removeAll { $0.pid == daw.pid }

            let closingIndices = activeSessions.indices.filter { activeSessions[$0].dawPID == daw.pid }
            for i in closingIndices.reversed() {
                var session = activeSessions.remove(at: i)
                session.closedAt = Date()
                recentSessions.insert(session, at: 0)
            }
            stopWatchersForPID(daw.pid)
        }

        // Update process stats for running DAWs
        for i in runningDAWs.indices {
            runningDAWs[i].stats = Self.getProcessStats(pid: runningDAWs[i].pid)
        }

        // Poll watched files for changes (catches atomic writes that replace the fd)
        for session in activeSessions {
            let path = session.projectPath
            let checkPath: String
            if session.format == .logic {
                let candidates = [
                    (path as NSString).appendingPathComponent("Alternatives/000/ProjectData"),
                    (path as NSString).appendingPathComponent("ProjectData"),
                ]
                checkPath = candidates.first { fm.fileExists(atPath: $0) } ?? path
            } else {
                checkPath = path
            }

            guard let attrs = try? fm.attributesOfItem(atPath: checkPath) else { continue }
            let modTime = attrs[.modificationDate] as? Date
            let size = (attrs[.size] as? Int64) ?? 0

            if let modTime, modTime != lastModTimes[path], size != lastFileSizes[path] {
                lastModTimes[path] = modTime
                lastFileSizes[path] = size

                // Find the DAW for this session
                if let daw = runningDAWs.first(where: { $0.pid == session.dawPID }) {
                    processSaveEvent(projectPath: path, daw: daw, fileSize: size)
                }
            }
        }
    }

    // MARK: - Helpers

    private nonisolated static func projectName(from path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }

    /// Get the active session for a given project path.
    func session(for projectPath: String) -> LiveSession? {
        activeSessions.first { $0.projectPath == projectPath }
    }

    /// Get all sessions (active + recent).
    var allSessions: [LiveSession] {
        activeSessions + recentSessions
    }

    /// Clear recent session history.
    func clearRecentSessions() {
        recentSessions.removeAll()
    }

    // MARK: - Auto-Backup Triggers

    private func triggerAutoBackup(projectPath: String, reason: String) {
        logger.info("Auto-backup triggered for \(projectPath): \(reason)")
        NotificationCenter.default.post(
            name: .sessionAutoBackupRequested,
            object: nil,
            userInfo: [
                "projectPath": projectPath,
                "reason": reason,
            ]
        )
    }

    // MARK: - Activity Sync

    private func syncSessionToAPI(_ session: LiveSession) {
        guard let sync, let auth, auth.isAuthenticated, let token = auth.authToken else { return }
        Task {
            await sync.syncSessionActivity(session: session, token: token)
        }
    }

    /// Get the stats for a specific running DAW by PID.
    func stats(for pid: Int32) -> DAWProcessStats? {
        runningDAWs.first(where: { $0.pid == pid })?.stats
    }

    // MARK: - Process Stats (proc_pidinfo + CoreAudio)

    /// Get CPU and memory usage for a process. No special permissions required.
    private nonisolated static func getProcessStats(pid: Int32) -> DAWProcessStats {
        let cpu = cpuUsage(for: pid)
        let memory = memoryUsageMB(for: pid)
        let (device, sampleRate) = defaultAudioOutputDevice()
        return DAWProcessStats(
            cpuPercent: cpu,
            memoryMB: memory,
            audioDevice: device,
            sampleRate: sampleRate
        )
    }

    /// Get CPU usage percentage for a process via proc_pidinfo.
    private nonisolated static func cpuUsage(for pid: Int32) -> Double {
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result == size else { return 0 }

        // pti_total_user + pti_total_system gives total CPU time in nanoseconds
        // We return the accumulated time as a rough indicator; for a true
        // percentage you'd need to diff across two samples.
        let totalNs = Double(taskInfo.pti_total_user + taskInfo.pti_total_system)
        let totalSeconds = totalNs / 1_000_000_000

        // Estimate: total CPU seconds / wall-clock uptime approximated by threadrun_time
        // This is imprecise but useful for display purposes
        let threads = max(Int(taskInfo.pti_threadnum), 1)
        let cpuPercent = (totalSeconds / max(Double(threads), 1)) * 100
        return min(cpuPercent, 100 * Double(threads))
    }

    /// Get resident memory in MB for a process via proc_pidinfo.
    private nonisolated static func memoryUsageMB(for pid: Int32) -> Double {
        var taskInfo = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let result = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &taskInfo, size)
        guard result == size else { return 0 }
        return Double(taskInfo.pti_resident_size) / (1024 * 1024)
    }

    /// Get the default audio output device name and sample rate via CoreAudio.
    private nonisolated static func defaultAudioOutputDevice() -> (name: String?, sampleRate: Int?) {
        var deviceID = AudioObjectID(0)
        var propertySize = UInt32(MemoryLayout<AudioObjectID>.size)

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0, nil,
            &propertySize,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return (nil, nil) }

        // Get device name
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        status = AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)
        let deviceName: String? = status == noErr ? name?.takeUnretainedValue() as String? : nil

        // Get sample rate
        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate: Float64 = 0
        var srSize = UInt32(MemoryLayout<Float64>.size)
        status = AudioObjectGetPropertyData(deviceID, &sampleRateAddress, 0, nil, &srSize, &sampleRate)
        let sr = status == noErr ? Int(sampleRate) : nil

        return (deviceName, sr)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let sessionSaveDetected = Notification.Name("AudioEnv.sessionSaveDetected")
    static let sessionOpened = Notification.Name("AudioEnv.sessionOpened")
    static let sessionClosed = Notification.Name("AudioEnv.sessionClosed")
    static let sessionAutoBackupRequested = Notification.Name("AudioEnv.sessionAutoBackupRequested")
}

// MARK: - TimeInterval Formatting

extension TimeInterval {
    var formatted: String {
        let hours = Int(self) / 3600
        let minutes = (Int(self) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
