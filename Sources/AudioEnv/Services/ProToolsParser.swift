import Foundation
import os

enum ProToolsParser {
    private static let logger = Logger(subsystem: "com.audioenv", category: "ProToolsParser")

    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "caf", "flac", "alac"
    ]
    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "mxf", "avi"
    ]

    /// Maximum files to collect per subdirectory to prevent runaway enumeration.
    private static let maxFilesPerDirectory = 500

    static func parse(path: String) -> ProToolsProject? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 1024 * 1024)) ?? Data()
        return parse(data: data, path: path)
    }

    /// Parse a Pro Tools session from pre-read data. Use this to avoid reading the file twice
    /// when the caller also needs the raw data for plugin matching.
    static func parse(data: Data, path: String) -> ProToolsProject? {
        let start = CFAbsoluteTimeGetCurrent()
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

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("Parsed \(path, privacy: .public) in \(elapsed, format: .fixed(precision: 3))s (data=\(data.count)B, plugins=\(pluginNames.count), audio=\(audioFiles.count))")

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
    /// Limits search to the first 64 KB where PT stores session metadata.
    private static func extractSampleRate(from data: Data) -> Int? {
        let knownRates: Set<UInt32> = [44100, 48000, 88200, 96000, 176400, 192000]
        let searchLimit = min(data.count, 65_536)
        guard searchLimit >= 4 else { return nil }

        return data.withUnsafeBytes { raw -> Int? in
            let ptr = raw.bindMemory(to: UInt8.self)
            for i in 0..<(searchLimit - 3) {
                let value = UInt32(ptr[i]) << 24
                          | UInt32(ptr[i+1]) << 16
                          | UInt32(ptr[i+2]) << 8
                          | UInt32(ptr[i+3])
                if knownRates.contains(value) {
                    return Int(value)
                }
            }
            return nil
        }
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
            if extensions.contains(ext) {
                results.append(rel)
                if results.count >= maxFilesPerDirectory {
                    logger.warning("File enumeration capped at \(maxFilesPerDirectory) in \(dir.path, privacy: .public)")
                    break
                }
            }
        }
        return results.sorted()
    }

    // MARK: – Known-plugin matching

    /// Match installed plugin names and bundle IDs against binary data.
    /// Uses Data.range(of:) for optimised searching instead of manual byte iteration.
    static func matchKnownPlugins(in data: Data, against plugins: [AudioPlugin]) -> [PluginMatch] {
        let start = CFAbsoluteTimeGetCurrent()
        var matches: [PluginMatch] = []
        var matchedNames: Set<String> = []

        for plugin in plugins {
            guard !matchedNames.contains(plugin.name) else { continue }

            // Try name match
            if plugin.name.count >= 4 {
                let nameData = Data(plugin.name.utf8)
                if data.range(of: nameData) != nil {
                    matches.append(PluginMatch(name: plugin.name, confidence: .nameMatch))
                    matchedNames.insert(plugin.name)
                    continue
                }
            }

            // Try bundle ID match
            if let bundleID = plugin.bundleID, bundleID.count >= 8 {
                let bundleData = Data(bundleID.utf8)
                if data.range(of: bundleData) != nil {
                    matches.append(PluginMatch(name: plugin.name, confidence: .bundleIdMatch))
                    matchedNames.insert(plugin.name)
                }
            }
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        logger.info("matchKnownPlugins: \(plugins.count) plugins checked in \(elapsed, format: .fixed(precision: 3))s → \(matches.count) matches")
        return matches
    }
}
