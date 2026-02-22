import Foundation

/// Extracts whatever metadata is available from a .logicpro session bundle.
///
/// Logic Pro sessions store the bulk of their project data in a proprietary
/// binary format that cannot be fully parsed without the app.  However,
/// the bundle contains plist files with useful metadata – in particular,
/// `Alternatives/000/MetaData.plist` has structured info about tempo,
/// sample rate, track count, key, time signature, and referenced assets.
enum LogicParser {

    // MARK: – Rich metadata from Alternatives/000/MetaData.plist

    private struct RichMetadata {
        let beatsPerMinute: Double?
        let sampleRate: Int?
        let numberOfTracks: Int?
        let songKey: String?
        let songGenderKey: String?
        let songSignatureNumerator: Int?
        let songSignatureDenominator: Int?
        let hasARAPlugins: Bool?
        let audioFiles: [String]
        let samplerInstrumentsFiles: [String]
        let alchemyFiles: [String]
        let impulseResponseFiles: [String]
        let quicksamplerFiles: [String]
        let ultrabeatFiles: [String]
        let playbackFiles: [String]
        let unusedAudioFiles: [String]
    }

    /// Parse the rich MetaData.plist directly from the active alternative.
    private static func parseRichMetadataPlist(at path: String) -> RichMetadata? {
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        // BPM is stored as Int in the plist; safely convert via NSNumber
        let bpm: Double? = (dict["BeatsPerMinute"] as? NSNumber)?.doubleValue

        return RichMetadata(
            beatsPerMinute: bpm,
            sampleRate: dict["SampleRate"] as? Int,
            numberOfTracks: dict["NumberOfTracks"] as? Int,
            songKey: dict["SongKey"] as? String,
            songGenderKey: dict["SongGenderKey"] as? String,
            songSignatureNumerator: dict["SongSignatureNumerator"] as? Int,
            songSignatureDenominator: dict["SongSignatureDenominator"] as? Int,
            hasARAPlugins: (dict["HasARAPlugins"] as? Int).map { $0 != 0 },
            audioFiles: dict["AudioFiles"] as? [String] ?? [],
            samplerInstrumentsFiles: dict["SamplerInstrumentsFiles"] as? [String] ?? [],
            alchemyFiles: dict["AlchemyFiles"] as? [String] ?? [],
            impulseResponseFiles: dict["ImpulsResponsesFiles"] as? [String] ?? [],
            quicksamplerFiles: dict["QuicksamplerFiles"] as? [String] ?? [],
            ultrabeatFiles: dict["UltrabeatFiles"] as? [String] ?? [],
            playbackFiles: dict["PlaybackFiles"] as? [String] ?? [],
            unusedAudioFiles: dict["UnusedAudioFiles"] as? [String] ?? []
        )
    }

    // MARK: – ProjectInformation.plist (Logic version, alternative names)

    private struct ProjectInfo {
        let lastSavedFrom: String?
        let variantNames: [String: String]  // "0" → "My Alternative Name"
    }

    private static func parseProjectInfo(in bundlePath: String) -> ProjectInfo? {
        let path = (bundlePath as NSString).appendingPathComponent("Resources/ProjectInformation.plist")
        guard let data = FileManager.default.contents(atPath: path),
              let dict = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }

