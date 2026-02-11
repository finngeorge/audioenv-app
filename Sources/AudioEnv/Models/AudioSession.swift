import Foundation

// MARK: – Session format

enum SessionFormat: String, CaseIterable, Identifiable, Codable {
    case ableton = "Ableton Live"
    case logic   = "Logic Pro"
    case proTools = "Pro Tools"

    var id: String { rawValue }
}

// MARK: – Parsed-project wrapper

/// Holds the result of successfully parsing a session file.
/// Not required to be Hashable – AudioSession provides its own hash via path.
enum ParsedProject: Codable {
    case ableton(AbletonProject)
    case logic(LogicProject)
    case proTools(ProToolsProject)

    private enum CodingKeys: String, CodingKey { case type, value }
    private enum ProjectType: String, Codable { case ableton, logic, proTools }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(ProjectType.self, forKey: .type)
        switch type {
        case .ableton:
            let value = try container.decode(AbletonProject.self, forKey: .value)
            self = .ableton(value)
        case .logic:
            let value = try container.decode(LogicProject.self, forKey: .value)
            self = .logic(value)
        case .proTools:
            let value = try container.decode(ProToolsProject.self, forKey: .value)
            self = .proTools(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ableton(let value):
            try container.encode(ProjectType.ableton, forKey: .type)
            try container.encode(value, forKey: .value)
        case .logic(let value):
            try container.encode(ProjectType.logic, forKey: .type)
            try container.encode(value, forKey: .value)
        case .proTools(let value):
            try container.encode(ProjectType.proTools, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }
}

// MARK: – Session model

/// Represents a single DAW session file found on disk.
struct AudioSession: Identifiable, Hashable, Codable {
    let name:         String          /// session name (filename sans extension)
    let path:         String          /// full path on disk
    let format:       SessionFormat
    let modifiedDate: Date
    let fileSize:     UInt64          /// bytes on disk
    var project:      ParsedProject?  /// populated after parsing
    var knownPluginMatches: [PluginMatch]?  /// populated after known-plugin matching

    init(name: String, path: String, format: SessionFormat,
         modifiedDate: Date, fileSize: UInt64, project: ParsedProject? = nil,
         knownPluginMatches: [PluginMatch]? = nil) {
        self.name         = name
        self.path         = path
        self.format       = format
        self.modifiedDate = modifiedDate
        self.fileSize     = fileSize
        self.project      = project
        self.knownPluginMatches = knownPluginMatches
    }

    /// Stable identity driven by on-disk path.
    var id: String { path }

    // Equality / hashing driven by on-disk path (stable identity)
    static func == (lhs: AudioSession, rhs: AudioSession) -> Bool { lhs.path == rhs.path }
    func hash(into hasher: inout Hasher)                          { hasher.combine(path) }
}

// MARK: – Derived helpers

extension AudioSession {
    /// Heuristic to mark Ableton autosaves / backups as lower-priority sessions.
    var isBackup: Bool {
        switch format {
        case .ableton:
            let lowerName = name.lowercased()
            if lowerName.contains("backup") || lowerName.contains("auto-save") || lowerName.contains("autosave") {
                return true
            }
            let lowerPath = path.lowercased()
            return lowerPath.contains("/backups/") || lowerPath.contains("/backup/")
        case .proTools:
            let lowerPath = path.lowercased()
            if lowerPath.contains("/session file backups/") { return true }
            return proToolsBackupSuffix(in: (path as NSString).lastPathComponent)
        case .logic:
            return false
        }
    }

    /// Normalized project name for grouping sessions.
    var projectDisplayName: String {
        switch format {
        case .ableton:
            return projectFolderName() ?? normalizeAbletonName(name)
        case .proTools:
            return projectFolderName() ?? name
        case .logic:
            return projectFolderName() ?? name
        }
    }

    /// Stable key to group sessions under the same project folder.
    var projectGroupKey: String {
        switch format {
        case .ableton, .proTools:
            var dir = (path as NSString).deletingLastPathComponent
            if dir.lowercased().hasSuffix("/backups") || dir.lowercased().hasSuffix("/backup") {
                dir = (dir as NSString).deletingLastPathComponent
            }
            return "\(dir.lowercased())::\(projectDisplayName.lowercased())"
        case .logic:
            // Logic bundles (.logicx) are the session file itself; group by parent directory
            let dir = (path as NSString).deletingLastPathComponent
            return "\(dir.lowercased())::\(projectDisplayName.lowercased())"
        }
    }

    private func normalizeAbletonName(_ raw: String) -> String {
        let suffixes = [
            " [auto-save]",
            " [auto save]",
            " auto-save",
            " auto save",
            " (backup)",
            " - backup",
            " backup",
            "_backup",
            " autosave"
        ]
        let lower = raw.lowercased()
        for suffix in suffixes {
            if lower.hasSuffix(suffix) {
                return String(raw.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func projectFolderName() -> String? {
        var dir = (path as NSString).deletingLastPathComponent
        if dir.lowercased().hasSuffix("/backups") || dir.lowercased().hasSuffix("/backup") {
            dir = (dir as NSString).deletingLastPathComponent
        }
        let folder = (dir as NSString).lastPathComponent
        return folder.isEmpty ? nil : folder
    }

    private func proToolsBackupSuffix(in filename: String) -> Bool {
        let lower = filename.lowercased()
        guard let bakRange = lower.range(of: ".bak.") else { return false }
        let suffix = lower[bakRange.upperBound...]
        let digits = suffix.prefix(3)
        return digits.count == 3 && digits.allSatisfy { $0.isNumber }
    }
}
