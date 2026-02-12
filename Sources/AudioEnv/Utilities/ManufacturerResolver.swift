import Foundation

/// Resolves a human-readable manufacturer name from various plugin metadata sources.
enum ManufacturerResolver {

    // MARK: – Known bundleID identifiers → display names

    private static let knownManufacturers: [String: String] = [
        "fabfilter":            "FabFilter",
        "soundtoys":            "Soundtoys",
        "xfer":                 "Xfer Records",
        "xferrecords":          "Xfer Records",
        "xlnaudio":             "XLN Audio",
        "arturia":              "Arturia",
        "native-instruments":   "Native Instruments",
        "nativeinstruments":    "Native Instruments",
        "izotope":              "iZotope",
        "waves":                "Waves",
        "universalaudio":       "Universal Audio",
        "uaudio":               "Universal Audio",
        "avid":                 "Avid",
        "plugin-alliance":      "Plugin Alliance",
        "pluginalliance":       "Plugin Alliance",
        "bluecataudio":         "Blue Cat Audio",
        "valhalla":             "Valhalla DSP",
        "valhalladsp":          "Valhalla DSP",
        "u-he":                 "u-he",
        "steinberg":            "Steinberg",
        "eventide":             "Eventide",
        "sonnox":               "Sonnox",
        "ssl":                  "Solid State Logic",
        "slate-digital":        "Slate Digital",
        "slatedigital":         "Slate Digital",
        "softube":              "Softube",
        "spectrasonics":        "Spectrasonics",
        "output":               "Output",
        "kilohearts":           "Kilohearts",
        "cableguys":            "Cableguys",
        "goodhertz":            "Goodhertz",
        "neuraldsp":            "Neural DSP",
        "tokyodawn":            "Tokyo Dawn Labs",
        "tokyodawnlabs":        "Tokyo Dawn Labs",
        "audiority":            "Audiority",
        "audiothing":           "AudioThing",
        "overloud":             "Overloud",
        "cherry-audio":         "Cherry Audio",
        "cherryaudio":          "Cherry Audio",
        "amplesound":           "Ample Sound",
        "ample-sound":          "Ample Sound",
        "soniccharge":          "Sonic Charge",
        "sonic-charge":         "Sonic Charge",
        "josephlyncheski":      "Direct",
    ]

    // MARK: – AU 4-char manufacturer codes → display names

    private static let auCodeToManufacturer: [String: String] = [
        "FabF": "FabFilter",
        "SToy": "Soundtoys",
        "XFER": "Xfer Records",
        "Artu": "Arturia",
        "NiNa": "Native Instruments",
        "Ni  ": "Native Instruments",
        "iZtp": "iZotope",
        "iZot": "iZotope",
        "Wave": "Waves",
        "UADp": "Universal Audio",
        "UAud": "Universal Audio",
        "PA  ": "Plugin Alliance",
        "Uhey": "u-he",
        "VaDp": "Valhalla DSP",
        "Stbg": "Steinberg",
        "Evnt": "Eventide",
        "Snnx": "Sonnox",
        "SSLS": "Solid State Logic",
        "SltD": "Slate Digital",
        "Sftb": "Softube",
        "Spec": "Spectrasonics",
    ]

    // MARK: – TLDs and short prefixes to skip

    private static let tldPrefixes: Set<String> = [
        "com", "co", "de", "ch", "org", "net", "io", "audio", "jp", "uk", "fr", "se", "fi"
    ]

    // MARK: – Public API

    /// Extract a manufacturer identifier from a CFBundleIdentifier string.
    /// Most plugins use `com.manufacturer.pluginname` format.
    static func parseFromBundleID(_ bundleID: String?) -> String? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let parts = bundleID.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }

        let identifier: String
        if tldPrefixes.contains(parts[0].lowercased()) || parts[0].count <= 3 {
            identifier = parts[1]
        } else {
            identifier = parts[0]
        }

        let key = identifier.lowercased()
        if let known = knownManufacturers[key] { return known }
        return beautifyIdentifier(identifier)
    }

    /// Resolve an AU 4-char manufacturer code to a display name.
    static func resolveAUCode(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        return auCodeToManufacturer[code]
    }

    /// Full fallback chain to produce the best manufacturer display string.
    ///
    /// Priority:
    /// 1. Catalog manufacturer (highest — curated data)
    /// 2. BundleID-parsed manufacturer
    /// 3. AU 4-char code resolved
    /// 4. Raw plist manufacturer (if not "BNDL")
    /// 5. "Unknown"
    static func displayManufacturer(plugin: AudioPlugin, catalogManufacturer: String?) -> String {
        if let m = catalogManufacturer, !m.isEmpty { return m }
        if let m = parseFromBundleID(plugin.bundleID) { return m }
        if let m = resolveAUCode(plugin.auManufacturerCode) { return m }
        if let m = plugin.manufacturer, !m.isEmpty, m.uppercased() != "BNDL" { return m }
        return "Unknown"
    }

    // MARK: – Private helpers

    /// Turn a raw bundleID component like "native-instruments" or "fabFilter"
    /// into a human-readable form: "Native Instruments", "Fab Filter".
    static func beautifyIdentifier(_ raw: String) -> String {
        // Split on hyphens first
        let hyphenParts = raw.split(separator: "-").map(String.init)
        let expanded = hyphenParts.flatMap { insertCamelCaseSpaces($0) }
        return expanded
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Split "camelCase" into ["camel", "Case"] word boundaries.
    /// Keeps consecutive uppercase runs together: "AVID" → ["AVID"],
    /// "SoundToys" → ["Sound", "Toys"], "myAVIDPlugin" → ["my", "AVID", "Plugin"].
    private static func insertCamelCaseSpaces(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        let chars = Array(s)
        var words: [String] = []
        var current = String(chars[0])

        for i in 1..<chars.count {
            let prev = chars[i - 1]
            let cur = chars[i]
            let next: Character? = (i + 1 < chars.count) ? chars[i + 1] : nil

            if cur.isUppercase && !prev.isUppercase {
                // lowercase→UPPER: start new word ("sound|T")
                words.append(current)
                current = String(cur)
            } else if cur.isUppercase && prev.isUppercase && next != nil && !next!.isUppercase {
                // UPPER→UPPER→lower: the last upper starts a new word ("AVI|Dp" → "AVI", "Dp")
                words.append(current)
                current = String(cur)
            } else {
                current.append(cur)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}