        return ProjectInfo(
            lastSavedFrom: dict["LastSavedFrom"] as? String,
            variantNames: dict["VariantNames"] as? [String: String] ?? [:]
        )
    }

    // MARK: – Main parse entry point

    static func parse(path: String, plugins: [AudioPlugin] = []) -> LogicProject? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return nil }

        let name = ((path as NSString).lastPathComponent as NSString)
                        .deletingPathExtension

        // Step 1: Parse the rich MetaData.plist from the active alternative (000)
        let richPlistPath = (path as NSString).appendingPathComponent("Alternatives/000/MetaData.plist")
        let rich = parseRichMetadataPlist(at: richPlistPath)

        // Step 2: Parse ProjectInformation.plist for Logic version + alternative names
        let projInfo = parseProjectInfo(in: path)

        // Step 3: Legacy directory scan for any other plist metadata (fallback)
        var metadata: [String: String] = [:]
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

        // Step 4: Extract fields — prefer rich plist, fall back to legacy metadata
        let tempo = rich?.beatsPerMinute ?? extractTempo(metadata)
        let sampleRate = rich?.sampleRate ?? extractSampleRate(metadata)
        let mediaFiles = discoverFiles(in: path, extensions: Self.audioExtensions)
        let midiFiles  = discoverFiles(in: path, extensions: Self.midiExtensions)
        let bouncedFiles = discoverBouncedFiles(in: path)
        let pluginHints  = extractPluginHints(in: path)

        // Step 4b: Binary parsing of ProjectData for track names and per-track plugins
        var trackNames: [String: String] = [:]
        var trackPlugins: [String: [String]] = [:]
        let projectDataCandidates = [
            (path as NSString).appendingPathComponent("Alternatives/000/ProjectData"),
            (path as NSString).appendingPathComponent("ProjectData"),
            (path as NSString).appendingPathComponent("Contents/ProjectData"),
        ]
        for dataPath in projectDataCandidates {
            if let projectData = fm.contents(atPath: dataPath) {
                trackNames = findTrackNames(in: projectData)
                trackPlugins = findChannelStripPlugins(in: projectData, plugins: plugins)
                break
            }
        }

        // Step 5: Discover alternatives, map to human-readable names if available
        let rawAlternatives = discoverAlternatives(in: path)
        let alternatives: [String]
        if let variantNames = projInfo?.variantNames, !variantNames.isEmpty {
            alternatives = rawAlternatives.map { dirName -> String in
                // Map "000" → index "0", "001" → "1", etc.
                if let idx = Int(dirName), let humanName = variantNames[String(idx)] {
                    return humanName
                }
                return dirName
            }
        } else {
            alternatives = rawAlternatives
        }

        // Step 6: Strip absolute paths to filenames for asset arrays
        let stripToFilename: ([String]) -> [String] = { paths in
            paths.map { ($0 as NSString).lastPathComponent }
        }

        // Key/time sig: treat C/major/4/4 as Logic defaults ("not set")
        let isDefaultKey = (rich?.songKey == "C") && (rich?.songGenderKey == "major")
        let isDefaultTimeSig = (rich?.songSignatureNumerator == 4) && (rich?.songSignatureDenominator == 4)

        return LogicProject(
            name: name, path: path, metadata: metadata,
            tempo: tempo, sampleRate: sampleRate,
            mediaFiles: mediaFiles, midiFiles: midiFiles,
            bouncedFiles: bouncedFiles,
            alternatives: alternatives,
            pluginHints: pluginHints,
            trackCount: rich?.numberOfTracks,
            songKey: isDefaultKey ? nil : rich?.songKey,
            songScale: isDefaultKey ? nil : rich?.songGenderKey,
            timeSignatureNumerator: isDefaultTimeSig ? nil : rich?.songSignatureNumerator,
            timeSignatureDenominator: isDefaultTimeSig ? nil : rich?.songSignatureDenominator,
            hasARAPlugins: rich?.hasARAPlugins,
            samplerInstrumentFiles: rich?.samplerInstrumentsFiles.nilIfEmpty.map(stripToFilename),
            alchemyFiles: rich?.alchemyFiles.nilIfEmpty.map(stripToFilename),
            impulseResponseFiles: rich?.impulseResponseFiles.nilIfEmpty.map(stripToFilename),
            quicksamplerFiles: rich?.quicksamplerFiles.nilIfEmpty.map(stripToFilename),
            ultrabeatFiles: rich?.ultrabeatFiles.nilIfEmpty.map(stripToFilename),
            unusedAudioFiles: rich?.unusedAudioFiles.nilIfEmpty.map(stripToFilename),
            logicVersion: projInfo?.lastSavedFrom,
            trackNames: trackNames,
            trackPlugins: trackPlugins
        )
    }

    // MARK: – Structured-field extraction (legacy fallback)

    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "caf", "flac", "alac"
    ]
    private static let midiExtensions: Set<String> = ["mid", "midi"]

    /// Pull tempo from well-known metadata keys Logic may emit.
    private static func extractTempo(_ metadata: [String: String]) -> Double? {
        for key in ["tempo", "Tempo", "BPM", "bpm", "ProjectTempo", "BeatsPerMinute"] {
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
            (bundlePath as NSString).appendingPathComponent("Alternatives/000/ProjectData"),
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

    // MARK: – Binary track name extraction (ivnE records)

    /// Names that are system/internal environment objects, not user tracks.
    private static let enviSkipNames: Set<String> = [
        "No Output", "Sequencer Input", "Physical Input", "Preview",
        "Click", "MIDI Click", "(Folder)", "Stereo Out",
    ]

    /// Marker bytes for ivnE (Environment) records.
    private static let ivnEMarker: [UInt8] = [0x69, 0x76, 0x6E, 0x45]

    /// Extract channel-strip → track-name mapping from ivnE Environment records.
    ///
    /// Each record contains a name string and a channel strip index byte that
    /// identifies which channel strip (Audio N, Aux N, etc.) the track is assigned to.
    static func findTrackNames(in data: Data) -> [String: String] {
        let bytes = [UInt8](data)
        var mapping: [String: String] = [:]

        for i in 0..<(bytes.count - 4) {
            guard bytes[i] == ivnEMarker[0],
                  bytes[i+1] == ivnEMarker[1],
                  bytes[i+2] == ivnEMarker[2],
                  bytes[i+3] == ivnEMarker[3]
            else { continue }

            let regionEnd = min(i + 400, bytes.count)
            let regionLen = regionEnd - i
            guard regionLen >= 200 else { continue }

            // Name length at offset 194 (UInt16 LE)
            let nameLen = Int(bytes[i + 194]) | (Int(bytes[i + 195]) << 8)
            guard nameLen > 0, nameLen <= 200 else { continue }
            guard i + 196 + nameLen <= bytes.count else { continue }

            let nameData = Data(bytes[(i + 196)..<(i + 196 + nameLen)])
            guard let name = String(data: nameData, encoding: .utf8) else { continue }

            // Skip system objects
            if name.hasPrefix("@") || enviSkipNames.contains(name) { continue }

            // Channel index byte sits after the name, aligned to 2-byte boundary
            var nameEnd = 196 + nameLen
            if nameEnd % 2 == 1 { nameEnd += 1 }
            guard i + nameEnd < bytes.count else { continue }
            let chanByte = bytes[i + nameEnd]

            // Decode channel strip ID
            let chan: String
            if chanByte >= 0x01 && chanByte <= 0x2B {
                chan = "Audio \(chanByte)"
            } else if chanByte >= 0x40 && chanByte <= 0x4A {
                chan = "Aux \(chanByte - 0x3F)"
            } else if chanByte >= 0x4B && chanByte <= 0x4F {
                chan = "Inst \(chanByte - 0x4A)"
            } else if chanByte == 0x64 {
                chan = "Output 1-2"
            } else {
                continue
            }

            // First-seen wins
            if mapping[chan] == nil {
                mapping[chan] = name
            }
        }

        return mapping
    }

    // MARK: – Binary channel strip plugin extraction (OCuA + embedded plists)

    /// Marker bytes for OCuA (Audio Channel Object).
    private static let ocuAMarker: [UInt8] = Array("OCuA".utf8)

    /// Channel strip name pattern (e.g. "Audio 12", "Aux 3", "Inst 1", "Output 1-2", "Bus 5").
    private static let channelStripPattern = try! NSRegularExpression(
        pattern: #"Audio \d+|Aux \d+|Inst \d+|Output \d+-\d+|Bus \d+"#
    )

    /// Decode a 4-char code from a big-endian UInt32 integer.
    private static func decodeFourCC(_ value: Int) -> String? {
        let uint = UInt32(clamping: value)
        var bytes = uint.bigEndian
        return withUnsafeBytes(of: &bytes) { buf -> String? in
            guard let ptr = buf.baseAddress else { return nil }
            let data = Data(bytes: ptr, count: 4)
            guard let s = String(data: data, encoding: .ascii),
                  s.allSatisfy({ $0.isASCII && !$0.isNewline && $0 != "\0" })
            else { return nil }
            return s
        }
    }

    /// Find all OCuA markers and extract the channel strip name from nearby bytes.
    private static func findOCuAMarkers(in bytes: [UInt8]) -> [(offset: Int, channel: String)] {
        var results: [(Int, String)] = []

        for i in 0..<(bytes.count - 4) {
            guard bytes[i] == ocuAMarker[0],
                  bytes[i+1] == ocuAMarker[1],
                  bytes[i+2] == ocuAMarker[2],
                  bytes[i+3] == ocuAMarker[3]
            else { continue }

            let regionEnd = min(i + 200, bytes.count)
            let regionData = Data(bytes[i..<regionEnd])
            // Search for channel name as ASCII in the region
            guard let regionStr = String(data: regionData, encoding: .ascii) else { continue }
            let range = NSRange(regionStr.startIndex..., in: regionStr)
            if let match = channelStripPattern.firstMatch(in: regionStr, range: range),
               let swiftRange = Range(match.range, in: regionStr) {
                results.append((i, String(regionStr[swiftRange])))
            }
        }

        return results
    }

    /// Find all embedded XML plists in the binary data. Returns (offset, plistData) pairs.
    private static func findEmbeddedPlists(in data: Data) -> [(offset: Int, data: Data)] {
        // Scan for <?xml version ... </plist> blocks using latin-1 interpretation
        guard let text = String(data: data, encoding: .isoLatin1) else { return [] }

        var results: [(Int, Data)] = []
        let xmlHeader = "<?xml version"
        let plistEnd = "</plist>"

        var searchStart = text.startIndex
        while let headerRange = text.range(of: xmlHeader, range: searchStart..<text.endIndex) {
            guard let endRange = text.range(of: plistEnd, range: headerRange.lowerBound..<text.endIndex) else {
                break
            }
            let plistString = String(text[headerRange.lowerBound..<endRange.upperBound])
            let offset = text.distance(from: text.startIndex, to: headerRange.lowerBound)
            if let plistData = plistString.data(using: .isoLatin1) {
                results.append((offset, plistData))
            }
            searchStart = endRange.upperBound
        }

        return results
    }

    /// Extract per-channel-strip plugin lists from ProjectData binary.
    ///
    /// Finds OCuA channel strip markers, then associates embedded AU plists
    /// with the nearest preceding OCuA marker. Each plist's manufacturer and
    /// subtype integers are decoded to 4-char codes for plugin identification.
    ///
    /// Plugin names are resolved by matching (manufacturer, subtype) against
    /// installed plugins' AudioComponents metadata, falling back to the raw
    /// 4-char codes only when no installed plugin matches.
    static func findChannelStripPlugins(in data: Data, plugins: [AudioPlugin] = []) -> [String: [String]] {
        let bytes = [UInt8](data)

        // Build lookup index: (manufacturer, subtype) → installed plugin
        let auIndex = buildAUIndex(from: plugins)

        // 1. Find all OCuA markers with channel names
        let ocuaList = findOCuAMarkers(in: bytes)
        guard !ocuaList.isEmpty else { return [:] }

        // 2. Find all embedded plists
        let plists = findEmbeddedPlists(in: data)

        // 3. For each plist, parse AU identity and associate with nearest preceding OCuA
        var channelPlugins: [String: [String]] = [:]

        for (plistOffset, plistData) in plists {
            guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any]
            else { continue }

            guard let mfrInt = plist["manufacturer"] as? Int,
                  let subInt = plist["subtype"] as? Int
            else { continue }

            guard let mfr = decodeFourCC(mfrInt),
                  let sub = decodeFourCC(subInt)
            else { continue }

            // Resolve name: installed plugin description > installed plugin name > raw codes
            let pluginName: String
            let auKey = "\(mfr):\(sub)"
            if let installed = auIndex[auKey] {
                pluginName = installed.auDescription ?? installed.name
            } else {
                pluginName = "\(mfr) \(sub)"
            }

            // Find the last OCuA marker before this plist
            var bestChannel: String?
            for (ocuaOffset, channel) in ocuaList {
                if ocuaOffset < plistOffset {
                    bestChannel = channel
                }
            }

            guard let channel = bestChannel else { continue }
            channelPlugins[channel, default: []].append(pluginName)
        }

        return channelPlugins
    }

    /// Build an index of installed AU plugins keyed by "manufacturer:subtype".
    /// This gives O(1) lookup when matching embedded plist identities.
    private static func buildAUIndex(from plugins: [AudioPlugin]) -> [String: AudioPlugin] {
        var index: [String: AudioPlugin] = [:]
        for plugin in plugins where plugin.format == .audioUnit {
            if let mfr = plugin.auManufacturerCode, let sub = plugin.auSubtypeCode {
                let key = "\(mfr):\(sub)"
                // First plugin wins (avoid duplicates from multiple AU registrations)
                if index[key] == nil {
                    index[key] = plugin
                }
            }
        }
        return index
    }

    // MARK: – Known-plugin matching

    /// Match AU plugin identities found in binary data against installed plugins.
    ///
    /// Uses two reliable strategies based on structured data in the binary:
    /// 1. Embedded XML plists contain `manufacturer` and `subtype` as integers,
    ///    which map 1:1 to an installed AU plugin's AudioComponents identity.
    /// 2. Raw AU type code triplets (aufx/aumu/aumf + subtype + manufacturer)
    ///    appear as 12-byte ASCII sequences, matched against installed plugins.
    ///
    /// No raw string searching is performed — plugin identification is always
    /// grounded in structured AU identity codes, not arbitrary text in the binary.
    static func matchKnownPlugins(in data: Data, against plugins: [AudioPlugin]) -> [PluginMatch] {
        // Build lookup index: "manufacturer:subtype" → installed plugin
        let auIndex = buildAUIndex(from: plugins)

        var matches: [PluginMatch] = []
        var matchedIdentities: Set<String> = []  // "mfr:sub" pairs already matched

        // Strategy 1: Match embedded plist manufacturer+subtype against installed plugins.
        // Each embedded plist represents an actual plugin instance on a channel strip.
        let embeddedPlists = findEmbeddedPlists(in: data)
        for (_, plistData) in embeddedPlists {
            guard let plist = try? PropertyListSerialization.propertyList(
                from: plistData, options: [], format: nil) as? [String: Any],
                  let mfrInt = plist["manufacturer"] as? Int,
                  let subInt = plist["subtype"] as? Int,
                  let mfr = decodeFourCC(mfrInt),
                  let sub = decodeFourCC(subInt)
            else { continue }

            let auKey = "\(mfr):\(sub)"
            guard !matchedIdentities.contains(auKey) else { continue }
            matchedIdentities.insert(auKey)

            if let installed = auIndex[auKey] {
                let displayName = installed.auDescription ?? installed.name
                matches.append(PluginMatch(name: displayName, confidence: .auCodeMatch))
            }
        }

        // Strategy 2: Match raw AU type code triplets (12-byte ASCII sequences).
        // These appear as e.g. "aufxU3BYUADx" in the binary — type(4)+subtype(4)+mfr(4).
        let auCodes = scanBinaryForAUPlugins(data)
        for code in auCodes {
            let parts = code.split(separator: ":")
            guard parts.count == 3 else { continue }
            let mfr = String(parts[2])
            let sub = String(parts[1])
            let auKey = "\(mfr):\(sub)"
            guard !matchedIdentities.contains(auKey) else { continue }
            matchedIdentities.insert(auKey)

            if let installed = auIndex[auKey] {
                let displayName = installed.auDescription ?? installed.name
                matches.append(PluginMatch(name: displayName, confidence: .auCodeMatch))
            }
        }

        return matches
    }

}

// MARK: – Array helper

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
