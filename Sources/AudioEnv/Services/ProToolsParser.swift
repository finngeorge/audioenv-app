import Foundation

enum ProToolsParser {
    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "caf", "flac", "alac"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "mxf", "avi"
    ]

    static func parse(path: String) -> ProToolsProject? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        // Read first 1MB for metadata and plugin extraction
        let headerData = try? handle.read(upToCount: 1024 * 1024)
        let data = headerData ?? Data()
        let signatureHex = data.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")

        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? UInt64) ?? 0

        let sampleRate = extractSampleRate(from: data)
        let pluginNames = extractPluginNames(from: data)

        let root = projectRoot(for: path)
        let audioFiles = discoverFiles(in: root.appendingPathComponent("Audio Files"), extensions: audioExtensions)
        let bouncedFiles = discoverFiles(in: root.appendingPathComponent("Bounced Files"), extensions: audioExtensions)
        let videoFiles = discoverFiles(in: root.appendingPathComponent("Video Files"), extensions: videoExtensions)
        let renderedFiles = discoverFiles(in: root.appendingPathComponent("Rendered Files"), extensions: audioExtensions)

        return ProToolsProject(
            signatureHex: signatureHex,
            byteLength: size,
            sampleRate: sampleRate,
            audioFiles: audioFiles,
            bouncedFiles: bouncedFiles,
            pluginNames: pluginNames,
            videoFiles: videoFiles,
            renderedFiles: renderedFiles,
            projectRootPath: root.path
        )
    }

    // MARK: – Sample rate extraction

    /// Search header for known sample rate values as big-endian 32-bit integers.
    private static func extractSampleRate(from data: Data) -> Int? {
        let knownRates: [UInt32] = [44100, 48000, 88200, 96000, 176400, 192000]
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { return nil }

        for i in 0..<(bytes.count - 3) {
            let value = UInt32(bytes[i]) << 24
                      | UInt32(bytes[i+1]) << 16
                      | UInt32(bytes[i+2]) << 8
                      | UInt32(bytes[i+3])
            if knownRates.contains(value) {
                return Int(value)
            }
        }
        return nil
    }

    // MARK: – Plugin name extraction

    /// Search binary for readable ASCII strings near plugin-related markers.
    private static func extractPluginNames(from data: Data) -> [String] {
        let bytes = [UInt8](data)
        guard bytes.count > 16 else { return [] }

        var names: Set<String> = []
        let markers = ["aax\0", "plug", "rtas", "AAX\0", "Plug", "RTAS", "TDM\0", "AudioSuite", "AVID"]

        for marker in markers {
            let markerBytes = Array(marker.utf8)
            for i in 0..<(bytes.count - markerBytes.count) {
                guard bytes[i..<(i + markerBytes.count)].elementsEqual(markerBytes) else { continue }

                // Look for readable strings in the surrounding area
                let searchStart = max(0, i - 64)
                let searchEnd = min(bytes.count, i + 128)
                let nearbyStrings = extractReadableStrings(from: bytes, start: searchStart, end: searchEnd, minLength: 4)
                for s in nearbyStrings {
                    // Filter out common non-plugin strings
                    let lower = s.lowercased()
                    if lower == "aax" || lower == "plug" || lower == "rtas" || lower == "plugin" { continue }
                    if s.count > 3 && s.count < 64 {
                        names.insert(s)
                    }
                }
            }
        }

        return names.sorted()
    }

    /// Extract contiguous runs of printable ASCII from a byte range.
    private static func extractReadableStrings(from bytes: [UInt8], start: Int, end: Int, minLength: Int) -> [String] {
        var results: [String] = []
        var current = ""

        for i in start..<end {
            let b = bytes[i]
            if b >= 0x20 && b < 0x7F {
                current.append(Character(UnicodeScalar(b)))
            } else {
                if current.count >= minLength {
                    results.append(current)
                }
                current = ""
            }
        }
        if current.count >= minLength {
            results.append(current)
        }
        return results
    }

    private static func projectRoot(for path: String) -> URL {
        var dir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        if dir.lastPathComponent.lowercased() == "session file backups" {
            dir.deleteLastPathComponent()
        }
        return dir
    }

    private static func discoverFiles(in dir: URL, extensions: Set<String>) -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(atPath: dir.path)
        else { return [] }

        var results: [String] = []
        while let rel = enumerator.nextObject() as? String {
            let ext = (rel as NSString).pathExtension.lowercased()
            if extensions.contains(ext) { results.append(rel) }
        }
        return results.sorted()
    }

    // MARK: – Known-plugin matching

    /// Match installed plugin names and bundle IDs against binary data.
    static func matchKnownPlugins(in data: Data, against plugins: [AudioPlugin]) -> [PluginMatch] {
        let bytes = [UInt8](data)
        var matches: [PluginMatch] = []
        var matchedNames: Set<String> = []

        for plugin in plugins {
            guard !matchedNames.contains(plugin.name) else { continue }

            // Try name match
            if plugin.name.count >= 4 {
                let nameBytes = Array(plugin.name.utf8)
                if containsSubsequence(bytes, nameBytes) {
                    matches.append(PluginMatch(name: plugin.name, confidence: .nameMatch))
                    matchedNames.insert(plugin.name)
                    continue
                }
            }

            // Try bundle ID match
            if let bundleID = plugin.bundleID, bundleID.count >= 8 {
                let bundleBytes = Array(bundleID.utf8)
                if containsSubsequence(bytes, bundleBytes) {
                    matches.append(PluginMatch(name: plugin.name, confidence: .bundleIdMatch))
                    matchedNames.insert(plugin.name)
                }
            }
        }

        return matches
    }

    private static func containsSubsequence(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        let limit = haystack.count - needle.count
        for i in 0...limit {
            if haystack[i..<(i + needle.count)].elementsEqual(needle) {
                return true
            }
        }
        return false
    }
}
