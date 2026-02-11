import Foundation

/// Handles intelligent deduplication of plugins across multiple formats
/// Prefers VST3 > AU > VST > AAX by default
struct PluginDeduplicator {

    enum PreferredFormat: String, CaseIterable {
        case vst3 = "VST3"
        case au = "AU"
        case vst = "VST"
        case aax = "AAX"

        var priority: Int {
            switch self {
            case .vst3: return 0
            case .au: return 1
            case .vst: return 2
            case .aax: return 3
            }
        }
    }

    /// Groups plugins by unique identity (bundleID or normalized name)
    /// Returns only the preferred format for each plugin
    static func deduplicate(_ plugins: [AudioPlugin], preferFormat: PreferredFormat = .vst3) -> [AudioPlugin] {
        // Group by bundle ID (most reliable) or by normalized name
        var pluginGroups: [String: [AudioPlugin]] = [:]

        for plugin in plugins {
            let key = plugin.bundleID ?? normalizePluginName(plugin.name)
            pluginGroups[key, default: []].append(plugin)
        }

        // For each group, select the best format
        return pluginGroups.values.compactMap { group in
            selectPreferredPlugin(from: group, preferFormat: preferFormat)
        }
    }

    /// Selects the preferred plugin from a group of duplicates
    private static func selectPreferredPlugin(from plugins: [AudioPlugin], preferFormat: PreferredFormat) -> AudioPlugin? {
        // Sort by format priority
        let sorted = plugins.sorted { plugin1, plugin2 in
            let format1 = PreferredFormat(rawValue: plugin1.format.rawValue) ?? .aax
            let format2 = PreferredFormat(rawValue: plugin2.format.rawValue) ?? .aax
            return format1.priority < format2.priority
        }

        // Return the highest priority plugin
        return sorted.first
    }

    /// Normalizes plugin name for grouping (removes version numbers, common prefixes)
    private static func normalizePluginName(_ name: String) -> String {
        var normalized = name.lowercased()

        // Remove common manufacturer prefixes
        let prefixes = ["uaudio_", "uad_", "fabfilter ", "waves ", "native instruments ", "ni_"]
        for prefix in prefixes {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
            }
        }

        // Remove version numbers (e.g., "v2", "3.0", "mk2")
        normalized = normalized.replacingOccurrences(of: #"\s*v?\d+(\.\d+)*\s*"#, with: " ", options: .regularExpression)
        normalized = normalized.replacingOccurrences(of: #"\s+mk\d+\s*"#, with: " ", options: .regularExpression)

        // Remove extra whitespace
        normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        normalized = normalized.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        return normalized
    }

    /// Calculates backup size reduction from deduplication
    static func calculateSavings(original: [AudioPlugin], deduplicated: [AudioPlugin]) -> BackupStats {
        let originalSize = original.reduce(0) { $0 + getPluginSize($1) }
        let deduplicatedSize = deduplicated.reduce(0) { $0 + getPluginSize($1) }

        return BackupStats(
            originalCount: original.count,
            deduplicatedCount: deduplicated.count,
            originalSizeBytes: originalSize,
            deduplicatedSizeBytes: deduplicatedSize,
            savedBytes: originalSize - deduplicatedSize,
            savedPercentage: originalSize > 0 ? Double(originalSize - deduplicatedSize) / Double(originalSize) * 100 : 0
        )
    }

    private static func getPluginSize(_ plugin: AudioPlugin) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: plugin.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }
}

struct BackupStats {
    let originalCount: Int
    let deduplicatedCount: Int
    let originalSizeBytes: Int64
    let deduplicatedSizeBytes: Int64
    let savedBytes: Int64
    let savedPercentage: Double

    var formattedOriginalSize: String {
        ByteCountFormatter.string(fromByteCount: originalSizeBytes, countStyle: .file)
    }

    var formattedDeduplicatedSize: String {
        ByteCountFormatter.string(fromByteCount: deduplicatedSizeBytes, countStyle: .file)
    }

    var formattedSavings: String {
        ByteCountFormatter.string(fromByteCount: savedBytes, countStyle: .file)
    }
}

// MARK: - Example Usage

extension ScannerService {
    /// Prepares plugins for backup with deduplication
    func preparePluginsForBackup(preferFormat: PluginDeduplicator.PreferredFormat = .vst3) -> (plugins: [AudioPlugin], stats: BackupStats) {
        let deduplicated = PluginDeduplicator.deduplicate(plugins, preferFormat: preferFormat)
        let stats = PluginDeduplicator.calculateSavings(original: plugins, deduplicated: deduplicated)
        return (deduplicated, stats)
    }
}
