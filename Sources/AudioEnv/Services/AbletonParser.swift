import Foundation

/// Parses an Ableton Live .als session without opening Live.
///
/// .als files are **gzip-compressed XML**.  The parser:
///   1. Decompresses via the system `/usr/bin/gunzip`.
///   2. Loads the XML into an `XMLDocument` (libxml2-backed, macOS only).
///   3. Walks well-known XPath patterns to extract tracks, tempo, plugin info, and device chains.
///
/// Plugin-name patterns differ slightly across Live 10 / 11 / 12;
/// we query every known pattern and deduplicate.
enum AbletonParser {

    // MARK: – Public entry-point

    /// Attempt to decompress and parse the .als at *path*.
    /// Returns `nil` on any I/O or XML error.
    static func parse(path: String) -> AbletonProject? {
        guard let xmlData = decompress(at: path),
              let doc     = try? XMLDocument(data: xmlData)
        else { return nil }

        let root    = doc.rootElement()
        let version = root?.attribute(forName: "MinorVersion")?.stringValue ?? "unknown"
        let tempo      = extractTempo(doc)
        let tracks     = extractTracks(doc)

        // Aggregate plugin names from both pluginInfos and legacy plugins list
        var allPluginNames = Set(tracks.flatMap { $0.plugins })
        for track in tracks {
            if let infos = track.pluginInfos {
                allPluginNames.formUnion(infos.map(\.name))
            }
        }
        let allPlugins = Array(allPluginNames).sorted()

        let samplePaths = Array(Set(tracks.flatMap { $0.clips }.compactMap { $0.samplePath })).sorted()

        let projectRoot = projectRoot(for: path)
        let projectSampleFiles = discoverFiles(in: projectRoot.appendingPathComponent("Samples"))
        let bouncedFiles = discoverBounces(in: projectRoot)

        let timeSig = extractTimeSignature(doc)
        let keyInfo = extractKey(doc)
        let sampleRate = extractSampleRate(doc)

        return AbletonProject(
            version:     version,
            tempo:       tempo,
            tracks:      tracks,
            usedPlugins: allPlugins,
            samplePaths: samplePaths,
            projectSampleFiles: projectSampleFiles,
            bouncedFiles: bouncedFiles,
            projectRootPath: projectRoot.path,
            timeSignature: timeSig.map { "\($0.numerator)/\($0.denominator)" },
            keyRoot: keyInfo?.root,
            keyScale: keyInfo?.scale,
            sampleRate: sampleRate
        )
    }

    /// Post-parse pass: match plugin info against installed plugins inventory.
    static func matchInstalledPlugins(project: inout AbletonProject, installedPlugins: [AudioPlugin]) {
        // Build AU index: "manufacturer:subtype" → plugin
        var auIndex: [String: AudioPlugin] = [:]
        // Build name index for VST/VST3 matching
        var nameIndex: [String: AudioPlugin] = [:]
        for plugin in installedPlugins {
            if plugin.format == .audioUnit,
               let mfr = plugin.auManufacturerCode,
               let sub = plugin.auSubtypeCode {
                let key = "\(mfr):\(sub)"
                if auIndex[key] == nil { auIndex[key] = plugin }
            }
            nameIndex[plugin.name.lowercased()] = plugin
        }

        var updatedTracks: [AbletonTrack] = []
        for track in project.tracks {
            guard var infos = track.pluginInfos else {
                updatedTracks.append(track)
                continue
            }
            for i in infos.indices {
                var info = infos[i]
                switch info.format {
                case "AU":
                    if let mfr = info.manufacturer, let sub = info.auSubtype {
                        let key = "\(mfr):\(sub)"
                        if auIndex[key] != nil { info.isInstalled = true }
                    }
                case "VST2", "VST3":
                    if nameIndex[info.name.lowercased()] != nil { info.isInstalled = true }
                default:
                    if nameIndex[info.name.lowercased()] != nil { info.isInstalled = true }
                }
                infos[i] = info
            }
            updatedTracks.append(AbletonTrack(
                name: track.name, type: track.type, plugins: track.plugins,
                pluginInfos: infos, deviceChain: track.deviceChain,
                clips: track.clips, isMuted: track.isMuted, isSolo: track.isSolo, color: track.color
            ))
        }
        project = AbletonProject(
            version: project.version, tempo: project.tempo, tracks: updatedTracks,
            usedPlugins: project.usedPlugins, samplePaths: project.samplePaths,
            projectSampleFiles: project.projectSampleFiles, bouncedFiles: project.bouncedFiles,
            projectRootPath: project.projectRootPath, timeSignature: project.timeSignature,
            keyRoot: project.keyRoot, keyScale: project.keyScale, sampleRate: project.sampleRate
        )
    }

