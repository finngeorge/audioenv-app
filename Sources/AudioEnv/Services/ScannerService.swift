import Foundation
import AppKit

/// Central observable that drives the entire scan → parse pipeline.
/// All @Published mutations happen on the main thread.
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
    @Published var autoRescanOnLaunch: Bool = true {
        didSet {
            UserDefaults.standard.set(autoRescanOnLaunch, forKey: Self.defaultsAutoRescanKey)
        }
    }
    @Published var isCacheStale: Bool = false
    @Published var cacheStaleReason: String? = nil

    private let cacheStore = ScanCacheStore()
    private let pluginCatalog = PluginCatalogStore()
    private var cachedScanRoots: [String] = []
    private var cachedRootModTimes: [String: Date] = [:]

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
    private static var userPluginDirs: [String] {
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

    private static var defaultSessionRoots: [String] {
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

    /// Kick off a full scan on a background queue.
    /// No-ops if a scan is already in flight.
    func scanAll(keepExisting: Bool = false) {
        guard !isScanning else { return }
        isScanning   = true
        scanProgress = 0

        // Snapshot cached sessions so we can reuse parse data for unchanged files.
        let cachedSessionsByPath: [String: AudioSession] = Dictionary(
            sessions.compactMap { s in s.project != nil ? (s.path, s) : nil },
            uniquingKeysWith: { first, _ in first }
        )

        if !keepExisting {
            plugins  = []
            sessions = []
        }
        skippedLargeSessions = 0
        statusMessage = keepExisting ? "Rescanning in background…" : "Scanning plugins…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. Discover plugins
            let foundPlugins = self.discoverPlugins()
            self.onMain {
                self.plugins      = foundPlugins
                self.scanProgress = 0.35
                self.statusMessage = "Scanning sessions…"
            }

            // 2. Discover session files
            let roots         = Self.defaultSessionRoots + self.customPaths
            let foundSessions = self.discoverSessions(roots: roots)
            self.onMain {
                self.sessions     = foundSessions
                self.scanProgress = 0.6
                if self.parseAllSessions {
                    self.statusMessage = "Parsing all sessions…"
                } else {
                    let n = min(foundSessions.count, Self.maxParsedSessions)
                    self.statusMessage = "Parsing latest \(n) sessions…"
                }
            }

            // 3. Parse each session, reusing cached parse data for unchanged files
            var parsed = foundSessions
            var skippedLarge = 0
            var cacheHits = 0
            let parseLimit = self.parseAllSessions ? Int.max : Self.maxParsedSessions
            let parseCandidates = parsed.enumerated()
                .filter { !$0.element.isBackup }
                .sorted { $0.element.modifiedDate > $1.element.modifiedDate }
            let allowedIndices = Set(parseCandidates.prefix(parseLimit).map { $0.offset })

            for i in parsed.indices {
                let current = parsed[i]

                // Check if we can reuse cached parse data (same path, size, and mod date)
                if let cached = cachedSessionsByPath[current.path],
                   cached.fileSize == current.fileSize,
                   cached.modifiedDate == current.modifiedDate {
                    var reused = current
                    reused.project = cached.project
                    parsed[i] = reused
                    cacheHits += 1
                    let pct = 0.6 + 0.35 * (Double(i + 1) / Double(max(parsed.count, 1)))
                    self.onMain { self.scanProgress = pct }
                    continue
                }

                self.onMain {
                    self.statusMessage = "Parsing \(current.name)…"
                }
                let parsedSession: AudioSession
                if allowedIndices.contains(i) {
                    parsedSession = self.parseSession(current)
                } else {
                    parsedSession = current
                }
                if parsedSession.project == nil && parsed[i].fileSize > Self.maxParseSizeBytes {
                    skippedLarge += 1
                }
                parsed[i] = parsedSession
                let pct = 0.6 + 0.35 * (Double(i + 1) / Double(max(parsed.count, 1)))
                self.onMain { self.scanProgress = pct }
            }

            // 4. Done
            let scanDate = Date()
            self.onMain {
                self.sessions     = parsed
                self.scanProgress = 1.0
                self.isScanning   = false
                self.skippedLargeSessions = skippedLarge
                self.lastScanDate = scanDate
                var base = "\(parsed.count) session(s), \(foundPlugins.count) plugin(s) found"
                if cacheHits > 0 {
                    base += " (\(cacheHits) cached)"
                }
                self.statusMessage = skippedLarge > 0
                    ? "\(base), \(skippedLarge) large session(s) skipped"
                    : base
            }

            let scanRoots = self.scanRootsForStaleness()
            let rootModTimes = self.rootModTimes(for: scanRoots)
            self.persistCache(
                plugins: foundPlugins,
                sessions: parsed,
                lastScanDate: scanDate,
                skippedLargeSessions: skippedLarge,
                scanRoots: scanRoots,
                rootModTimes: rootModTimes
            )
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
    func parseIndividualSession(path: String) {
        guard let index = sessions.firstIndex(where: { $0.path == path }) else { return }
        let session = sessions[index]

        // Skip if already parsed
        if session.project != nil {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let parsed = self.parseSession(session)
            self.onMain {
                self.sessions[index] = parsed
            }
        }
    }

    // MARK: – Private helpers

    private func onMain(_ block: @escaping () -> Void) {
        DispatchQueue.main.async(execute: block)
    }

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
        cacheStaleReason = nil
        if let lastScanDate {
            statusMessage = "Loaded cached scan from \(Self.cacheDateFormatter.string(from: lastScanDate))"
        } else {
            statusMessage = "Loaded cached scan"
        }
    }

    private func persistCache(
        plugins: [AudioPlugin],
        sessions: [AudioSession],
        lastScanDate: Date?,
        skippedLargeSessions: Int,
        scanRoots: [String],
        rootModTimes: [String: Date]
    ) {
        let cache = ScanCacheStore.makeCache(
            plugins: plugins,
            sessions: sessions,
            lastScanDate: lastScanDate,
            skippedLargeSessions: skippedLargeSessions,
            scanRoots: scanRoots,
            rootModTimes: rootModTimes
        )
        let store = cacheStore
        DispatchQueue.global(qos: .utility).async {
            store.save(cache)
        }
        onMain {
            self.cachedScanRoots = scanRoots
            self.cachedRootModTimes = rootModTimes
            self.isCacheStale = false
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

    private func evaluateCacheStalenessAndAutoRescan() {
        isCacheStale = false
        cacheStaleReason = nil
        let currentRoots = scanRootsForStaleness()
        guard !cachedScanRoots.isEmpty else { return }

        if Set(currentRoots) != Set(cachedScanRoots) {
            isCacheStale = true
            cacheStaleReason = "Scan roots changed"
        } else {
            let currentTimes = rootModTimes(for: currentRoots)
            for root in currentRoots {
                guard let cachedTime = cachedRootModTimes[root],
                      let currentTime = currentTimes[root]
                else { continue }
                if currentTime > cachedTime {
                    isCacheStale = true
                    cacheStaleReason = "Updated: \(root)"
                    break
                }
            }
        }

        guard isCacheStale, autoRescanOnLaunch else { return }
        guard shouldAutoRescan() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.scanAll(keepExisting: true)
        }
    }

    private func shouldAutoRescan() -> Bool {
        guard let lastScanDate else { return true }
        return Date().timeIntervalSince(lastScanDate) > Self.autoRescanMinimumAge
    }

    private func scanRootsForStaleness() -> [String] {
        let roots = Self.systemPluginDirs + Self.userPluginDirs + customPaths
        return Array(Set(roots)).sorted()
    }

    private func scanRoots() -> [String] {
        let roots = Self.systemPluginDirs + Self.userPluginDirs + Self.defaultSessionRoots + customPaths
        return Array(Set(roots)).sorted()
    }

    private func rootModTimes(for roots: [String]) -> [String: Date] {
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

    private static let cacheDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let defaultsCustomPathsKey = "AudioEnv.customPaths"
    private static let defaultsParseAllKey = "AudioEnv.parseAllSessions"
    private static let defaultsAutoRescanKey = "AudioEnv.autoRescanOnLaunch"

    private static let legacyCustomPathsKey = "AudioEnvScanner.customPaths"
    private static let legacyParseAllKey = "AudioEnvScanner.parseAllSessions"
    private static let legacyAutoRescanKey = "AudioEnvScanner.autoRescanOnLaunch"
    private static let autoRescanMinimumAge: TimeInterval = 12 * 60 * 60

    // ── Plugin discovery ──────────────────────────────────────────

    private func discoverPlugins() -> [AudioPlugin] {
        var results: [AudioPlugin] = []
        let fm = FileManager.default

        for dir in Self.systemPluginDirs + Self.userPluginDirs {
            guard fm.fileExists(atPath: dir),
                  let enumerator = fm.enumerator(atPath: dir)
            else { continue }

            while let rel = enumerator.nextObject() as? String {
                let ext = (rel as NSString).pathExtension.lowercased()
                guard Self.pluginExts.contains(ext) else { continue }

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
    private func formatFor(_ ext: String) -> PluginFormat {
        switch ext {
        case "au", "component": return .audioUnit
        case "vst":             return .vst
        case "vst3":            return .vst3
        default:                return .aax   // aax / aaxfs / aaxplugin
        }
    }

    /// Best-effort read of a macOS bundle's Info.plist.
    private func readBundleInfo(at path: String) -> (bundleID: String?, version: String?, manufacturer: String?, auManufacturerCode: String?) {
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
    private func discoverSessions(roots: [String]) -> [AudioSession] {
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

            onMain { self.statusMessage = "Scanning \(root)…" }

            while let url = enumerator.nextObject() as? URL {
                if shouldSkipDirectory(url: url) {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard Self.sessionExts.contains(ext) else { continue }

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

    private func cleanSessionName(url: URL) -> String {
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

    private func shouldSkipDirectory(url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true
        else { return false }
        return Self.skippedDirNames.contains(url.lastPathComponent)
    }

    private func shouldSkipLogicTemplate(url: URL) -> Bool {
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

    private func shouldSkipProToolsTemplate(url: URL) -> Bool {
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

    private func parseSession(_ session: AudioSession) -> AudioSession {
        if session.fileSize > Self.maxParseSizeBytes {
            return session
        }
        if session.isBackup {
            return session
        }
        var s = session
        switch session.format {
        case .ableton:
            if let p = AbletonParser.parse(path: session.path) { s.project = .ableton(p) }
        case .logic:
            if let p = LogicParser.parse(path: session.path)   { s.project = .logic(p) }
        case .proTools:
            if let p = ProToolsParser.parse(path: session.path) { s.project = .proTools(p) }
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
                if let handle = FileHandle(forReadingAtPath: session.path) {
                    matchData = try? handle.read(upToCount: 1024 * 1024)
                    try? handle.close()
                } else {
                    matchData = nil
                }
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

        return s
    }
}
