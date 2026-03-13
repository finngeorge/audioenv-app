import Foundation
import AppKit
import CoreAudio
import Darwin
import os.log

/// Thread-safe cache for CoreAudio device info to avoid HAL console warnings on every poll.
private final class AudioDeviceCache: @unchecked Sendable {
    static let shared = AudioDeviceCache()
    private var name: String?
    private var sampleRate: Int?
    private var lastFetch: Date = .distantPast
    private let lock = NSLock()

    func get(maxAge: TimeInterval, fetch: () -> (String?, Int?)) -> (name: String?, sampleRate: Int?) {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastFetch) >= maxAge {
            let result = fetch()
            name = result.0
            sampleRate = result.1
            lastFetch = Date()
        }
        return (name, sampleRate)
    }
}

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
    private var lastLogPollDate: Date = .distantPast
    private static let logPollIntervalSeconds: TimeInterval = 10

    private static let audioDeviceCacheSeconds: TimeInterval = 30

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
        // Discover candidate paths from log + file system
        let allPaths = discoverProjectPaths(for: daw)

        // Ableton only has one project open at a time — use the most recent
        // "Loading document" entry from Log.txt as the current project.
        if daw.format == .ableton, let logPath = findAbletonLogPath() {
            let logEntries = parseAbletonLogForOpenSets(logPath: logPath)
            if let (currentPath, openedAt) = logEntries.first,  // most recent (parsed in reverse)
               !activeSessions.contains(where: { $0.projectPath == currentPath }),
               FileManager.default.fileExists(atPath: currentPath) {
                let name = Self.projectName(from: currentPath)
                let session = LiveSession(
                    projectPath: currentPath,
                    projectName: name,
                    format: daw.format,
                    dawPID: daw.pid,
                    openedAt: openedAt
                )
                activeSessions.append(session)
                logger.info("Session opened (from log): \(name)")
                captureInitialSnapshot(projectPath: currentPath, format: daw.format)
            }
        }

        for path in allPaths {
            startWatchingProjectFile(path: path, daw: daw)
        }
    }

    /// Discover project paths to watch for a given DAW.
    /// Uses scanner's known sessions, Ableton's Log.txt, and common project locations.
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

        // 2. For Ableton, parse Log.txt to find the currently open project
        if daw.format == .ableton {
            if let logPath = findAbletonLogPath() {
                paths.append(contentsOf: parseAbletonLogForOpenSets(logPath: logPath).map(\.0))
            }
        }

        // 3. Add recently modified projects from common directories
        //    (limited to files modified in the last 7 days to avoid watching hundreds of files)
        let home = fm.homeDirectoryForCurrentUser.path
        let recentCutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        switch daw.format {
        case .ableton:
            let abletonDir = "\(home)/Music/Ableton"
            if fm.fileExists(atPath: abletonDir) {
                paths.append(contentsOf: findSessionFiles(in: abletonDir, extensions: ["als"], maxDepth: 4, modifiedAfter: recentCutoff))
            }
        case .logic:
            let musicDir = "\(home)/Music"
            if fm.fileExists(atPath: musicDir) {
                paths.append(contentsOf: findSessionFiles(in: musicDir, extensions: ["logicx", "logicpro"], maxDepth: 3, modifiedAfter: recentCutoff))
            }
        case .proTools:
            let docsDir = "\(home)/Documents"
            if fm.fileExists(atPath: docsDir) {
                paths.append(contentsOf: findSessionFiles(in: docsDir, extensions: ["ptx", "ptf"], maxDepth: 3, modifiedAfter: recentCutoff))
            }
        }

        // Deduplicate
        let deduplicated = Array(Set(paths))
        logger.info("Discovered \(deduplicated.count) project paths for \(daw.name)")
        return deduplicated
    }

    // MARK: - Ableton Log Parsing

    /// Find the most recent Ableton Live Log.txt path.
    private nonisolated func findAbletonLogPath() -> String? {
        let prefsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/Ableton").path
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: prefsDir) else { return nil }

        // Find the most recently modified "Live *" directory
        let liveDirs = versions
            .filter { $0.hasPrefix("Live ") }
            .compactMap { dir -> (String, Date)? in
                let fullPath = (prefsDir as NSString).appendingPathComponent(dir)
                let logPath = (fullPath as NSString).appendingPathComponent("Log.txt")
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
                      let modDate = attrs[.modificationDate] as? Date else { return nil }
                return (logPath, modDate)
            }
            .sorted { $0.1 > $1.1 }

        return liveDirs.first?.0
    }

    /// Parse Ableton's Log.txt for "Loading document" lines to find open project(s).
    /// Returns `[(path, timestamp)]` tuples with the ISO 8601 timestamp from each log line.
    /// Exposed as `nonisolated` and `static`-compatible logic for testability.
    private nonisolated func parseAbletonLogForOpenSets(logPath: String) -> [(String, Date)] {
        guard let data = FileManager.default.contents(atPath: logPath),
              let log = String(data: data, encoding: .utf8) else { return [] }
        return Self.parseAbletonLogLines(log)
    }

    /// Pure parsing logic, factored out for testability.
    /// Log lines look like: `2024-03-15T14:32:07.123456 info: Loading document "/Users/.../project.als"`
    nonisolated static func parseAbletonLogLines(_ log: String) -> [(String, Date)] {
        var results: [(String, Date)] = []
        var seen = Set<String>()
        let lines = log.components(separatedBy: "\n").reversed()

        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"

        for line in lines {
            // Stop at the last "Started: Live" marker — that's the current session boundary
            if line.contains("Started: Live") && line.contains("Build:") {
                break
            }

            if line.contains("Loading document") && line.contains(".als\"") {
                // Extract path between quotes
                if let startRange = line.range(of: "\""),
                   let endRange = line.range(of: "\"", range: line.index(after: startRange.lowerBound)..<line.endIndex) {
                    let path = String(line[startRange.upperBound..<endRange.lowerBound])
                    // Skip template/default/untitled tracks, only include real user projects
                    let filename = (path as NSString).lastPathComponent.lowercased()
                    if !path.contains("/App-Resources/") &&
                       !path.contains("/Core Library/") &&
                       !path.contains("/Defaults/") &&
                       filename != "untitled.als" &&
                       !filename.hasPrefix("untitled ") &&
                       !seen.contains(path) {
                        seen.insert(path)
                        // Parse timestamp from the start of the line
                        let timestamp = Self.parseLogTimestamp(line, formatter: fmt) ?? Date()
                        results.append((path, timestamp))
                    }
                }
            }
        }

        return results
    }

    /// Extract the timestamp prefix from an Ableton log line.
    /// Ableton uses local time without timezone: `2024-03-15T14:32:07.123456`
    nonisolated static func parseLogTimestamp(_ line: String, formatter: DateFormatter? = nil) -> Date? {
        // Timestamp is the first space-delimited token: "2024-03-15T14:32:07.123456"
        guard let spaceIndex = line.firstIndex(of: " ") else { return nil }
        let timestampStr = String(line[line.startIndex..<spaceIndex])

        if let fmt = formatter {
            return fmt.date(from: timestampStr)
        }

        // Ableton log timestamps are local time without timezone suffix
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS"
        if let date = fmt.date(from: timestampStr) {
            return date
        }
        // Fallback: without fractional seconds
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.date(from: timestampStr)
    }

    /// Find session files in a directory, recursing up to maxDepth levels.
    /// Only returns files modified after the given date (if provided) to avoid watching stale projects.
    private nonisolated func findSessionFiles(in directory: String, extensions: [String], maxDepth: Int, modifiedAfter: Date? = nil) -> [String] {
        var results: [String] = []
        findSessionFilesRecursive(in: directory, extensions: extensions, depth: 0, maxDepth: maxDepth, modifiedAfter: modifiedAfter, results: &results)
        return results
    }

    private nonisolated func findSessionFilesRecursive(in directory: String, extensions: [String], depth: Int, maxDepth: Int, modifiedAfter: Date?, results: inout [String]) {
        guard depth < maxDepth else { return }
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: directory) else { return }

        for item in contents {
            // Skip Backup folders, hidden dirs, and Factory Packs
            if item.hasPrefix(".") || item == "Backup" || item == "Factory Packs" { continue }

            let fullPath = (directory as NSString).appendingPathComponent(item)
            let ext = (item as NSString).pathExtension.lowercased()

            if extensions.contains(ext) {
                // Filter by modification date if specified
                if let cutoff = modifiedAfter {
                    if let attrs = try? fm.attributesOfItem(atPath: fullPath),
                       let modDate = attrs[.modificationDate] as? Date,
                       modDate > cutoff {
                        results.append(fullPath)
                    }
                } else {
                    results.append(fullPath)
                }
            } else {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    findSessionFilesRecursive(in: fullPath, extensions: extensions, depth: depth + 1, maxDepth: maxDepth, modifiedAfter: modifiedAfter, results: &results)
                }
            }
        }
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
            let events = source.data
            Task { @MainActor in
                if events.contains(.rename) {
                    // Atomic write: file was replaced. Re-open watcher on the new fd.
                    self.reopenFileWatcher(path: path, watchPath: watchPath, daw: daw)
                }
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

    /// Re-open a file watcher after an atomic write (rename) replaces the original file.
    /// The old fd is stale after the rename, so we cancel it and open a fresh one.
    private func reopenFileWatcher(path: String, watchPath: String, daw: DAWProcessInfo) {
        // Cancel the old source (which closes the old fd via setCancelHandler)
        fileWatchers[path]?.cancel()
        fileWatchers.removeValue(forKey: path)

        let fd = open(watchPath, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not re-open file for watching after rename: \(watchPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .attrib],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = source.data
            Task { @MainActor in
                if events.contains(.rename) {
                    self.reopenFileWatcher(path: path, watchPath: watchPath, daw: daw)
                }
                self.handleFileChange(projectPath: path, daw: daw)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        fileWatchers[path] = source
        logger.debug("Re-opened file watcher after rename: \(path)")
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

        // Only require mod-time change to detect a save — same-size saves are common
        // (e.g. renaming a track, tweaking a parameter)
        guard newModTime != oldModTime else { return }

        lastModTimes[projectPath] = newModTime
        lastFileSizes[projectPath] = newSize

        // Count save immediately (not gated by re-parse throttle)
        if let index = activeSessions.firstIndex(where: { $0.projectPath == projectPath }) {
            activeSessions[index].saveCount += 1
            activeSessions[index].lastSaveAt = Date()
            activeSessions[index].currentFileSize = newSize
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
            session.currentFileSize = newSize
            activeSessions.append(session)
            logger.info("New session discovered via save: \(name)")
        }

        logger.info("Save detected: \(projectPath) (\(newSize) bytes)")

        // Post save notification immediately
        let saveCount = activeSessions.first(where: { $0.projectPath == projectPath })?.saveCount ?? 1
        NotificationCenter.default.post(
            name: .sessionSaveDetected,
            object: nil,
            userInfo: [
                "projectPath": projectPath,
                "format": daw.format.rawValue,
                "fileSize": newSize,
                "saveCount": saveCount,
            ]
        )

        // Check auto-backup on Nth save
        if autoBackupSaveInterval > 0, saveCount > 0, saveCount % autoBackupSaveInterval == 0 {
            triggerAutoBackup(projectPath: projectPath, reason: "every \(autoBackupSaveInterval) saves")
        }

        // Debounce only the expensive re-parse
        debounceWorkItems[projectPath]?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.reparseForSnapshot(projectPath: projectPath, format: daw.format, fileSize: newSize)
            }
        }
        debounceWorkItems[projectPath] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.reparseThrottleSeconds, execute: workItem)
    }

    private func reparseForSnapshot(projectPath: String, format: SessionFormat, fileSize: Int64) {
        // Throttle: skip if we parsed too recently
        if let lastParse = lastParseTime[projectPath],
           Date().timeIntervalSince(lastParse) < Self.reparseThrottleSeconds {
            return
        }

        lastParseTime[projectPath] = Date()

        // Trigger re-parse on a background thread and create a snapshot
        guard fileSize < Self.maxParseSizeBytes else { return }

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
                    NotificationCenter.default.post(name: .sessionSnapshotCaptured, object: nil)
                }
            }
        }
    }

    // MARK: - Re-parse & Snapshot

    /// Parse the project file immediately on discovery so the menu bar shows
    /// track count, plugin count, tempo, etc. right away.
    private func captureInitialSnapshot(projectPath: String, format: SessionFormat) {
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: projectPath)[.size] as? Int64) ?? 0
        guard fileSize > 0, fileSize < Self.maxParseSizeBytes else {
            logger.warning("Skipping initial snapshot for \(projectPath): size=\(fileSize)")
            return
        }

        logger.info("Parsing project for initial snapshot: \(projectPath) (\(fileSize) bytes)")

        Task.detached(priority: .utility) {
            let snapshot = Self.reparseAndSnapshot(path: projectPath, format: format, fileSize: fileSize)
            await MainActor.run { [weak self] in
                guard let self,
                      let index = self.activeSessions.firstIndex(where: { $0.projectPath == projectPath })
                else {
                    self?.logger.warning("Session gone before snapshot completed for \(projectPath)")
                    return
                }
                if let snapshot {
                    self.activeSessions[index].snapshots.append(snapshot)
                    self.logger.info("Initial snapshot for \(self.activeSessions[index].projectName): \(snapshot.pluginCount ?? 0) plugins, \(snapshot.trackCount ?? 0) tracks, \(snapshot.tempo ?? 0) BPM")
                    // Notify menu bar to rebuild with the new snapshot data
                    NotificationCenter.default.post(name: .sessionSnapshotCaptured, object: nil)
                } else {
                    self.logger.warning("Parse returned nil for \(projectPath)")
                }
            }
        }
    }

    /// Re-parse a project file and create a snapshot of its current state.
    /// Runs off the main actor — pure I/O + parsing.
    private nonisolated static func reparseAndSnapshot(path: String, format: SessionFormat, fileSize: Int64) -> SessionSnapshot? {
        switch format {
        case .ableton:
            guard let project = AbletonParser.parse(path: path) else { return nil }
            let nonMasterTracks = project.tracks.filter { $0.type != .master }
            let audioTracks = nonMasterTracks.filter { $0.type == .audio }.count
            let midiTracks = nonMasterTracks.filter { $0.type == .midi || $0.type == .beatBassline }.count
            let returnTracks = nonMasterTracks.filter { $0.type == .returnTrack }.count
            let totalClips = nonMasterTracks.reduce(0) { $0 + $1.clips.count }

            var keySignature: String? = nil
            if let root = project.keyRoot {
                keySignature = project.keyScale != nil ? "\(root) \(project.keyScale!)" : root
            }

            // Build per-track plugin info
            var trackPlugins: [TrackPluginInfo] = []
            for track in project.tracks {
                let typeLabel: String
                switch track.type {
                case .audio: typeLabel = "audio"
                case .midi, .beatBassline: typeLabel = "midi"
                case .returnTrack: typeLabel = "return"
                case .master: typeLabel = "master"
                }
                for plugin in track.plugins {
                    trackPlugins.append(TrackPluginInfo(
                        pluginName: plugin,
                        trackName: track.name,
                        trackType: typeLabel
                    ))
                }
            }

            return SessionSnapshot(
                fileSize: fileSize,
                pluginCount: project.usedPlugins.count,
                trackCount: nonMasterTracks.count,
                tempo: project.tempo,
                keySignature: keySignature,
                timeSignature: project.timeSignature,
                audioTrackCount: audioTracks,
                midiTrackCount: midiTracks,
                returnTrackCount: returnTracks,
                clipCount: totalClips,
                sampleCount: project.samplePaths.count,
                pluginNames: project.usedPlugins,
                trackPlugins: trackPlugins,
                abletonVersion: project.version
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
                pluginCount: project.pluginCatalog.count,
                trackCount: project.trackCount
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

        // Periodically re-check Ableton Log.txt for newly opened projects
        if Date().timeIntervalSince(lastLogPollDate) >= Self.logPollIntervalSeconds {
            lastLogPollDate = Date()
            for daw in runningDAWs where daw.format == .ableton {
                if let logPath = findAbletonLogPath() {
                    let logEntries = parseAbletonLogForOpenSets(logPath: logPath)
                    // Close sessions for this DAW that are no longer the active project.
                    // Ableton only has one project open at a time, so the most recent
                    // "Loading document" entry is the current one — close all others.
                    let currentProject = logEntries.first?.0 // most recent path from log
                    let staleSessions = activeSessions.indices.filter { i in
                        activeSessions[i].dawPID == daw.pid &&
                        activeSessions[i].format == .ableton &&
                        activeSessions[i].projectPath != currentProject
                    }
                    // Collect closed sessions for Save As detection
                    var closedSessions: [LiveSession] = []
                    for i in staleSessions.reversed() {
                        var session = activeSessions.remove(at: i)
                        session.closedAt = Date()
                        logger.info("Session closed (project switched): \(session.projectName)")
                        syncSessionToAPI(session)
                        recentSessions.insert(session, at: 0)
                        closedSessions.append(session)
                    }

                    // Add the current project if it's not already tracked
                    if let (path, openedAt) = logEntries.first,
                       !activeSessions.contains(where: { $0.projectPath == path }),
                       FileManager.default.fileExists(atPath: path) {
                        let name = Self.projectName(from: path)

                        // Save As detection: check if the new project is a version
                        // of a just-closed session (same directory, same base name)
                        var relatedPath: String? = nil
                        var inheritedSnapshot: SessionSnapshot? = nil
                        let newDir = (path as NSString).deletingLastPathComponent
                        let newBase = Self.stripVersionSuffix(from: (path as NSString).lastPathComponent)

                        for closed in closedSessions {
                            let closedDir = (closed.projectPath as NSString).deletingLastPathComponent
                            let closedBase = Self.stripVersionSuffix(from: (closed.projectPath as NSString).lastPathComponent)
                            if newDir == closedDir && newBase == closedBase {
                                relatedPath = closed.projectPath
                                inheritedSnapshot = closed.snapshots.last
                                logger.info("Save As detected: \(closed.projectName) → \(name)")
                                break
                            }
                        }

                        var session = LiveSession(
                            projectPath: path,
                            projectName: name,
                            format: daw.format,
                            dawPID: daw.pid,
                            openedAt: openedAt,
                            relatedProjectPath: relatedPath
                        )
                        // Copy last snapshot from closed session for cross-version diffing
                        if let snapshot = inheritedSnapshot {
                            session.snapshots.append(snapshot)
                        }
                        activeSessions.append(session)
                        logger.info("Session opened (from log poll): \(name)")
                        captureInitialSnapshot(projectPath: path, format: daw.format)
                        startWatchingProjectFile(path: path, daw: daw)
                    }
                }
            }
        }

        // Poll watched files for changes (catches atomic writes that replace the fd)
        for session in activeSessions {
            if let daw = runningDAWs.first(where: { $0.pid == session.dawPID }) {
                handleFileChange(projectPath: session.projectPath, daw: daw)
            }
        }
    }

    // MARK: - Helpers

    private nonisolated static func projectName(from path: String) -> String {
        let filename = (path as NSString).lastPathComponent
        return (filename as NSString).deletingPathExtension
    }

    /// Strip version suffix from a filename for Save As grouping.
    /// e.g. "findU 1.2.als" → "findU.als", "My Song v3.als" → "My Song.als"
    private nonisolated static func stripVersionSuffix(from filename: String) -> String {
        let name = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        // Strip trailing version patterns: " 1.2", " v3", " 1.2.3"
        let stripped = name.replacingOccurrences(
            of: #"\s+v?\d+(\.\d+)*$"#,
            with: "",
            options: .regularExpression
        )
        return ext.isEmpty ? stripped : "\(stripped).\(ext)"
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

        // Use cached audio device info to avoid CoreAudio HAL warnings on every poll
        let device = AudioDeviceCache.shared.get(maxAge: audioDeviceCacheSeconds) {
            defaultAudioOutputDevice()
        }

        return DAWProcessStats(
            cpuPercent: cpu,
            memoryMB: memory,
            audioDevice: device.name,
            sampleRate: device.sampleRate
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
    static let sessionSnapshotCaptured = Notification.Name("AudioEnv.sessionSnapshotCaptured")
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