    // MARK: – Decompression

    /// Decompress a gzip file by shelling out to `/usr/bin/gunzip -c`.
    /// Returns the raw XML bytes, or nil on failure.
    private static func decompress(at path: String) -> Data? {
        let proc = Process()
        proc.executableURL  = URL(fileURLWithPath: "/usr/bin/gunzip")
        proc.arguments      = ["-c", path]

        let outPipe = Pipe()
        let errPipe = Pipe()   // swallow stderr
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        do { try proc.run() } catch { return nil }

        // Read stdout *before* waitUntilExit to avoid pipe-buffer deadlock.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return data.isEmpty ? nil : data
    }

    // MARK: – Tempo

    /// Ableton stores the project tempo in `<Tempo><Manual Value="137.0"/>`.
    /// Live 10/11 used `//Transport/Tempo/Manual`; Live 12 moved it under
    /// `//MasterTrack/.../Tempo/Manual` or directly `//Tempo/Manual`.
    /// We try all known patterns and take the first match that looks like a BPM.
    private static func extractTempo(_ doc: XMLDocument) -> Double {
        let xpaths = [
            "//Transport/Tempo/Manual",    // Live 10/11
            "//MasterTrack//Tempo/Manual", // Live 12 variant
            "//Tempo/Manual",              // Broadest fallback
        ]

        for xpath in xpaths {
            guard let nodes = try? doc.nodes(forXPath: xpath) else { continue }
            for node in nodes {
                guard let el = node as? XMLElement else { continue }
                if let attrVal = el.attribute(forName: "Value")?.stringValue,
                   let value = Double(attrVal),
                   value >= 20 && value <= 999 {
                    return value
                }
            }
        }
        return 120.0
    }

    // MARK: - Time Signature

    /// Extract time signature from `<RemoteableTimeSignature>` (first occurrence).
    static func extractTimeSignature(_ doc: XMLDocument) -> (numerator: Int, denominator: Int)? {
        guard let numNodes = try? doc.nodes(forXPath: "//RemoteableTimeSignature/Numerator"),
              let denNodes = try? doc.nodes(forXPath: "//RemoteableTimeSignature/Denominator"),
              let numEl = numNodes.first as? XMLElement,
              let denEl = denNodes.first as? XMLElement,
              let num = numEl.attribute(forName: "Value")?.stringValue.flatMap({ Int($0) }),
              let den = denEl.attribute(forName: "Value")?.stringValue.flatMap({ Int($0) })
        else { return nil }
        return (num, den)
    }

    // MARK: - Scale / Key

