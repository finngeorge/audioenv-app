import Foundation
import AppKit

struct PluginCatalog: Codable {
    let version: Int
    let plugins: [PluginCatalogEntry]
}

struct PluginCatalogEntry: Codable {
    let name: String
    let manufacturer: String?
    let img: String?
    let aliases: [String]?
    let category: String?
    let description: String?
    let price: String?
    let formats: [String]?
    let bundleIdHint: String?
}

final class PluginCatalogStore {
    private var byName: [String: PluginCatalogEntry] = [:]
    private var byNormalized: [String: PluginCatalogEntry] = [:]
    private(set) var pluginCount: Int = 0

    /// Resource bundle — tries nested SPM resource bundle, then main bundle.
    private static let resourceBundle: Bundle = {
        // SPM .app bundles: Contents/Resources/AudioEnv_AudioEnv.bundle
        if let resourceURL = Bundle.main.resourceURL {
            let nested = resourceURL.appendingPathComponent("AudioEnv_AudioEnv.bundle")
            if let bundle = Bundle(path: nested.path) {
                return bundle
            }
        }
        // SPM `swift run`: resource bundle is next to the executable
        if let execURL = Bundle.main.executableURL {
            let adjacent = execURL.deletingLastPathComponent()
                .appendingPathComponent("AudioEnv_AudioEnv.bundle")
            if let bundle = Bundle(path: adjacent.path) {
                return bundle
            }
        }
        return Bundle.main
    }()

    init() {
        load()
    }

    func lookup(name: String) -> PluginCatalogEntry? {
        for candidate in Self.candidateNames(for: name) {
            if let entry = byName[candidate.lowercased()] { return entry }
        }
        for candidate in Self.candidateNames(for: name) {
            let normalized = Self.normalize(candidate)
            if let entry = byNormalized[normalized] { return entry }
        }
        return nil
    }

    func image(named filename: String) -> NSImage? {
        guard let url = imageURL(named: filename) else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    func imageURL(named filename: String) -> URL? {
        let bundle = Self.resourceBundle
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        // SwiftPM .process() flattens plugin_imgs/ so images are at bundle root
        if !ext.isEmpty,
           let url = bundle.url(forResource: base, withExtension: ext) {
            return url
        }
        // Also try with subdirectory (for non-SwiftPM bundles)
        if !ext.isEmpty,
           let url = bundle.url(forResource: base, withExtension: ext, subdirectory: "plugin_imgs") {
            return url
        }
        return bundle.url(forResource: filename, withExtension: nil)
            ?? bundle.url(forResource: filename, withExtension: nil, subdirectory: "plugin_imgs")
    }

    private func load() {
        let bundle = Self.resourceBundle
        guard let url = bundle.url(forResource: "plugin_catalog", withExtension: "json") else {
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        guard let catalog = try? decoder.decode(PluginCatalog.self, from: data) else { return }
        var nameMap: [String: PluginCatalogEntry] = [:]
        var normalizedMap: [String: PluginCatalogEntry] = [:]
        for plugin in catalog.plugins {
            nameMap[plugin.name.lowercased()] = plugin
            normalizedMap[Self.normalize(plugin.name)] = plugin
            if let aliases = plugin.aliases {
                for alias in aliases {
                    nameMap[alias.lowercased()] = plugin
                    normalizedMap[Self.normalize(alias)] = plugin
                }
            }
            for extra in Self.catalogExtraNames(for: plugin.name, manufacturer: plugin.manufacturer) {
                nameMap[extra.lowercased()] = plugin
                normalizedMap[Self.normalize(extra)] = plugin
            }
        }
        byName = nameMap
        byNormalized = normalizedMap
        pluginCount = catalog.plugins.count
    }

    private static func normalize(_ name: String) -> String {
        let scalars = name.lowercased().unicodeScalars
        let filtered = scalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(filtered))
    }

    private static func candidateNames(for name: String) -> [String] {
        var results: [String] = [name]
        if let cleaned = uaudioCleanedName(from: name, dropSuffixes: false) {
            results.append(cleaned)
        }
        if let cleaned = uaudioCleanedName(from: name, dropSuffixes: true) {
            results.append(cleaned)
        }
        if let stripped = stripUaudioPrefix(from: name) {
            results.append(stripped)
        }
        if let strippedFab = stripFabFilterPrefix(from: name) {
            results.append(strippedFab)
        }
        return Array(Set(results))
    }

    private static func catalogExtraNames(for name: String, manufacturer: String?) -> [String] {
        var results: [String] = []
        if let cleaned = uaudioCleanedName(from: name, dropSuffixes: true) {
            results.append(cleaned)
        }
        if let stripped = stripUaudioPrefix(from: name) {
            results.append(stripped)
        }
        if let manufacturer, manufacturer.lowercased() == "fabfilter" {
            if !name.lowercased().hasPrefix("fabfilter ") {
                results.append("FabFilter \(name)")
            }
        }
        return results
    }

    private static func stripUaudioPrefix(from name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasPrefix("uaudio_") || lower.hasPrefix("uaudio-") {
            return String(name.dropFirst(7))
        }
        if lower.hasPrefix("uad_") || lower.hasPrefix("uad-") || lower.hasPrefix("uad ") {
            return String(name.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func stripFabFilterPrefix(from name: String) -> String? {
        let lower = name.lowercased()
        if lower.hasPrefix("fabfilter ") {
            return String(name.dropFirst("FabFilter ".count))
        }
        return nil
    }

    private static func uaudioCleanedName(from name: String, dropSuffixes: Bool) -> String? {
        let lower = name.lowercased()
        guard lower.hasPrefix("uaudio_") || lower.hasPrefix("uaudio-") || lower.hasPrefix("uad_") || lower.hasPrefix("uad-") || lower.hasPrefix("uad ") else {
            return nil
        }
        var raw = name
        if let stripped = stripUaudioPrefix(from: name) {
            raw = stripped
        }
        raw = raw.replacingOccurrences(of: "-", with: "_")
        var parts = raw.split(separator: "_").map { String($0) }
        if dropSuffixes, let last = parts.last?.lowercased(), last == "tape" {
            parts.removeLast()
        }
        let words = parts.map { beautifyToken($0) }
        return words.joined(separator: " ")
    }

    private static func beautifyToken(_ token: String) -> String {
        if token.isEmpty { return token }
        if token.allSatisfy({ $0.isNumber }) { return token }
        if token.contains("-") {
            let parts = token.split(separator: "-").map { beautifyToken(String($0)) }
            return parts.joined(separator: "-")
        }
        let lower = token.lowercased()
        if lower.count <= 3 && lower.allSatisfy({ $0.isLetter }) {
            return lower.uppercased()
        }
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }
}
