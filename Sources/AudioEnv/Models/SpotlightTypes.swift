import Foundation
import SwiftUI

// MARK: - Command Verbs (mirrors web app's COMMAND_VERBS)

enum SpotlightVerb: String, CaseIterable {
    case play
    case download
    case go
    case share
    case queue
    case open

    var aliases: [String] {
        switch self {
        case .play: return ["p"]
        case .download: return ["d", "dl"]
        case .go: return ["g"]
        case .share: return ["sh"]
        case .queue: return ["q", "add"]
        case .open: return ["o"]
        }
    }

    var targetTypes: [SpotlightResultType] {
        switch self {
        case .play: return [.bounce]
        case .download: return [.bounce]
        case .go: return SpotlightResultType.allCases
        case .share: return [.project]
        case .queue: return [.bounce]
        case .open: return [.project]
        }
    }

    var label: String {
        switch self {
        case .play: return "Play"
        case .download: return "Download"
        case .go: return "Go to"
        case .share: return "Share"
        case .queue: return "Add to queue"
        case .open: return "Open in DAW"
        }
    }

    var icon: String {
        switch self {
        case .play: return "play.fill"
        case .download: return "arrow.down.circle"
        case .go: return "arrow.right.circle"
        case .share: return "square.and.arrow.up"
        case .queue: return "text.append"
        case .open: return "pianokeys"
        }
    }

    var hint: String {
        switch self {
        case .play: return "play <bounce name>"
        case .download: return "download <bounce name>"
        case .go: return "go <section or item>"
        case .share: return "share <project name>"
        case .queue: return "queue <bounce name>"
        case .open: return "open <project name>"
        }
    }

    var badgeColor: Color {
        switch self {
        case .play: return Color(red: 0.145, green: 0.388, blue: 0.922)    // #2563eb
        case .download: return Color(red: 0.961, green: 0.620, blue: 0.043) // #f59e0b
        case .go: return Color(red: 0.545, green: 0.361, blue: 0.965)       // #8b5cf6
        case .share: return Color(red: 0.063, green: 0.725, blue: 0.506)    // #10b981
        case .queue: return Color(red: 0.145, green: 0.388, blue: 0.922)    // #2563eb
        case .open: return Color(red: 0.612, green: 0.639, blue: 0.682)     // #9ca3af
        }
    }

    static func from(_ text: String) -> SpotlightVerb? {
        let lower = text.lowercased()
        return allCases.first { $0.rawValue == lower || $0.aliases.contains(lower) }
    }
}

// MARK: - Result Types

enum SpotlightResultType: String, CaseIterable, Identifiable {
    case plugin, project, bounce, collection

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plugin: return "Plugins"
        case .project: return "Projects"
        case .bounce: return "Bounces"
        case .collection: return "Collections"
        }
    }

    var icon: String {
        switch self {
        case .plugin: return "puzzlepiece.extension"
        case .project: return "folder.fill"
        case .bounce: return "waveform"
        case .collection: return "rectangle.stack"
        }
    }

    /// Short badge letter for compact display
    var badge: String {
        switch self {
        case .plugin: return "P"
        case .project: return "S"
        case .bounce: return "B"
        case .collection: return "C"
        }
    }
}

// MARK: - Results

/// A single format variant of a plugin (used for expanded sub-items)
struct SpotlightFormatVariant: Identifiable {
    let id: String        // plugin UUID
    let format: String    // e.g. "VST3", "AU"
    let path: String      // file path for Finder reveal
}

struct SpotlightResult: Identifiable {
    let id: String
    let type: SpotlightResultType
    let name: String
    let subtitle: String?
    let format: String?
    let relevance: Double
    /// DAW name for project results (e.g. "Ableton Live", "Logic Pro")
    let dawName: String?
    /// All format variants for grouped plugins (e.g. ["VST3", "AU", "AAX"])
    let formats: [String]
    /// Format sub-items for expansion (plugin only)
    let formatVariants: [SpotlightFormatVariant]

    init(id: String, type: SpotlightResultType, name: String, subtitle: String? = nil, format: String? = nil, relevance: Double = 0.7, dawName: String? = nil, formats: [String] = [], formatVariants: [SpotlightFormatVariant] = []) {
        self.id = id
        self.type = type
        self.name = name
        self.subtitle = subtitle
        self.format = format
        self.relevance = relevance
        self.dawName = dawName
        self.formats = formats
        self.formatVariants = formatVariants
    }

