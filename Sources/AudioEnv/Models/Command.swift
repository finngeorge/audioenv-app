import Foundation

// MARK: - Query types

/// Entity types that can be queried by the command system.
enum QueryEntityType: String, CaseIterable, Codable, Identifiable, Equatable {
    case plugins
    case projects
    case bounces
    case collections

    var id: String { rawValue }

    var label: String {
        switch self {
        case .plugins: return "Plugins"
        case .projects: return "Projects"
        case .bounces: return "Bounces"
        case .collections: return "Collections"
        }
    }

    var icon: String {
        switch self {
        case .plugins: return "puzzlepiece.extension"
        case .projects: return "folder.fill"
        case .bounces: return "waveform"
        case .collections: return "rectangle.stack"
        }
    }

    /// Fields available for filtering this entity type.
    var availableFields: [QueryField] {
        switch self {
        case .plugins:
            return [.name, .format, .manufacturer]
        case .projects:
            return [.name, .format, .pluginUsed, .modifiedDate]
        case .bounces:
            return [.name, .format, .bpm, .key, .duration, .sampleRate, .modifiedDate]
        case .collections:
            return [.name, .status]
        }
    }
}

/// Fields available for query filters.
enum QueryField: String, CaseIterable, Codable, Identifiable, Equatable {
    case name
    case format
    case manufacturer
    case pluginUsed = "plugin_used"
    case bpm
    case key
    case client
    case status
    case duration
    case sampleRate = "sample_rate"
    case modifiedDate = "modified_date"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: return "Name"
        case .format: return "Format"
        case .manufacturer: return "Manufacturer"
        case .pluginUsed: return "Plugin Used"
        case .bpm: return "BPM"
        case .key: return "Key"
        case .client: return "Client"
        case .status: return "Status"
        case .duration: return "Duration"
        case .sampleRate: return "Sample Rate"
        case .modifiedDate: return "Modified Date"
        }
    }

    /// Operators available for this field type.
    var availableOperators: [QueryOperator] {
        switch self {
        case .name, .manufacturer, .client, .status, .key:
            return [.equals, .notEquals, .contains, .startsWith, .oneOf]
        case .format, .pluginUsed:
            return [.equals, .notEquals, .contains, .oneOf]
        case .bpm, .duration, .sampleRate:
            return [.equals, .notEquals, .greaterThan, .lessThan, .between]
        case .modifiedDate:
            return [.after, .before, .between]
        }
    }
}

/// Comparison operators for query filters.
enum QueryOperator: String, CaseIterable, Codable, Identifiable, Equatable {
    case equals
    case notEquals = "not_equals"
    case contains
    case startsWith = "starts_with"
    case greaterThan = "greater_than"
    case lessThan = "less_than"
    case after
    case before
    case between
    case oneOf = "one_of"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .equals: return "is"
        case .notEquals: return "is not"
        case .contains: return "contains"
        case .startsWith: return "starts with"
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .after: return "after"
        case .before: return "before"
        case .between: return "between"
        case .oneOf: return "one of"
        }
    }

    /// DSL symbol used in text commands.
    var dslSymbol: String? {
        switch self {
        case .contains: return "~"
        case .startsWith: return "^"
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .notEquals: return "!"
        default: return nil
        }
    }

    /// Resolve a DSL symbol back to an operator.
    static func from(dslSymbol: String) -> QueryOperator? {
        switch dslSymbol {
        case "~": return .contains
        case "^": return .startsWith
        case ">": return .greaterThan
        case "<": return .lessThan
        case "!": return .notEquals
        default: return nil
        }
    }
}

/// A single filter condition within a query.
struct QueryFilter: Codable, Equatable, Identifiable {
    let id: UUID
    var field: QueryField
    var op: QueryOperator
    var value: String
    var secondaryValue: String?  // For "between" operator

