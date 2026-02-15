import Foundation
import AppKit
import os

/// Central observable that drives the entire scan → parse pipeline.
/// All @Published mutations happen on the main actor.
@MainActor
class ScannerService: ObservableObject {

    // MARK: – Published state

    @Published var plugins:       [AudioPlugin]  = []
    @Published var sessions:      [AudioSession] = []
    @Published var isScanning:    Bool           = false
    @Published var scanProgress:  Double         = 0        /// 0 … 1
    @Published var statusMessage: String         = "Ready – press Scan"
    @Published var customPaths:   [String]       = []
    @Published var lastScanDate:  Date?          = nil
    @Published var skippedLargeSessions: Int     = 0
    @Published var parseAllSessions: Bool = false {
        didSet {
            UserDefaults.standard.set(parseAllSessions, forKey: Self.defaultsParseAllKey)
        }
    }
    @Published var parseBackups: Bool = false {
        didSet {
            UserDefaults.standard.set(parseBackups, forKey: Self.defaultsParseBackupsKey)
        }
    }
    @Published var autoRescanOnLaunch: Bool = true {
        didSet {
            UserDefaults.standard.set(autoRescanOnLaunch, forKey: Self.defaultsAutoRescanKey)
        }
    }
    @Published var isCacheStale: Bool = false
    @Published var cacheStaleReason: String? = nil

    private static let logger = Logger(subsystem: "com.audioenv", category: "ScannerService")

    /// Maximum time (seconds) allowed for parsing a single session file.
    private static let perSessionTimeout: TimeInterval = 10

    private let cacheStore = ScanCacheStore()
    private let pluginCatalog = PluginCatalogStore()
    private var cachedScanRoots: [String] = []
    private var cachedRootModTimes: [String: Date] = [:]
    private var cachedPluginDirModTimes: [String: Date] = [:]

    init() {
        loadDefaults()
        loadCache()
        evaluateCacheStalenessAndAutoRescan()
    }

    // MARK: – Well-known plugin directories

    /// System-wide plugin install locations on macOS.
    private static let systemPluginDirs: [String] = [
        "/Library/Audio/Plug-Ins/Components",
        "/Library/Audio/Plug-Ins/AU",
        "/Library/Audio/Plug-Ins/VST",
        "/Library/Audio/Plug-Ins/VST3",
        "/Library/Application Support/Avid/Audio/Plug-Ins",
        "/Library/Application Support/Universal Audio/UAD-2/Plug-Ins",
    ]

