import Foundation

// MARK: – Plugin format

enum PluginFormat: String, CaseIterable, Identifiable, Codable {
    case audioUnit = "AU"
    case vst       = "VST"
    case vst3      = "VST3"
    case aax       = "AAX"

    var id: String { rawValue }
}

// MARK: – Plugin model

/// Represents a single audio plugin bundle found on disk.
struct AudioPlugin: Identifiable, Hashable, Codable {
    let id:           UUID
    let name:         String          /// display name (bundle filename sans extension)
    let path:         String          /// full path on disk
    let format:       PluginFormat
    let bundleID:            String?  /// CFBundleIdentifier from Info.plist
    let version:             String?  /// CFBundleShortVersionString
    let manufacturer:        String?  /// CFBundlePackageType (best-effort)
    let auManufacturerCode:  String?  /// AudioComponents[0].manufacturer (AU 4-char code)
    let auSubtypeCode:       String?  /// AudioComponents[0].subtype (AU 4-char code)
    let auDescription:       String?  /// AU display name (from system component registry, same as DAWs)

    init(name: String, path: String, format: PluginFormat,
         bundleID: String? = nil, version: String? = nil,
         manufacturer: String? = nil, auManufacturerCode: String? = nil,
         auSubtypeCode: String? = nil, auDescription: String? = nil) {
        self.id                 = UUID()
        self.name               = name
        self.path               = path
        self.format             = format
        self.bundleID           = bundleID
        self.version            = version
        self.manufacturer       = manufacturer
        self.auManufacturerCode = auManufacturerCode
        self.auSubtypeCode      = auSubtypeCode
        self.auDescription      = auDescription
    }

    // Equality / hashing driven by on-disk path (stable identity)
    static func == (lhs: AudioPlugin, rhs: AudioPlugin) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher)                        { hasher.combine(path) }
}

// MARK: – Plugin group (stacked by name)

/// Groups multiple format variants of the same plugin into a single list item.
struct PluginGroup: Identifiable, Hashable {
    let name: String
    let plugins: [AudioPlugin]

    var id: String { name.lowercased() }
    var formats: [PluginFormat] { plugins.map(\.format).sorted { $0.rawValue < $1.rawValue } }
    var primaryPlugin: AudioPlugin { plugins.first! }
    var manufacturer: String? { plugins.compactMap(\.manufacturer).first }
    var version: String? { plugins.compactMap(\.version).first }
    var isMultiFormat: Bool { plugins.count > 1 }

    /// Group a flat list of plugins by name.
    static func grouped(from plugins: [AudioPlugin]) -> [PluginGroup] {
        let dict = Dictionary(grouping: plugins) { $0.name.lowercased() }
        return dict.values
            .map { variants in
                let sorted = variants.sorted { $0.format.rawValue < $1.format.rawValue }
                return PluginGroup(name: sorted.first!.name, plugins: sorted)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func == (lhs: PluginGroup, rhs: PluginGroup) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: – Plugin match confidence

/// Confidence level for plugin matches found via binary scanning.
enum PluginMatchConfidence: String, Codable, Comparable {
    case auCodeMatch = "AU Code Match"     // High: matched AU type+subtype+manufacturer
    case bundleIdMatch = "Bundle ID Match" // High: found bundle ID in binary
    case nameMatch = "Name Match"          // Medium: found plugin name string in binary

    private var sortOrder: Int {
        switch self {
        case .auCodeMatch: return 0
        case .bundleIdMatch: return 1
        case .nameMatch: return 2
        }
    }

    static func < (lhs: PluginMatchConfidence, rhs: PluginMatchConfidence) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: – Plugin match result

struct PluginMatch: Codable, Hashable {
    let name: String
    let confidence: PluginMatchConfidence
}
