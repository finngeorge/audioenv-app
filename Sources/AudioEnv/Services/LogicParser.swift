import Foundation

/// Extracts whatever metadata is available from a .logicpro session bundle.
///
/// Logic Pro sessions store the bulk of their project data in a proprietary
/// binary format that cannot be fully parsed without the app.  However,
/// the bundle may contain plist files with useful metadata – this parser
/// reads every plist it can find inside the bundle and flattens the
/// key/value pairs into a simple dictionary.
enum LogicParser {

    static func parse(path: String) -> LogicProject? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }

        let name = ((path as NSString).lastPathComponent as NSString)
                        .deletingPathExtension
        var metadata: [String: String] = [:]

        // Candidate directories that may hold plist metadata.
        // Layout has varied across Logic Pro versions.
        let candidates: [String] = [
            (path as NSString).appendingPathComponent("Contents/MetaData"),
            (path as NSString).appendingPathComponent("MetaData"),
            (path as NSString).appendingPathComponent("Contents"),
            path,
        ]

        for dir in candidates {
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let fullPath = (dir as NSString).appendingPathComponent(file)
                guard let data = fm.contents(atPath: fullPath),
                      let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
                else { continue }

                for (key, value) in dict {
                    metadata[key] = "\(value)"
                }
            }
        }

        let tempo      = extractTempo(metadata)
        let sampleRate = extractSampleRate(metadata)
        let mediaFiles = discoverFiles(in: path, extensions: Self.audioExtensions)
        let midiFiles  = discoverFiles(in: path, extensions: Self.midiExtensions)
        let bouncedFiles = discoverBouncedFiles(in: path)
        let alternatives = discoverAlternatives(in: path)
        let pluginHints  = extractPluginHints(in: path)

        return LogicProject(
            name: name, path: path, metadata: metadata,
            tempo: tempo, sampleRate: sampleRate,
            mediaFiles: mediaFiles, midiFiles: midiFiles,
            bouncedFiles: bouncedFiles,
            alternatives: alternatives,
            pluginHints: pluginHints
        )
    }

    // MARK: – Structured-field extraction

    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "caf", "flac", "alac"
    ]
    private static let midiExtensions: Set<String> = ["mid", "midi"]

    /// Pull tempo from well-known metadata keys Logic may emit.
    private static func extractTempo(_ metadata: [String: String]) -> Double? {
        for key in ["tempo", "Tempo", "BPM", "bpm", "ProjectTempo"] {
            if let val = metadata[key], let d = Double(val) { return d }
        }
        return nil
    }

    /// Pull sample-rate from well-known metadata keys.
    private static func extractSampleRate(_ metadata: [String: String]) -> Int? {
        for key in ["sampleRate", "SampleRate", "sample_rate", "ProjectSampleRate"] {
            if let val = metadata[key], let d = Double(val) { return Int(d) }
        }
        return nil
    }

    /// Recursively enumerate the bundle, returning relative paths matching *extensions*.
    private static func discoverFiles(in bundlePath: String, extensions: Set<String>) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: bundlePath)
        else { return [] }

        var results: [String] = []
        while let rel = enumerator.nextObject() as? String {
            let ext = (rel as NSString).pathExtension.lowercased()
            if extensions.contains(ext) { results.append(rel) }
        }
        return results.sorted()
    }

    private static func discoverBouncedFiles(in bundlePath: String) -> [String] {
        let fm = FileManager.default
        let candidates = [
            (bundlePath as NSString).appendingPathComponent("Bounces"),
            (bundlePath as NSString).appendingPathComponent("Bounced Files"),
            (bundlePath as NSString).appendingPathComponent("Contents/Bounces"),
            (bundlePath as NSString).appendingPathComponent("Contents/Bounced Files"),
        ]

        for dir in candidates where fm.fileExists(atPath: dir) {
            let found = discoverFiles(in: dir, extensions: audioExtensions)
            if !found.isEmpty { return found }
        }
        return []
    }

    // MARK: – Alternatives discovery

    /// Enumerate the Alternatives/ subdirectory to find named alternative versions.
    private static func discoverAlternatives(in bundlePath: String) -> [String] {
        let fm = FileManager.default
        let altDirs = [
            (bundlePath as NSString).appendingPathComponent("Alternatives"),
            (bundlePath as NSString).appendingPathComponent("Contents/Alternatives"),
        ]

        for dir in altDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            let names = contents
                .filter { !$0.hasPrefix(".") }
                .sorted()
            if !names.isEmpty { return names }
        }
        return []
    }

    // MARK: – AU plugin hint extraction

    /// AU plugin type codes that appear as readable ASCII in Logic's binary ProjectData.
    private static let auTypeCodes: Set<String> = ["aufx", "aumu", "aumf"]

    /// Scan the binary ProjectData for AU plugin 4-char type codes.
    /// Returns deduplicated, sorted list of plugin identifier strings found nearby.
    private static func extractPluginHints(in bundlePath: String) -> [String] {
        let fm = FileManager.default
        let dataCandidates = [
            (bundlePath as NSString).appendingPathComponent("ProjectData"),
            (bundlePath as NSString).appendingPathComponent("Contents/ProjectData"),
        ]

        for dataPath in dataCandidates {
            guard let data = fm.contents(atPath: dataPath) else { continue }
            return scanBinaryForAUPlugins(data)
        }
        return []
    }

    /// Search binary data for AU 4-char type codes and extract nearby readable strings.
    static func scanBinaryForAUPlugins(_ data: Data) -> [String] {
        let bytes = [UInt8](data)
        var hints: Set<String> = []

        // AU plugins in Logic binary data often appear as sequences of
        // 4-char codes: type(4) + subtype(4) + manufacturer(4)
        // e.g., "aufx" + "EQxx" + "Appl" for Apple's Channel EQ
        for i in 0..<(bytes.count - 12) {
            let typeCode = String(bytes: bytes[i..<(i+4)], encoding: .ascii) ?? ""
            guard auTypeCodes.contains(typeCode) else { continue }

            // Read the next two 4-char codes (subtype + manufacturer)
            let subtype = String(bytes: bytes[(i+4)..<(i+8)], encoding: .ascii) ?? ""
            let mfr     = String(bytes: bytes[(i+8)..<(i+12)], encoding: .ascii) ?? ""

            // Validate all three are printable ASCII
            let combined = typeCode + subtype + mfr
            guard combined.count == 12,
                  combined.allSatisfy({ $0.isASCII && !$0.isNewline && $0 != "\0" })
            else { continue }

            hints.insert("\(typeCode):\(subtype):\(mfr)")
        }

        return hints.sorted()
    }

    // MARK: – Known-plugin matching

    /// Match AU plugin codes found in binary data against installed plugins.
    /// Returns an array of PluginMatch with confidence levels.
    static func matchKnownPlugins(in data: Data, against plugins: [AudioPlugin]) -> [PluginMatch] {
        let auCodes = scanBinaryForAUPlugins(data)
        var matches: [PluginMatch] = []
        var matchedNames: Set<String> = []

        // Strategy 1: Match manufacturer code from AU plugin bundleIDs
        for plugin in plugins where plugin.format == .audioUnit {
            guard !matchedNames.contains(plugin.name) else { continue }
            if let bundleID = plugin.bundleID {
                let bundleLower = bundleID.lowercased()
                for code in auCodes {
                    let parts = code.split(separator: ":")
                    guard parts.count == 3 else { continue }
                    let mfr = String(parts[2]).lowercased()
                    if bundleLower.contains(mfr) {
                        matches.append(PluginMatch(name: plugin.name, confidence: .auCodeMatch))
                        matchedNames.insert(plugin.name)
                        break
                    }
                }
            }
        }

        // Strategy 2: Search for plugin names as UTF-8 strings in the binary
        let bytes = [UInt8](data)
        for plugin in plugins {
            guard !matchedNames.contains(plugin.name) else { continue }
            guard plugin.name.count >= 4 else { continue }

            let nameBytes = Array(plugin.name.utf8)
            if containsSubsequence(bytes, nameBytes) {
                matches.append(PluginMatch(name: plugin.name, confidence: .nameMatch))
                matchedNames.insert(plugin.name)
            }
        }

        return matches
    }

    /// Check if bytes contains the given subsequence.
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