    /// Per-user plugin directories.
    private nonisolated static var userPluginDirs: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Library/Audio/Plug-Ins/Components",
            "\(home)/Library/Audio/Plug-Ins/AU",
            "\(home)/Library/Audio/Plug-Ins/VST",
            "\(home)/Library/Audio/Plug-Ins/VST3",
            "\(home)/Library/Application Support/Avid/Audio/Plug-Ins",
            "\(home)/Library/Application Support/Universal Audio/UAD-2/Plug-Ins",
            "\(home)/Library/Application Support/Slate Digital",
            "\(home)/Library/Application Support/Waves/Plug-Ins V15",
        ]
    }

    // MARK: – Default session search roots

    private nonisolated static var defaultSessionRoots: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/Documents",
            "\(home)/Desktop",
            "\(home)/Music",
            "\(home)/Downloads",
        ]
    }

    // MARK: – Extension sets

    /// Bundle extensions that indicate a plugin on disk.
    private static let pluginExts: Set<String> = [
        "au", "component", "vst", "vst3", "aax", "aaxfs", "aaxplugin"
    ]

    /// File/bundle extensions for DAW sessions.
    private static let sessionExts: Set<String> = ["als", "logicpro", "logicx", "ptx", "ptf", "pts"]

    /// Heavy directories to skip when users add large roots like ~ or /.
    private static let skippedDirNames: Set<String> = [
        "Library", ".git", "node_modules", "Pods", "DerivedData", ".build",
        "venv", ".Trash", "Caches"
    ]

    /// Skip parsing extremely large sessions to avoid apparent hangs.
    private static let maxParseSizeBytes: UInt64 = 200 * 1024 * 1024
    private static let maxParsedSessions: Int = 200

    // MARK: – Public API

    /// Kick off a full scan on a background task.
    /// No-ops if a scan is already in flight.
    func scanAll(keepExisting: Bool = false) {
        guard !isScanning else { return }

        // ── Fast re-scan path ──────────────────────────────────────
        // If the last scan was < 5 min ago and no root directories changed,
        // skip the entire filesystem walk and return cached data immediately.
        if let lastScan = lastScanDate,
           Date().timeIntervalSince(lastScan) < Self.fastRescanWindow,
           !sessions.isEmpty {
            let currentRoots = Self.scanRootsForStaleness(customPaths: customPaths)
            let currentTimes = Self.rootModTimes(for: currentRoots)
            var changed = Set(currentRoots) != Set(cachedScanRoots)
            if !changed {
                for root in currentRoots {
                    if let cached = cachedRootModTimes[root],
                       let current = currentTimes[root],
                       current > cached {
                        changed = true
                        break
                    }
                }
            }
            if !changed {
                statusMessage = "No changes since last scan (\(Self.relativeTimeString(from: lastScan)) ago)"
                return
            }
        }

        isScanning   = true
        scanProgress = 0

        // Snapshot cached data before clearing so we can reuse parse results.
        let cachedSessionsByPath: [String: AudioSession] = Dictionary(
            sessions.compactMap { s in s.project != nil ? (s.path, s) : nil },
            uniquingKeysWith: { first, _ in first }
        )
        let priorPlugins = self.plugins
        let priorPluginDirModTimes = self.cachedPluginDirModTimes

        if !keepExisting {
            plugins  = []
            sessions = []
        }
        skippedLargeSessions = 0
        statusMessage = keepExisting ? "Rescanning in background…" : "Scanning plugins…"

        // Capture values needed by the detached task
        let customPaths = self.customPaths
        let parseAll = self.parseAllSessions
        let shouldParseBackups = self.parseBackups

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }

            // ── 1. Discover plugins (with directory mod-time caching) ──
            let pluginDirs = Self.systemPluginDirs + Self.userPluginDirs
            let currentPluginDirTimes = Self.rootModTimes(for: pluginDirs)
            let pluginsUnchanged = !priorPluginDirModTimes.isEmpty
                && !priorPlugins.isEmpty
                && pluginDirs.allSatisfy { dir in
                    guard let cached = priorPluginDirModTimes[dir],
                          let current = currentPluginDirTimes[dir] else { return true }
                    return current <= cached
                }

            let foundPlugins: [AudioPlugin]
            if pluginsUnchanged {
                foundPlugins = priorPlugins
            } else {
                foundPlugins = Self.discoverPlugins()
            }

            await MainActor.run {
                self.plugins      = foundPlugins
                self.scanProgress = 0.35
                self.statusMessage = "Scanning sessions…"
            }

            // ── 2. Discover session files ──
            let roots         = Self.defaultSessionRoots + customPaths
            let foundSessions = Self.discoverSessions(roots: roots)

            // ── 3. Determine which sessions to parse ──
            var parsed = foundSessions

            // Filter parse candidates: respect parseBackups setting
            let parseCandidates = parsed.enumerated()
                .filter { shouldParseBackups || !$0.element.isBackup }
                .sorted { $0.element.modifiedDate > $1.element.modifiedDate }

            let parseLimit = parseAll ? Int.max : Self.maxParsedSessions
            let allowedIndices: Set<Int>
            if parseAll {
                allowedIndices = Set(parseCandidates.map { $0.offset })
            } else {
                // Group by project; only parse the most recently modified per group
                let groups = Dictionary(grouping: parseCandidates) { $0.element.projectGroupKey }
                var representatives: [(offset: Int, element: AudioSession)] = []
                for (_, group) in groups {
                    if let newest = group.max(by: { $0.element.modifiedDate < $1.element.modifiedDate }) {
                        representatives.append(newest)
                    }
                }
                representatives.sort { $0.element.modifiedDate > $1.element.modifiedDate }
                allowedIndices = Set(representatives.prefix(parseLimit).map { $0.offset })
            }

            await MainActor.run {
                self.sessions     = foundSessions
                self.scanProgress = 0.6
                if parseAll {
                    self.statusMessage = "Parsing all sessions…"
                } else {
                    self.statusMessage = "Parsing latest \(allowedIndices.count) sessions…"
                }
            }

            // ── 4. Separate cache hits from sessions that need parsing ──
            var skippedLarge = 0
            var cacheHits = 0
            var indicesToParse: [(index: Int, session: AudioSession)] = []

            for i in parsed.indices {
                let session = parsed[i]

                // Reuse cached parse data for unchanged files (same path + size + modDate)
                if let cached = cachedSessionsByPath[session.path],
                   cached.fileSize == session.fileSize,
                   cached.modifiedDate == session.modifiedDate {
                    var reused = session
                    reused.project = cached.project
                    reused.knownPluginMatches = cached.knownPluginMatches
                    parsed[i] = reused
                    cacheHits += 1
                    continue
                }

                guard allowedIndices.contains(i) else { continue }
                indicesToParse.append((i, session))
            }

            // ── 5. Parallel parsing (max 4 concurrent) with batched UI updates ──
            let totalToParse = indicesToParse.count
            var completedCount = 0
            var lastUpdateTime = CFAbsoluteTimeGetCurrent()

            await withTaskGroup(of: (Int, AudioSession).self) { group in
                var iter = indicesToParse.makeIterator()

                // Seed with up to 4 concurrent parse tasks
                for _ in 0..<4 {
                    guard let (idx, session) = iter.next() else { break }
                    group.addTask {
                        (idx, await Self.parseWithTimeout(session, plugins: foundPlugins))
                    }
                }

                for await (idx, result) in group {
                    parsed[idx] = result
                    if result.project == nil && result.fileSize > Self.maxParseSizeBytes {
                        skippedLarge += 1
                    }
                    completedCount += 1

                    // Batch MainActor updates: every 10 sessions or 0.5 s
                    let now = CFAbsoluteTimeGetCurrent()
                    if completedCount % 10 == 0
                        || (now - lastUpdateTime) >= 0.5
                        || completedCount == totalToParse {
                        let pct = 0.6 + 0.35 * (Double(cacheHits + completedCount) / Double(max(parsed.count, 1)))
                        let sessionName = result.name
                        lastUpdateTime = now
                        await MainActor.run {
                            self.scanProgress = pct
                            self.statusMessage = "Parsing \(sessionName)…"
                        }
                    }

                    // Maintain concurrency — start next task
                    if let (nextIdx, nextSession) = iter.next() {
                        group.addTask {
                            (nextIdx, await Self.parseWithTimeout(nextSession, plugins: foundPlugins))
                        }
                    }
                }
            }

            // ── 6. Done ──
            let scanDate = Date()
            let finalSkippedLarge = skippedLarge
            let finalCacheHits = cacheHits
            let finalParsed = parsed
            await MainActor.run {
                self.sessions     = finalParsed
                self.scanProgress = 1.0
                self.isScanning   = false
                self.skippedLargeSessions = finalSkippedLarge
                self.lastScanDate = scanDate
                var base = "\(finalParsed.count) session(s), \(foundPlugins.count) plugin(s) found"
                if finalCacheHits > 0 {
                    base += " (\(finalCacheHits) cached)"
                }
                self.statusMessage = finalSkippedLarge > 0
                    ? "\(base), \(finalSkippedLarge) large session(s) skipped"
                    : base
            }

            let scanRoots = Self.scanRootsForStaleness(customPaths: customPaths)
            let rootModTimes = Self.rootModTimes(for: scanRoots)

            let cache = ScanCacheStore.makeCache(
                plugins: foundPlugins,
                sessions: finalParsed,
                lastScanDate: scanDate,
                skippedLargeSessions: finalSkippedLarge,
                scanRoots: scanRoots,
                rootModTimes: rootModTimes,
                pluginDirModTimes: currentPluginDirTimes
            )
            let store = await MainActor.run { self.cacheStore }
            store.save(cache)

            await MainActor.run {
                self.cachedScanRoots = scanRoots
                self.cachedRootModTimes = rootModTimes
                self.cachedPluginDirModTimes = currentPluginDirTimes
                self.isCacheStale = false
            }
        }
    }

    /// Append a directory to the custom search path list (ignores duplicates).
    func addCustomPath(_ path: String) {
        guard !customPaths.contains(path) else { return }
        customPaths.append(path)
        UserDefaults.standard.set(customPaths, forKey: Self.defaultsCustomPathsKey)
        evaluateCacheStalenessAndAutoRescan()
    }

    /// Remove a previously added custom search path.
    func removeCustomPath(_ path: String) {
        customPaths.removeAll { $0 == path }
        UserDefaults.standard.set(customPaths, forKey: Self.defaultsCustomPathsKey)
        evaluateCacheStalenessAndAutoRescan()
    }

    /// Parse a single session and update it in the sessions array
    func parseIndividualSession(path: String, completion: (() -> Void)? = nil) {
        guard let index = sessions.firstIndex(where: { $0.path == path }) else {
            completion?()
            return
        }
        let session = sessions[index]

        // Skip if already parsed
        if session.project != nil {
            completion?()
            return
        }

        let currentPlugins = self.plugins
        Task {
            let parsed = await Task.detached(priority: .userInitiated) {
                Self.parseSession(session, plugins: currentPlugins)
            }.value
            // Re-check index in case sessions array changed
            if let currentIndex = self.sessions.firstIndex(where: { $0.path == path }) {
                self.sessions[currentIndex] = parsed
            }
            completion?()
        }
    }

    // MARK: – Private helpers

    private func loadDefaults() {
        let defaults = UserDefaults.standard

        let newPaths = defaults.stringArray(forKey: Self.defaultsCustomPathsKey)
        let oldPaths = defaults.stringArray(forKey: Self.legacyCustomPathsKey)
        if let newPaths {
            customPaths = newPaths
        } else if let oldPaths {
            customPaths = oldPaths
            defaults.set(oldPaths, forKey: Self.defaultsCustomPathsKey)
        }

        if defaults.object(forKey: Self.defaultsParseAllKey) != nil {
            parseAllSessions = defaults.bool(forKey: Self.defaultsParseAllKey)
        } else if defaults.object(forKey: Self.legacyParseAllKey) != nil {
            let value = defaults.bool(forKey: Self.legacyParseAllKey)
            parseAllSessions = value
            defaults.set(value, forKey: Self.defaultsParseAllKey)
        }

        if defaults.object(forKey: Self.defaultsParseBackupsKey) != nil {
            parseBackups = defaults.bool(forKey: Self.defaultsParseBackupsKey)
        }

        if defaults.object(forKey: Self.defaultsAutoRescanKey) != nil {
            autoRescanOnLaunch = defaults.bool(forKey: Self.defaultsAutoRescanKey)
        } else if defaults.object(forKey: Self.legacyAutoRescanKey) != nil {
            let value = defaults.bool(forKey: Self.legacyAutoRescanKey)
            autoRescanOnLaunch = value
            defaults.set(value, forKey: Self.defaultsAutoRescanKey)
        }
    }

    private func loadCache() {
        guard let cache = cacheStore.load() else { return }
        plugins = cache.plugins
        sessions = cache.sessions
        skippedLargeSessions = cache.skippedLargeSessions
        lastScanDate = cache.lastScanDate
        cachedScanRoots = cache.scanRoots
        cachedRootModTimes = cache.rootModTimes
        cachedPluginDirModTimes = cache.pluginDirModTimes
        cacheStaleReason = nil
        if let lastScanDate {
            statusMessage = "Loaded cached scan from \(Self.cacheDateFormatter.string(from: lastScanDate))"
        } else {
            statusMessage = "Loaded cached scan"
        }
    }

    func clearCache() {
        cacheStore.clear()
        plugins = []
        sessions = []
        skippedLargeSessions = 0
        lastScanDate = nil
        isCacheStale = false
        cachedScanRoots = []
        cachedRootModTimes = [:]
        cachedPluginDirModTimes = [:]
        statusMessage = "Cache cleared"
    }

    func catalogEntry(for plugin: AudioPlugin) -> PluginCatalogEntry? {
        pluginCatalog.lookup(name: plugin.name)
    }

    func catalogImage(for plugin: AudioPlugin) -> NSImage? {
        guard let entry = catalogEntry(for: plugin),
              let filename = entry.img
        else { return nil }
        return pluginCatalog.image(named: filename)
    }

    var hasCatalogMatches: Bool {
        plugins.contains { catalogEntry(for: $0)?.img != nil }
    }

    var catalogEntryCount: Int {
        pluginCatalog.pluginCount
    }

    var catalogMatchCount: Int {
        plugins.filter { catalogEntry(for: $0)?.img != nil }.count
    }

    var catalogImageFileCount: Int {
        plugins.filter { plugin in
            guard let entry = catalogEntry(for: plugin),
                  let filename = entry.img
            else { return false }
            return pluginCatalog.imageURL(named: filename) != nil
        }.count
    }

    /// Evaluate cache staleness WITHOUT touching the filesystem.
    /// This avoids triggering macOS TCC prompts (Desktop, Downloads, etc.) on every launch.
    /// Actual filesystem mod-time checks happen lazily when the user triggers a scan.
    private func evaluateCacheStalenessAndAutoRescan() {
        isCacheStale = false
        cacheStaleReason = nil
        guard !cachedScanRoots.isEmpty else { return }

        let currentRoots = Self.scanRootsForStaleness(customPaths: customPaths)
        if Set(currentRoots) != Set(cachedScanRoots) {
            isCacheStale = true
            cacheStaleReason = "Scan roots changed"
        } else if let lastScan = lastScanDate {
            // Mark stale based on age rather than filesystem access
            let age = Date().timeIntervalSince(lastScan)
            if age > 3600 {
                isCacheStale = true
                cacheStaleReason = "Last scan was \(Self.relativeTimeString(from: lastScan)) ago"
            }
        }

        guard isCacheStale, autoRescanOnLaunch else { return }
        guard shouldAutoRescan() else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.scanAll(keepExisting: true)
        }
    }

    private func shouldAutoRescan() -> Bool {
        guard let lastScanDate else { return true }
        return Date().timeIntervalSince(lastScanDate) > Self.autoRescanMinimumAge
    }

    private nonisolated static func scanRootsForStaleness(customPaths: [String]) -> [String] {
        let roots = defaultSessionRoots + systemPluginDirs + userPluginDirs + customPaths
        return Array(Set(roots)).sorted()
    }

    private nonisolated static func rootModTimes(for roots: [String]) -> [String: Date] {
        var result: [String: Date] = [:]
        let fm = FileManager.default
        for root in roots {
            guard let attrs = try? fm.attributesOfItem(atPath: root),
                  let date = attrs[.modificationDate] as? Date
            else { continue }
            result[root] = date
        }
        return result
    }

    private static func relativeTimeString(from date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return "\(hours)h"
    }

    private static let cacheDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let defaultsCustomPathsKey = "AudioEnv.customPaths"
    private static let defaultsParseAllKey = "AudioEnv.parseAllSessions"
    private static let defaultsAutoRescanKey = "AudioEnv.autoRescanOnLaunch"

    private static let defaultsParseBackupsKey = "AudioEnv.parseBackups"
    private static let legacyCustomPathsKey = "AudioEnvScanner.customPaths"
    private static let legacyParseAllKey = "AudioEnvScanner.parseAllSessions"
    private static let legacyAutoRescanKey = "AudioEnvScanner.autoRescanOnLaunch"
    private static let autoRescanMinimumAge: TimeInterval = 12 * 60 * 60
    private static let fastRescanWindow: TimeInterval = 5 * 60

    // ── Plugin discovery ──────────────────────────────────────────

    /// Discover all plugins on disk. This is a pure I/O operation safe to call off the main actor.
    private nonisolated static func discoverPlugins() -> [AudioPlugin] {
        var results: [AudioPlugin] = []
        let fm = FileManager.default

        for dir in systemPluginDirs + userPluginDirs {
            guard fm.fileExists(atPath: dir),
                  let enumerator = fm.enumerator(atPath: dir)
            else { continue }

            while let rel = enumerator.nextObject() as? String {
                let ext = (rel as NSString).pathExtension.lowercased()
                guard pluginExts.contains(ext) else { continue }

                // A plugin bundle is a directory; skip its internals.
                enumerator.skipDescendants()

                let full     = (dir as NSString).appendingPathComponent(rel)
                let baseName = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                let info     = readBundleInfo(at: full)

                results.append(AudioPlugin(
                    name:               baseName,
                    path:               full,
                    format:             formatFor(ext),
                    bundleID:           info.bundleID,
                    version:            info.version,
                    manufacturer:       info.manufacturer,
                    auManufacturerCode: info.auManufacturerCode
                ))
            }
        }
        return results
    }

    /// Map a file extension to the corresponding PluginFormat.
    private nonisolated static func formatFor(_ ext: String) -> PluginFormat {
        switch ext {
        case "au", "component": return .audioUnit
        case "vst":             return .vst
        case "vst3":            return .vst3
        default:                return .aax   // aax / aaxfs / aaxplugin
        }
    }

    /// Best-effort read of a macOS bundle's Info.plist.
    private nonisolated static func readBundleInfo(at path: String) -> (bundleID: String?, version: String?, manufacturer: String?, auManufacturerCode: String?) {
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return (nil, nil, nil, nil) }

        let rawManufacturer = dict["CFBundlePackageType"] as? String
        let manufacturer = (rawManufacturer?.uppercased() == "BNDL") ? nil : rawManufacturer

        // Extract AU 4-char manufacturer code from AudioComponents array
        var auCode: String? = nil
        if let components = dict["AudioComponents"] as? [[String: Any]],
           let first = components.first,
           let mfr = first["manufacturer"] as? String {
            auCode = mfr
        }

        return (
            bundleID:            dict["CFBundleIdentifier"]            as? String,
            version:             dict["CFBundleShortVersionString"]    as? String,
            manufacturer:        manufacturer,
            auManufacturerCode:  auCode
        )
    }

    // ── Session discovery ─────────────────────────────────────────

    /// Walk each search root and collect every .als / .logicpro entry.
    private nonisolated static func discoverSessions(roots: [String]) -> [AudioSession] {
        var results: [AudioSession] = []
        let fm = FileManager.default

        for root in roots {
            guard fm.fileExists(atPath: root),
                  let enumerator = fm.enumerator(
                      at: URL(fileURLWithPath: root),
                      includingPropertiesForKeys: [.isDirectoryKey],
                      options: [.skipsHiddenFiles]
                  )
            else { continue }

            while let url = enumerator.nextObject() as? URL {
                if shouldSkipDirectory(url: url) {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard sessionExts.contains(ext) else { continue }

                // .logicpro / .logicx are bundle directories – don't recurse into them.
                if ext == "logicpro" || ext == "logicx" { enumerator.skipDescendants() }
                if (ext == "logicpro" || ext == "logicx"), shouldSkipLogicTemplate(url: url) {
                    continue
                }
                // Skip Pro Tools templates and tutorials
                if (ext == "ptx" || ext == "ptf" || ext == "pts"), shouldSkipProToolsTemplate(url: url) {
                    continue
                }

                let full   = url.path
                let attrs  = try? fm.attributesOfItem(atPath: full)
                let size   = (attrs?[.size]             as? UInt64) ?? 0
                let date   = (attrs?[.modificationDate] as? Date)  ?? Date()
                let name = cleanSessionName(url: url)
                let format: SessionFormat
                switch ext {
                case "als":
                    format = .ableton
                case "logicpro", "logicx":
                    format = .logic
                default:
                    format = .proTools
                }

                results.append(AudioSession(
                    name: name, path: full, format: format,
                    modifiedDate: date, fileSize: size
                ))
            }
        }
        return results
    }

    private nonisolated static func cleanSessionName(url: URL) -> String {
        let filename = url.lastPathComponent
        var name = (filename as NSString).deletingPathExtension
        if let range = name.lowercased().range(of: ".bak.") {
            let suffix = name[range.upperBound...]
            let digits = suffix.prefix(3)
            if digits.count == 3 && digits.allSatisfy({ $0.isNumber }) {
                name = String(name[..<range.lowerBound])
            }
        }
        return name
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func shouldSkipDirectory(url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true
        else { return false }
        return skippedDirNames.contains(url.lastPathComponent)
    }

    private nonisolated static func shouldSkipLogicTemplate(url: URL) -> Bool {
        let lower = url.path.lowercased()
        let markers = [
            "/project templates/",
            "/tutorial",
            "/tutorial projects/",
            "/demo projects/",
            "/logic pro x demo projects/",
            "/learn logic/",
            "/lesson"
        ]
        return markers.contains { lower.contains($0) }
    }

    private nonisolated static func shouldSkipProToolsTemplate(url: URL) -> Bool {
        let lower = url.path.lowercased()
        let markers = [
            "/project templates/",
            "/tutorial",
            "/tutorials/",
            "/demo sessions/",
            "/demo projects/",
            "/pro tools tutorials/",
            "/learn pro tools/",
            "/lesson",
            "/training/"
        ]
        return markers.contains { lower.contains($0) }
    }

    // ── Parsing ───────────────────────────────────────────────────

    /// Parse a session file. Pure I/O operation safe to call off the main actor.
    /// The `plugins` parameter provides installed plugins for known-plugin matching.
    private nonisolated static func parseSession(_ session: AudioSession, plugins: [AudioPlugin]) -> AudioSession {
        if session.fileSize > maxParseSizeBytes {
            return session
        }

        let start = CFAbsoluteTimeGetCurrent()
        var s = session

        // For Pro Tools sessions, read the data once and reuse for both parsing and plugin matching.
        var ptData: Data?

        switch session.format {
        case .ableton:
            if let p = AbletonParser.parse(path: session.path) { s.project = .ableton(p) }
        case .logic:
            if let p = LogicParser.parse(path: session.path)   { s.project = .logic(p) }
        case .proTools:
            if let handle = FileHandle(forReadingAtPath: session.path) {
                let data = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
                try? handle.close()
                ptData = data
                if let p = ProToolsParser.parse(data: data, path: session.path) {
                    s.project = .proTools(p)
                }
            }
        }

        // Second pass: known-plugin matching against installed plugins
        if s.project != nil {
            let matchData: Data?
            switch session.format {
            case .logic:
                let candidates = [
                    (session.path as NSString).appendingPathComponent("ProjectData"),
                    (session.path as NSString).appendingPathComponent("Contents/ProjectData"),
                ]
                matchData = candidates.lazy.compactMap { FileManager.default.contents(atPath: $0) }.first
            case .proTools:
                matchData = ptData  // reuse already-read data
            default:
                matchData = nil
            }

            if let data = matchData {
                let matches: [PluginMatch]
                switch session.format {
                case .logic:
                    matches = LogicParser.matchKnownPlugins(in: data, against: plugins)
                case .proTools:
                    matches = ProToolsParser.matchKnownPlugins(in: data, against: plugins)
                default:
                    matches = []
                }
                if !matches.isEmpty {
                    s.knownPluginMatches = matches
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed > 2.0 {
            logger.warning("Slow parse: \(session.name, privacy: .public) took \(elapsed, format: .fixed(precision: 2))s")
        }
        return s
    }

    /// Run parseSession with a timeout to prevent one file from stalling the scan.
    private nonisolated static func parseWithTimeout(_ session: AudioSession, plugins: [AudioPlugin]) async -> AudioSession {
        await withTaskGroup(of: AudioSession?.self) { group in
            group.addTask {
                Self.parseSession(session, plugins: plugins)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(perSessionTimeout))
                return nil // sentinel for timeout
            }

            // Take whichever finishes first
            if let first = await group.next() {
                if let result = first {
                    group.cancelAll()
                    return result
                }
                // Timeout fired first (returned nil) – log and skip
                logger.warning("Parse timed out after \(perSessionTimeout)s: \(session.name, privacy: .public) at \(session.path, privacy: .public)")
                group.cancelAll()
                return session
            }
            return session
        }
    }
}
