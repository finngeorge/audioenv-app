import Foundation

struct ScanCache: Codable {
    let version: Int
    let createdAt: Date
    let lastScanDate: Date?
    let skippedLargeSessions: Int
    let scanRoots: [String]
    let rootModTimes: [String: Date]
    let pluginDirModTimes: [String: Date]
    let plugins: [AudioPlugin]
    let sessions: [AudioSession]
}

final class ScanCacheStore {
    private static let currentVersion = 6
    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.decoder = decoder
    }

    func load() -> ScanCache? {
        if let url = cacheURL(), let data = try? Data(contentsOf: url),
           let cache = try? decoder.decode(ScanCache.self, from: data),
           cache.version == Self.currentVersion {
            return cache
        }

        if let url = legacyCacheURL(), let data = try? Data(contentsOf: url),
           let cache = try? decoder.decode(ScanCache.self, from: data),
           cache.version == Self.currentVersion {
            save(ScanCache(
                version: cache.version,
                createdAt: cache.createdAt,
                lastScanDate: cache.lastScanDate,
                skippedLargeSessions: cache.skippedLargeSessions,
                scanRoots: cache.scanRoots,
                rootModTimes: cache.rootModTimes,
                pluginDirModTimes: [:],
                plugins: cache.plugins,
                sessions: cache.sessions
            ))
            return cache
        }

        return nil
    }

    func save(_ cache: ScanCache) {
        guard let url = cacheURL() else { return }
        guard let data = try? encoder.encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func clear() {
        guard let url = cacheURL() else { return }
        try? fm.removeItem(at: url)
    }

    private func cacheURL() -> URL? {
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("AudioEnv", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("scan-cache.json")
    }

    private func legacyCacheURL() -> URL? {
        guard let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("AudioEnvScanner", isDirectory: true)
        return dir.appendingPathComponent("scan-cache.json")
    }

    static func makeCache(
        plugins: [AudioPlugin],
        sessions: [AudioSession],
        lastScanDate: Date?,
        skippedLargeSessions: Int,
        scanRoots: [String],
        rootModTimes: [String: Date],
        pluginDirModTimes: [String: Date]
    ) -> ScanCache {
        ScanCache(
            version: currentVersion,
            createdAt: Date(),
            lastScanDate: lastScanDate,
            skippedLargeSessions: skippedLargeSessions,
            scanRoots: scanRoots,
            rootModTimes: rootModTimes,
            pluginDirModTimes: pluginDirModTimes,
            plugins: plugins,
            sessions: sessions
        )
    }
}
