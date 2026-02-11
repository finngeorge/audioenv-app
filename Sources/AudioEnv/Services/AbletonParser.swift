import Foundation

/// Parses an Ableton Live .als session without opening Live.
///
/// .als files are **gzip-compressed XML**.  The parser:
///   1. Decompresses via the system `/usr/bin/gunzip`.
///   2. Loads the XML into an `XMLDocument` (libxml2-backed, macOS only).
///   3. Walks well-known XPath patterns to extract tracks, tempo, and plugin names.
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
        let allPlugins  = Array(Set(tracks.flatMap { $0.plugins })).sorted()
        let samplePaths = Array(Set(tracks.flatMap { $0.clips }.compactMap { $0.samplePath })).sorted()

        let projectRoot = projectRoot(for: path)
        let projectSampleFiles = discoverFiles(in: projectRoot.appendingPathComponent("Samples"))
        let bouncedFiles = discoverBounces(in: projectRoot)

        return AbletonProject(
            version:     version,
            tempo:       tempo,
            tracks:      tracks,
            usedPlugins: allPlugins,
            samplePaths: samplePaths,
            projectSampleFiles: projectSampleFiles,
            bouncedFiles: bouncedFiles,
            projectRootPath: projectRoot.path
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

    /// Ableton stores the project tempo at  LiveSet > Transport > Tempo > Manual
    /// The element is typically `<Manual Value="128.0"/>` (self-closing with attribute).
    private static func extractTempo(_ doc: XMLDocument) -> Double {
        guard let nodes = try? doc.nodes(forXPath: "//Transport/Tempo/Manual"),
              let el    = nodes.first as? XMLElement
        else { return 120.0 }

        // Self-closing elements store the value as an attribute, not text content
        if let attrVal = el.attribute(forName: "Value")?.stringValue,
           let value = Double(attrVal) {
            return value
        }
        if let raw = el.stringValue, let value = Double(raw) {
            return value
        }
        return 120.0
    }

    // MARK: – Tracks

    private static func extractTracks(_ doc: XMLDocument) -> [AbletonTrack] {
        var tracks: [AbletonTrack] = []

        let defs: [(xpath: String, type: AbletonTrackType)] = [
            ("//Tracks/AudioTrack",        .audio),
            ("//Tracks/MidiTrack",         .midi),
            ("//Tracks/BbTrack",           .beatBassline),
            ("//ReturnTracks/ReturnTrack", .returnTrack),
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
        let plugins = extractPluginNames(el)
        let clips   = extractClips(el)

        return AbletonTrack(
            name: name, type: type, plugins: plugins, clips: clips,
            isMuted: isMuted, isSolo: false, color: color
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

    // MARK: – Plugin-name extraction

    /// Collects plugin names from a track element.
    ///
    /// Known XML patterns (across Live versions):
    ///   • `.//PluginDesc/Name`           – native instruments & effects (Live 10+)
    ///   • `.//Plug/Name`                 – some third-party / older layouts
    ///   • `.//InstrumentPluginName`      – legacy instrument reference
    ///   • `.//VstPluginInfo/PlugName`    – VST2
    ///   • `.//Vst3PluginInfo/PlugName`   – VST3
    ///   • `.//AuPluginInfo/PlugName`     – AU
    ///
    /// Results are deduplicated per-track.
    private static func extractPluginNames(_ el: XMLElement) -> [String] {
        var names: [String] = []

        let xpaths = [
            ".//PluginDesc/Name",
            ".//Plug/Name",
            ".//InstrumentPluginName",
            ".//VstPluginInfo/PlugName",
            ".//Vst3PluginInfo/PlugName",
            ".//AuPluginInfo/PlugName",
        ]

        for xpath in xpaths {
            guard let nodes = try? el.nodes(forXPath: xpath) else { continue }
            names += nodes.compactMap { pluginName(from: $0) }
        }

        return Array(Set(names.filter { !$0.isEmpty }))
    }

    private static func pluginName(from node: XMLNode) -> String? {
        if let el = node as? XMLElement {
            if let value = el.attribute(forName: "Value")?.stringValue { return value }
            if let value = el.attribute(forName: "ValueString")?.stringValue { return value }
        }
        return node.stringValue
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