    /// Returns the action badge text for a given active verb
    func actionBadge(for verb: SpotlightVerb?) -> String? {
        guard let verb else {
            // Default actions in plain search mode
            switch type {
            case .bounce: return "Play"
            case .project: return dawName.map { "Open in \($0)" }
            case .plugin: return nil
            case .collection: return nil
            }
        }
        switch verb {
        case .play: return "Play"
        case .download: return "Download"
        case .go: return "Go"
        case .share: return "Share"
        case .queue: return "Queue"
        case .open: return dawName.map { "Open in \($0)" } ?? "Open"
        }
    }

    /// Returns the badge color for a given active verb
    func actionBadgeColor(for verb: SpotlightVerb?) -> Color {
        if let verb { return verb.badgeColor }
        switch type {
        case .bounce: return SpotlightVerb.play.badgeColor
        case .project: return SpotlightVerb.open.badgeColor
        default: return .secondary
        }
    }
}

struct SpotlightResultGroup: Identifiable, Equatable {
    let type: SpotlightResultType
    let results: [SpotlightResult]
    var id: String { type.rawValue }

    static func == (lhs: SpotlightResultGroup, rhs: SpotlightResultGroup) -> Bool {
        lhs.type == rhs.type && lhs.results.map(\.id) == rhs.results.map(\.id)
    }
}

// MARK: - Input Parsing

enum SpotlightInputMode {
    case search
    case command
}

struct ParsedSpotlightInput {
    let mode: SpotlightInputMode
    let verb: SpotlightVerb?
    let searchQuery: String

    static let empty = ParsedSpotlightInput(mode: .search, verb: nil, searchQuery: "")
}

enum SpotlightInputParser {
    static func parse(_ raw: String) -> ParsedSpotlightInput {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .empty }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let firstWord = String(parts[0])

        if let verb = SpotlightVerb.from(firstWord) {
            let rest = parts.count > 1
                ? String(parts[1]).trimmingCharacters(in: .whitespaces)
                : ""
            return ParsedSpotlightInput(mode: .command, verb: verb, searchQuery: rest)
        }

        return ParsedSpotlightInput(mode: .search, verb: nil, searchQuery: trimmed)
    }
}

// MARK: - Quick Actions (modifier keys)

/// Actions available via modifier+Enter on a selected result
enum SpotlightQuickAction: Identifiable {
    case showInFinder       // ⌘↩  — any local file
    case openInDAW          // ⌥↩  — projects (Ableton, Logic, Pro Tools)
    case openInQuickLook    // ⇧↩  — audio files
    case revealPlugin       // ⌘↩  — plugins

    var id: String {
        switch self {
        case .showInFinder: return "finder"
        case .openInDAW: return "daw"
        case .openInQuickLook: return "quicklook"
        case .revealPlugin: return "reveal"
        }
    }

    var label: String {
        switch self {
        case .showInFinder: return "Show in Finder"
        case .openInDAW: return "Open in DAW"
        case .openInQuickLook: return "Quick Look"
        case .revealPlugin: return "Show in Finder"
        }
    }

    var icon: String {
        switch self {
        case .showInFinder: return "folder"
        case .openInDAW: return "pianokeys"
        case .openInQuickLook: return "eye"
        case .revealPlugin: return "folder"
        }
    }

    var shortcut: String {
        switch self {
        case .showInFinder: return "⌘↩"
        case .openInDAW: return "⌥↩"
        case .openInQuickLook: return "⇧↩"
        case .revealPlugin: return "⌘↩"
        }
    }

    /// Returns available quick actions for a given result type
    static func actions(for type: SpotlightResultType) -> [SpotlightQuickAction] {
        switch type {
        case .bounce:
            return [.showInFinder, .openInQuickLook]
        case .project:
            return [.openInDAW, .showInFinder]
        case .plugin:
            return [.revealPlugin]
        case .collection:
            return []
        }
    }
}

// MARK: - Go Targets

struct SpotlightGoTarget: Identifiable {
    let label: String
    let section: AppSection
    var id: String { section.rawValue }

    static let all: [SpotlightGoTarget] = [
        .init(label: "Summary", section: .summary),
        .init(label: "Plugins", section: .plugins),
        .init(label: "Projects", section: .projects),
        .init(label: "Collections", section: .collections),
        .init(label: "Bounces", section: .bounces),
        .init(label: "Commands", section: .commands),
        .init(label: "Backup", section: .backup),
        .init(label: "Profile", section: .profile),
    ]
}