    /// Extract key from `<ScaleInformation><Root Value="0"/><Name Value="Major"/>`.
    /// Root is a MIDI note number (0=C, 1=C#, ..., 11=B).
    static func extractKey(_ doc: XMLDocument) -> (root: String, scale: String?)? {
        guard let rootNodes = try? doc.nodes(forXPath: "//ScaleInformation/Root"),
              let rootEl = rootNodes.first as? XMLElement,
              let rootVal = rootEl.attribute(forName: "Value")?.stringValue,
              let rootInt = Int(rootVal)
        else { return nil }

        let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        let root = noteNames[rootInt % 12]

        // Name "0" means no scale set in Ableton; normalize common names
        var scaleName: String? = nil
        if let nameNodes = try? doc.nodes(forXPath: "//ScaleInformation/Name"),
           let nameEl = nameNodes.first as? XMLElement,
           let name = nameEl.attribute(forName: "Value")?.stringValue,
           name != "0" && !name.isEmpty {
            // Normalize scale names to short forms
            switch name.lowercased() {
            case "major": scaleName = "maj"
            case "minor", "natural minor": scaleName = "min"
            case "harmonic minor": scaleName = "harm min"
            case "melodic minor": scaleName = "mel min"
            case "dorian": scaleName = "dorian"
            case "mixolydian": scaleName = "mixo"
            case "phrygian": scaleName = "phryg"
            case "lydian": scaleName = "lydian"
            case "locrian": scaleName = "locrian"
            case "pentatonic": scaleName = "pent"
            case "blues": scaleName = "blues"
            default: scaleName = name
            }
        }

        return (root, scaleName)
    }

    // MARK: – Sample rate extraction

    /// Extract sample rate from the document.
    /// Queries several known locations across Live versions with sanity bounds (8000–384000).
    static func extractSampleRate(_ doc: XMLDocument) -> Int? {
        let xpaths = [
            "//MasterTrack//SampleRate/Value",
            "//SampleRate/Value",
            "//SampleRate",
        ]

        for xpath in xpaths {
            guard let nodes = try? doc.nodes(forXPath: xpath) else { continue }
            for node in nodes {
                let valueStr: String?
                if let el = node as? XMLElement {
                    valueStr = el.attribute(forName: "Value")?.stringValue ?? el.stringValue
                } else {
                    valueStr = node.stringValue
                }
                if let str = valueStr, let value = Int(str), value >= 8000, value <= 384000 {
                    return value
                }
            }
        }
        return nil
    }

    // MARK: – Tracks

    private static func extractTracks(_ doc: XMLDocument) -> [AbletonTrack] {
        var tracks: [AbletonTrack] = []

        let defs: [(xpath: String, type: AbletonTrackType)] = [
            ("//Tracks/AudioTrack",        .audio),
            ("//Tracks/MidiTrack",         .midi),
            ("//Tracks/BbTrack",           .beatBassline),
            ("//Tracks/ReturnTrack",       .returnTrack),   // Live 12
            ("//ReturnTracks/ReturnTrack", .returnTrack),   // Live 10/11
            ("//MainTrack",                .master),        // Live 12 master
            ("//MasterTrack",              .master),        // Live 10/11 master
        ]

        for def in defs {
            guard let nodes = try? doc.nodes(forXPath: def.xpath) else { continue }
            for node in nodes {
                guard let el = node as? XMLElement else { continue }
                tracks.append(parseTrack(el, type: def.type))
            }
        }
        return tracks
    }

    private static func parseTrack(_ el: XMLElement, type: AbletonTrackType) -> AbletonTrack {
        let name    = extractTrackName(el) ?? "Unnamed"
        let isMuted = extractBoolValue(el, names: ["IsMuted", "Muted"])
        let color   = extractIntValue(el, names: ["ColorIndex", "Color"])
        let pluginInfos = extractPlugins(el)
        let plugins = pluginInfos.map(\.name)
        let deviceChain = extractDeviceChain(el)
        let clips   = extractClips(el)

        return AbletonTrack(
            name: name, type: type, plugins: plugins, pluginInfos: pluginInfos,
            deviceChain: deviceChain, clips: clips, isMuted: isMuted, isSolo: false, color: color
        )
    }

