import Foundation

// MARK: - Command Verbs (mirrors web app's COMMAND_VERBS)

enum SpotlightVerb: String, CaseIterable {
    case play
    case download
    case go
    case share
    case queue

    var aliases: [String] {
        switch self {
        case .play: return ["p"]
        case .download: return ["d", "dl"]
        case .go: return ["g", "open"]
        case .share: return ["sh"]
        case .queue: return ["q", "add"]
        }
    }

    var targetTypes: [SpotlightResultType] {
        switch self {
        case .play: return [.bounce]
        case .download: return [.bounce]
        case .go: return SpotlightResultType.allCases
        case .share: return [.project]
        case .queue: return [.bounce]
        }
    }

    var label: String {
        switch self {
        case .play: return "Play"
        case .download: return "Download"
        case .go: return "Go to"
        case .share: return "Share"
        case .queue: return "Add to queue"
        }
    }

    var icon: String {
        switch self {
        case .play: return "play.fill"
        case .download: return "arrow.down.circle"
        case .go: return "arrow.right.circle"
        case .share: return "square.and.arrow.up"
        case .queue: return "text.append"
        }
    }

    var hint: String {
        switch self {
        case .play: return "play <bounce name>"
        case .download: return "download <bounce name>"
        case .go: return "go <section or item>"
        case .share: return "share <project name>"
        case .queue: return "queue <bounce name>"
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

struct SpotlightResult: Identifiable {
    let id: String
    let type: SpotlightResultType
    let name: String
    let subtitle: String?
    let format: String?
    let relevance: Double

    init(id: String, type: SpotlightResultType, name: String, subtitle: String? = nil, format: String? = nil, relevance: Double = 0.7) {
        self.id = id
        self.type = type
        self.name = name
        self.subtitle = subtitle
        self.format = format
        self.relevance = relevance
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