    init(field: QueryField, op: QueryOperator, value: String, secondaryValue: String? = nil) {
        self.id = UUID()
        self.field = field
        self.op = op
        self.value = value
        self.secondaryValue = secondaryValue
    }

    enum CodingKeys: String, CodingKey {
        case id, field, op, value
        case secondaryValue = "secondary_value"
    }
}

/// How multiple filters are combined.
enum FilterCombination: String, Codable, Equatable {
    case all  // AND
    case any  // OR

    var label: String {
        switch self {
        case .all: return "Match All"
        case .any: return "Match Any"
        }
    }
}

/// A query targeting a specific entity type with optional filters.
struct Query: Codable, Equatable {
    var entityType: QueryEntityType
    var filters: [QueryFilter]
    var combination: FilterCombination

    init(entityType: QueryEntityType, filters: [QueryFilter] = [], combination: FilterCombination = .all) {
        self.entityType = entityType
        self.filters = filters
        self.combination = combination
    }

    enum CodingKeys: String, CodingKey {
        case entityType = "entity_type"
        case filters, combination
    }
}

// MARK: - Command types

/// Actions that can be piped after a query.
enum CommandAction: Codable, Equatable {
    case addToCollection(UUID?)
    case createCollection(String)
    case backup
    case tag(key: String, value: String)
    case export(format: String)

    var label: String {
        switch self {
        case .addToCollection: return "Add to Collection"
        case .createCollection(let name): return "Create Collection \"\(name)\""
        case .backup: return "Backup"
        case .tag(let key, let value): return "Tag \(key):\(value)"
        case .export(let format): return "Export as \(format)"
        }
    }

    var icon: String {
        switch self {
        case .addToCollection: return "rectangle.stack.badge.plus"
        case .createCollection: return "plus.rectangle.on.rectangle"
        case .backup: return "arrow.up.circle"
        case .tag: return "tag"
        case .export: return "square.and.arrow.up"
        }
    }
}

/// A complete command: query + piped actions + metadata.
struct Command: Codable, Equatable, Identifiable {
    let id: UUID
    var query: Query
    var actions: [CommandAction]
    var name: String?
    var description: String?
    var createdAt: Date?
    var updatedAt: Date?
    var lastRunAt: Date?
    var lastResultCount: Int?

    init(
        id: UUID = UUID(),
        query: Query,
        actions: [CommandAction] = [],
        name: String? = nil,
        description: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date? = nil,
        lastRunAt: Date? = nil,
        lastResultCount: Int? = nil
    ) {
        self.id = id
        self.query = query
        self.actions = actions
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastRunAt = lastRunAt
        self.lastResultCount = lastResultCount
    }

    enum CodingKeys: String, CodingKey {
        case id, query, actions, name, description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastRunAt = "last_run_at"
        case lastResultCount = "last_result_count"
    }
}

/// Result of executing a command query.
struct CommandResult: Equatable {
    var matchedPlugins: [AudioPlugin]
    var matchedProjects: [SessionProject]
    var matchedBounces: [Bounce]
    var matchedCollections: [AudioCollection]
    var actionResults: [ActionResult]

    init(
        matchedPlugins: [AudioPlugin] = [],
        matchedProjects: [SessionProject] = [],
        matchedBounces: [Bounce] = [],
        matchedCollections: [AudioCollection] = [],
        actionResults: [ActionResult] = []
    ) {
        self.matchedPlugins = matchedPlugins
        self.matchedProjects = matchedProjects
        self.matchedBounces = matchedBounces
        self.matchedCollections = matchedCollections
        self.actionResults = actionResults
    }

    var totalMatchCount: Int {
        matchedPlugins.count + matchedProjects.count + matchedBounces.count + matchedCollections.count
    }

    var isEmpty: Bool { totalMatchCount == 0 }
}

/// Result of a single piped action.
struct ActionResult: Equatable {
    let action: CommandAction
    let success: Bool
    let message: String
}