    private static func extractTrackName(_ el: XMLElement) -> String? {
        let userName = firstAttributeValue(el, xpaths: [
            ".//Name/UserName/@Value",
            ".//Name/UserName/@ValueString",
        ])
        if let userName, !userName.isEmpty { return userName }

        let effectiveName = firstAttributeValue(el, xpaths: [
            ".//Name/EffectiveName/@Value",
            ".//Name/EffectiveName/@ValueString",
        ])
        if let effectiveName, !effectiveName.isEmpty { return effectiveName }

        let fallback = firstAttributeValue(el, xpaths: [
            ".//Name/Name/@Value",
            ".//Name/@Value",
        ])
        if let fallback, !fallback.isEmpty { return fallback }

        let nameElement = el.elements(forName: "Name").first?.stringValue
        return nameElement?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstAttributeValue(_ el: XMLElement, xpaths: [String]) -> String? {
        for xpath in xpaths {
            guard let nodes = try? el.nodes(forXPath: xpath) else { continue }
            if let node = nodes.first, let value = node.stringValue {
                return value
            }
        }
        return nil
    }

    private static func extractBoolValue(_ el: XMLElement, names: [String]) -> Bool {
        for name in names {
            if let node = el.elements(forName: name).first {
                if let value = node.attribute(forName: "Value")?.stringValue?.lowercased() {
                    return value == "true" || value == "1"
                }
                if let value = node.stringValue?.lowercased() {
                    return value == "true" || value == "1"
                }
            }
        }
        return false
    }

    private static func extractIntValue(_ el: XMLElement, names: [String]) -> Int? {
        for name in names {
            if let node = el.elements(forName: name).first {
                if let value = node.attribute(forName: "Value")?.stringValue, let intValue = Int(value) {
                    return intValue
                }
                if let value = node.stringValue, let intValue = Int(value) {
                    return intValue
                }
            }
        }
        return nil
    }

    // MARK: – Structured plugin extraction

    /// Collects structured plugin info from a track element.
    ///
    /// Groups XPaths by format to tag each plugin with its type:
    ///   • `Vst3PluginInfo` → "VST3"
    ///   • `VstPluginInfo`  → "VST2"
    ///   • `AuPluginInfo`   → "AU"
    ///   • Others           → "unknown"
    ///
    /// For each PluginDevice, also reads:
    ///   - UserName/@Value as preset name
    ///   - AU Manufacturer/@Value and SubType/@Value
    ///
    /// Results are deduplicated per-track by name.
    private static func extractPlugins(_ el: XMLElement) -> [AbletonPluginInfo] {
        var seen = Set<String>()
        var infos: [AbletonPluginInfo] = []

        // Format-grouped queries: (xpath, format)
        let formatQueries: [(xpath: String, format: String)] = [
            (".//Vst3PluginInfo/Name",      "VST3"),
            (".//Vst3PluginInfo/PlugName",  "VST3"),
            (".//VstPluginInfo/Name",       "VST2"),
            (".//VstPluginInfo/PlugName",   "VST2"),
            (".//AuPluginInfo/Name",        "AU"),
            (".//AuPluginInfo/PlugName",    "AU"),
            (".//PluginDesc/Name",          "unknown"),
            (".//Plug/Name",               "unknown"),
            (".//InstrumentPluginName",    "unknown"),
        ]

        for (xpath, format) in formatQueries {
            guard let nodes = try? el.nodes(forXPath: xpath) else { continue }
            for node in nodes {
                guard let name = pluginName(from: node), !name.isEmpty, !seen.contains(name) else { continue }
                seen.insert(name)

                // Walk up to PluginDevice ancestor for preset name
                var presetName: String? = nil
                var manufacturer: String? = nil
                var auSubtype: String? = nil
                var resolvedFormat = format

                let pluginDevice = findAncestor(of: node, named: "PluginDevice")

                if let pd = pluginDevice as? XMLElement {
                    // Preset: PluginDevice > UserName > @Value
                    if let userNameNodes = try? pd.nodes(forXPath: ".//UserName/@Value"),
                       let userNameVal = userNameNodes.first?.stringValue,
                       !userNameVal.isEmpty, userNameVal != name {
                        presetName = userNameVal
                    }
                }

                // For AU plugins, read Manufacturer and SubType from sibling elements
                if resolvedFormat == "AU" || resolvedFormat == "unknown" {
                    let auInfoParent = findAncestor(of: node, named: "AuPluginInfo")
                    if let auEl = auInfoParent as? XMLElement {
                        resolvedFormat = "AU"
                        if let mfrNodes = try? auEl.nodes(forXPath: "Manufacturer/@Value"),
                           let mfrVal = mfrNodes.first?.stringValue, !mfrVal.isEmpty {
                            manufacturer = mfrVal
                        }
                        if let subNodes = try? auEl.nodes(forXPath: "SubType/@Value"),
                           let subVal = subNodes.first?.stringValue, !subVal.isEmpty {
                            auSubtype = subVal
                        }
                    }
                }

                infos.append(AbletonPluginInfo(
                    name: name,
                    format: resolvedFormat,
                    presetName: presetName,
                    manufacturer: manufacturer,
                    auSubtype: auSubtype,
                    isInstalled: false
                ))
            }
        }

        return infos
    }

    private static func pluginName(from node: XMLNode) -> String? {
        if let el = node as? XMLElement {
            if let value = el.attribute(forName: "Value")?.stringValue { return value }
            if let value = el.attribute(forName: "ValueString")?.stringValue { return value }
        }
        return node.stringValue
    }

    /// Walk up the XML tree to find an ancestor element with the given name.
    private static func findAncestor(of node: XMLNode, named name: String) -> XMLNode? {
        var current = node.parent
        while let parent = current {
            if let el = parent as? XMLElement, el.name == name { return el }
            current = parent.parent
        }
        return nil
    }

    // MARK: – Device chain extraction

    /// Extracts the ordered device chain from a track element.
    /// Iterates `DeviceChain/DeviceChain/Devices/*` children in order.
    /// PluginDevice → thirdParty with full plugin info, everything else → native.
    private static func extractDeviceChain(_ el: XMLElement) -> [AbletonDeviceInfo]? {
        // Try both DeviceChain/DeviceChain/Devices and DeviceChain/Devices patterns
        let xpaths = [
            ".//DeviceChain/DeviceChain/Devices",
            ".//DeviceChain/Devices",
        ]

        var devicesElement: XMLElement?
        for xpath in xpaths {
            if let nodes = try? el.nodes(forXPath: xpath),
               let first = nodes.first as? XMLElement {
                devicesElement = first
                break
            }
        }

        guard let devicesEl = devicesElement else { return nil }
        guard let children = devicesEl.children, !children.isEmpty else { return nil }

        var devices: [AbletonDeviceInfo] = []
        for (index, child) in children.enumerated() {
            guard let deviceEl = child as? XMLElement, let deviceName = deviceEl.name else { continue }

            // Read enabled/bypass state from On/Value
            let isEnabled: Bool
            if let onNodes = try? deviceEl.nodes(forXPath: "On/@Value"),
               let onVal = onNodes.first?.stringValue {
                isEnabled = onVal.lowercased() == "true" || onVal == "1"
            } else {
                isEnabled = true
            }

            let deviceType: AbletonDeviceType
            if deviceName == "PluginDevice" {
                let pluginInfos = extractPlugins(deviceEl)
                if let info = pluginInfos.first {
                    deviceType = .thirdParty(info)
                } else {
                    deviceType = .native
                }
            } else {
                deviceType = .native
            }

            let displayName: String
            switch deviceType {
            case .thirdParty(let info):
                displayName = info.name
            case .native:
                displayName = deviceName
            }

            devices.append(AbletonDeviceInfo(
                name: displayName,
                deviceType: deviceType,
                index: index,
                isEnabled: isEnabled
            ))
        }

        return devices.isEmpty ? nil : devices
    }

    // MARK: – Clip extraction

    /// Collects audio, MIDI, and automation clips from a track element.
    ///
    /// Ableton clip containers across versions:
    ///   • `AudioClips/AudioClip`             – audio regions
    ///   • `MidiClips/MidiClip`               – MIDI regions
    ///   • `AutomationClips/AutomationClip`   – automation curves
    private static func extractClips(_ el: XMLElement) -> [AbletonClip] {
        var clips: [AbletonClip] = []

        // Audio clips
        if let nodes = try? el.nodes(forXPath: ".//AudioClips/AudioClip") {
            for node in nodes {
                guard let clipEl = node as? XMLElement else { continue }
                clips.append(AbletonClip(
                    name:       clipEl.elements(forName: "Name").first?.stringValue ?? "Audio Clip",
                    type:       .audio,
                    position:   extractNumeric(clipEl, names: ["Pos", "Position"]) ?? 0,
                    length:     extractNumeric(clipEl, names: ["Len", "Length"]) ?? 0,
                    samplePath: extractSamplePath(clipEl)
                ))
            }
        }

        // MIDI clips
        if let nodes = try? el.nodes(forXPath: ".//MidiClips/MidiClip") {
            for node in nodes {
                guard let clipEl = node as? XMLElement else { continue }
                clips.append(AbletonClip(
                    name:       clipEl.elements(forName: "Name").first?.stringValue ?? "MIDI Clip",
                    type:       .midi,
                    position:   extractNumeric(clipEl, names: ["Pos", "Position"]) ?? 0,
                    length:     extractNumeric(clipEl, names: ["Len", "Length"]) ?? 0,
                    samplePath: nil
                ))
            }
        }

        // Automation clips
        if let nodes = try? el.nodes(forXPath: ".//AutomationClips/AutomationClip") {
            for node in nodes {
                guard let clipEl = node as? XMLElement else { continue }
                clips.append(AbletonClip(
                    name:       clipEl.elements(forName: "Name").first?.stringValue ?? "Automation",
                    type:       .automation,
                    position:   extractNumeric(clipEl, names: ["Pos", "Position"]) ?? 0,
                    length:     extractNumeric(clipEl, names: ["Len", "Length"]) ?? 0,
                    samplePath: nil
                ))
            }
        }

        return clips
    }

    /// Pull a numeric value trying multiple child-element names.
    private static func extractNumeric(_ el: XMLElement, names: [String]) -> Double? {
        for name in names {
            if let child = el.elements(forName: name).first,
               let text  = child.stringValue,
               let value = Double(text) { return value }
        }
        return nil
    }

    /// Walk SampleRef children for an audio-file path (absolute preferred).
    private static func extractSamplePath(_ clipEl: XMLElement) -> String? {
        let xpaths = [
            ".//SampleRef/AbsolutePath",
            ".//SampleRef/RelativePath",
            ".//AbsolutePath",
            ".//RelativePath",
        ]
        for xpath in xpaths {
            if let nodes = try? clipEl.nodes(forXPath: xpath),
               let el    = nodes.first as? XMLElement,
               let path  = el.stringValue, !path.isEmpty { return path }
        }
        return nil
    }

    // MARK: – Project folder helpers

    private static let audioExtensions: Set<String> = [
        "wav", "aiff", "aif", "mp3", "m4a", "caf", "flac", "alac"
    ]

    private static func projectRoot(for path: String) -> URL {
        var dir = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
        if dir.lastPathComponent.lowercased() == "backups" || dir.lastPathComponent.lowercased() == "backup" {
            dir.deleteLastPathComponent()
        }
        return dir
    }

    private static func discoverFiles(in dir: URL) -> [String] {
        guard FileManager.default.fileExists(atPath: dir.path),
              let enumerator = FileManager.default.enumerator(atPath: dir.path)
        else { return [] }

        var results: [String] = []
        while let rel = enumerator.nextObject() as? String {
            let ext = (rel as NSString).pathExtension.lowercased()
            if audioExtensions.contains(ext) { results.append(rel) }
        }
        return results.sorted()
    }

    private static func discoverBounces(in root: URL) -> [String] {
        let candidates = [
            root.appendingPathComponent("Bounces"),
            root.appendingPathComponent("Bounced Files")
        ]
        for dir in candidates where FileManager.default.fileExists(atPath: dir.path) {
            let found = discoverFiles(in: dir)
            if !found.isEmpty { return found }
        }
        return []
    }
}
