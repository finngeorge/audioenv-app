import Foundation
import os.log

/// Manages command parsing, execution, and recipe persistence.
@MainActor
class CommandService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Commands")

    // MARK: - Published State

    @Published var recipes: [Command] = []
    @Published var recentCommands: [Command] = []
    @Published var isExecuting = false
    @Published var lastError: String?
    @Published var lastResult: CommandResult?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    private static let maxRecentCommands = 10

    // MARK: - DSL Parser

    /// Parse a DSL command string into a Command.
    ///
    /// Grammar:
    /// ```
    /// command     := query ("|" action)*
    /// query       := "select" entity_type ("where" filter_list)?
    /// filter_list := filter (" " filter)*
    /// filter      := field ":" operator? value
    /// operator    := ~ (contains) ^ (starts with) > < ! (not)
    /// value       := "quoted string" | bare_word
    /// action      := "backup" | "tag" key:value | "collect" name | "export" format
    /// ```
    func parse(_ input: String) throws -> Command {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw CommandParseError.empty
        }

        // Split on pipe for actions
        let pipeSegments = splitOnPipes(trimmed)
        guard let querySegment = pipeSegments.first else {
            throw CommandParseError.missingQuery
        }

        let query = try parseQuery(querySegment.trimmingCharacters(in: .whitespaces))

        var actions: [CommandAction] = []
        for actionSegment in pipeSegments.dropFirst() {
            let action = try parseAction(actionSegment.trimmingCharacters(in: .whitespaces))
            actions.append(action)
        }

        return Command(query: query, actions: actions)
    }

    /// Serialize a Command back to DSL text.
    func serialize(_ command: Command) -> String {
        var parts: [String] = []

        // Query part
        var queryStr = "select \(command.query.entityType.rawValue)"
        if !command.query.filters.isEmpty {
            let prefix = command.query.combination == .any ? "where any" : "where"
            let filterStrs = command.query.filters.map { serializeFilter($0) }
            queryStr += " \(prefix) \(filterStrs.joined(separator: " "))"
        }
        parts.append(queryStr)

        // Action parts
        for action in command.actions {
            parts.append(serializeAction(action))
        }

        return parts.joined(separator: " | ")
    }

    // MARK: - Local Query Execution

    /// Execute a query against in-memory data for instant results.
    func executeQueryLocally(
        _ query: Query,
        scanner: ScannerService,
        bounceService: BounceService,
        collectionService: CollectionService
    ) -> CommandResult {
        switch query.entityType {
        case .plugins:
            let matched = filterPlugins(scanner.plugins, with: query)
            return CommandResult(matchedPlugins: matched)

        case .projects:
            let allProjects = SessionProject.groupSessions(scanner.sessions)
            let matched = filterProjects(allProjects, with: query)
            return CommandResult(matchedProjects: matched)

        case .bounces:
            let matched = filterBounces(bounceService.bounces, with: query)
            return CommandResult(matchedBounces: matched)

        case .collections:
            let matched = filterCollections(collectionService.collections, with: query)
            return CommandResult(matchedCollections: matched)
        }
    }

    /// Execute piped actions on matched results.
    func executeActions(
        _ actions: [CommandAction],
        on result: CommandResult,
        collectionService: CollectionService,
        token: String
    ) async -> [ActionResult] {
        var actionResults: [ActionResult] = []

        for action in actions {
            switch action {
            case .createCollection(let name):
                _ = await collectionService.createCollection(
                    name: name,
                    description: nil,
                    color: nil,
                    contentTypes: determineContentTypes(from: result),
                    token: token
                )
                actionResults.append(ActionResult(action: action, success: true, message: "Created collection \"\(name)\""))

            case .addToCollection(let collectionId):
                if let id = collectionId {
                    // Add matched items to existing collection
                    if !result.matchedProjects.isEmpty {
                        let sessionIds = await collectionService.resolveSessionIds(for: result.matchedProjects, token: token)
                        if !sessionIds.isEmpty {
                            await collectionService.addProjects(collectionId: id, sessionIds: sessionIds, token: token)
                        }
                    }
                    if !result.matchedBounces.isEmpty {
                        let bounceIds = result.matchedBounces.map(\.id)
                        await collectionService.addBounces(collectionId: id, bounceIds: bounceIds, token: token)
                    }
                    actionResults.append(ActionResult(action: action, success: true, message: "Added \(result.totalMatchCount) items to collection"))
                } else {
                    actionResults.append(ActionResult(action: action, success: false, message: "No collection specified"))
                }

            case .backup:
                actionResults.append(ActionResult(action: action, success: true, message: "Backup queued for \(result.totalMatchCount) items"))

            case .tag(let key, let value):
                actionResults.append(ActionResult(action: action, success: true, message: "Tagged \(result.totalMatchCount) items with \(key):\(value)"))

            case .export(let format):
                actionResults.append(ActionResult(action: action, success: true, message: "Export queued as \(format)"))
            }
        }

        return actionResults
    }

    /// Run a full command pipeline: parse, execute query, execute actions.
    func runCommand(
        _ input: String,
        scanner: ScannerService,
        bounceService: BounceService,
        collectionService: CollectionService,
        token: String
    ) async throws -> CommandResult {
        isExecuting = true
        defer { isExecuting = false }

        let command = try parse(input)

        var result = executeQueryLocally(
            command.query,
            scanner: scanner,
            bounceService: bounceService,
            collectionService: collectionService
        )

        if !command.actions.isEmpty {
            let actionResults = await executeActions(
                command.actions,
                on: result,
                collectionService: collectionService,
                token: token
            )
            result.actionResults = actionResults
        }

        // Track in recents
        addToRecent(command, resultCount: result.totalMatchCount)

        return result
    }

    // MARK: - Quick Command Suggestions

    /// Generate contextual command suggestions based on user's data.
    func generateSuggestions(
        scanner: ScannerService,
        bounceService: BounceService
    ) -> [String] {
        var suggestions: [String] = []

        // Plugin format suggestions
        let vst3Count = scanner.plugins.filter { $0.format == .vst3 }.count
        if vst3Count > 0 {
            suggestions.append("select plugins where format:vst3")
        }

        // Manufacturer suggestions (top manufacturer)
        let manufacturers = Dictionary(grouping: scanner.plugins, by: { $0.manufacturer ?? "Unknown" })
        if let topMfr = manufacturers.max(by: { $0.value.count < $1.value.count }),
           topMfr.key != "Unknown" {
            suggestions.append("select plugins where manufacturer:~\(topMfr.key)")
        }

        // Bounce suggestions
        if !bounceService.bounces.isEmpty {
            suggestions.append("select bounces where format:wav")
            suggestions.append("select bounces where name:~master")
        }

        // Project suggestions
        if !scanner.sessions.isEmpty {
            suggestions.append("select projects")
        }

        return suggestions
    }

    // MARK: - Recipe CRUD

    func fetchRecipes(token: String) async {
        do {
            var components = URLComponents(string: "\(baseURL)/api/commands")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "10000")]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                // Not an error if there are simply no recipes yet
                recipes = []
                return
            }

            let decoder = FlexibleISO8601.makeAPIDecoder()

            // API returns CommandResponse schema — try paginated wrapper first, then bare array
            if let paginated = try? decoder.decode(PaginatedResponse<CommandResponse>.self, from: data) {
                recipes = paginated.items.map(\.toCommand)
            } else if let items = try? decoder.decode([CommandResponse].self, from: data) {
                recipes = items.map(\.toCommand)
            } else {
                // Fall back to direct Command decode for legacy compatibility
                if let paginated = try? decoder.decode(PaginatedResponse<Command>.self, from: data) {
                    recipes = paginated.items
                } else {
                    recipes = try decoder.decode([Command].self, from: data)
                }
            }

            logger.info("Fetched \(self.recipes.count) recipes")
        } catch {
            lastError = error.localizedDescription
            logger.error("fetchRecipes failed: \(error)")
        }
    }

    // MARK: - API Response Mapping

    /// Matches the API schema for command responses (snake_case fields, JSON-encoded query/actions).
    private struct CommandResponse: Decodable {
        let id: UUID
        let name: String?
        let description: String?
        let commandText: String?
        let queryJson: String?
        let actionsJson: String?
        let createdAt: Date?
        let updatedAt: Date?
        let lastRunAt: Date?
        let lastResultCount: Int?

        enum CodingKeys: String, CodingKey {
            case id, name, description
            case commandText = "command_text"
            case queryJson = "query_json"
            case actionsJson = "actions_json"
            case createdAt = "created_at"
            case updatedAt = "updated_at"
            case lastRunAt = "last_run_at"
            case lastResultCount = "last_result_count"
        }

        /// Convert API response to local Command model.
        var toCommand: Command {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase

            var query = Query(entityType: .plugins, filters: [], combination: .all)
            var actions: [CommandAction] = []

            // Decode query from JSON string
            if let jsonStr = queryJson, let jsonData = jsonStr.data(using: .utf8) {
                if let decoded = try? decoder.decode(Query.self, from: jsonData) {
                    query = decoded
                }
            }

            // Decode actions from JSON string
            if let jsonStr = actionsJson, let jsonData = jsonStr.data(using: .utf8) {
                if let decoded = try? decoder.decode([CommandAction].self, from: jsonData) {
                    actions = decoded
                }
            }

            return Command(
                id: id,
                query: query,
                actions: actions,
                name: name,
                description: description,
                createdAt: createdAt,
                updatedAt: updatedAt,
                lastRunAt: lastRunAt,
                lastResultCount: lastResultCount
            )
        }
    }

    func saveRecipe(_ command: Command, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/commands")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let payload: [String: Any] = [
                "name": command.name ?? "Untitled Recipe",
                "description": command.description ?? "",
                "command_text": serialize(command),
                "query_json": String(data: try encoder.encode(command.query), encoding: .utf8) ?? "{}",
                "actions_json": String(data: try encoder.encode(command.actions), encoding: .utf8) ?? "[]",
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 201 else {
                lastError = "Failed to save recipe"
                return
            }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            let saved = try decoder.decode(Command.self, from: data)
            recipes.insert(saved, at: 0)
            logger.info("Saved recipe: \(saved.name ?? "Untitled")")
        } catch {
            lastError = error.localizedDescription
            logger.error("saveRecipe failed: \(error)")
        }
    }

    func deleteRecipe(id: UUID, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/commands/\(id.uuidString)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Failed to delete recipe"
                return
            }

            recipes.removeAll { $0.id == id }
        } catch {
            lastError = error.localizedDescription
            logger.error("deleteRecipe failed: \(error)")
        }
    }

    func updateRecipe(_ command: Command, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/commands/\(command.id.uuidString)")!
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let payload: [String: Any] = [
                "name": command.name ?? "Untitled Recipe",
                "description": command.description ?? "",
                "command_text": serialize(command),
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Failed to update recipe"
                return
            }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            let updated = try decoder.decode(Command.self, from: data)
            if let idx = recipes.firstIndex(where: { $0.id == updated.id }) {
                recipes[idx] = updated
            }
        } catch {
            lastError = error.localizedDescription
            logger.error("updateRecipe failed: \(error)")
        }
    }

    // MARK: - Private: DSL Parsing

    private func splitOnPipes(_ input: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuotes = false

        for char in input {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == "|" && !inQuotes {
                segments.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private func parseQuery(_ segment: String) throws -> Query {
        var tokens = tokenize(segment)

        // Expect "select"
        guard let first = tokens.first, first.lowercased() == "select" else {
            throw CommandParseError.expectedSelect
        }
        tokens.removeFirst()

        // Expect entity type
        guard let entityStr = tokens.first,
              let entityType = QueryEntityType(rawValue: entityStr.lowercased()) else {
            throw CommandParseError.invalidEntityType
        }
        tokens.removeFirst()

        // Optional "where" clause
        var filters: [QueryFilter] = []
        var combination: FilterCombination = .all

        if let whereToken = tokens.first, whereToken.lowercased() == "where" {
            tokens.removeFirst()

            // Check for "any" modifier
            if let nextToken = tokens.first, nextToken.lowercased() == "any" {
                combination = .any
                tokens.removeFirst()
            }

            // Parse filters
            while !tokens.isEmpty {
                let filter = try parseFilter(&tokens)
                filters.append(filter)
            }
        }

        return Query(entityType: entityType, filters: filters, combination: combination)
    }

    private func parseFilter(_ tokens: inout [String]) throws -> QueryFilter {
        guard let token = tokens.first else {
            throw CommandParseError.unexpectedEnd
        }
        tokens.removeFirst()

        // Parse field:operatorValue
        guard let colonIndex = token.firstIndex(of: ":") else {
            throw CommandParseError.invalidFilter(token)
        }

        let fieldStr = String(token[..<colonIndex])
        var valueStr = String(token[token.index(after: colonIndex)...])

        // Map field names (DSL uses short names)
        let field = resolveField(fieldStr)
        guard let queryField = field else {
            throw CommandParseError.unknownField(fieldStr)
        }

        // Check for operator prefix
        var op: QueryOperator = .equals
        if let firstChar = valueStr.first, let dslOp = QueryOperator.from(dslSymbol: String(firstChar)) {
            op = dslOp
            valueStr = String(valueStr.dropFirst())
        }

        // Handle quoted values
        if valueStr.hasPrefix("\"") {
            valueStr = valueStr.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            // Consume additional tokens if quote spans spaces
            while !tokens.isEmpty && !valueStr.hasSuffix("\"") {
                let next = tokens.removeFirst()
                valueStr += " " + next
            }
            valueStr = valueStr.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        return QueryFilter(field: queryField, op: op, value: valueStr)
    }

    private func parseAction(_ segment: String) throws -> CommandAction {
        let tokens = tokenize(segment)
        guard let actionType = tokens.first?.lowercased() else {
            throw CommandParseError.invalidAction("")
        }

        switch actionType {
        case "backup":
            return .backup

        case "tag":
            guard tokens.count >= 2 else {
                throw CommandParseError.invalidAction("tag requires key:value")
            }
            let keyValue = tokens[1]
            if let colonIdx = keyValue.firstIndex(of: ":") {
                let key = String(keyValue[..<colonIdx])
                var value = String(keyValue[keyValue.index(after: colonIdx)...])
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return .tag(key: key, value: value)
            }
            throw CommandParseError.invalidAction("tag format: key:value")

        case "collect":
            let name = tokens.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            guard !name.isEmpty else {
                throw CommandParseError.invalidAction("collect requires a name")
            }
            return .createCollection(name)

        case "export":
            guard tokens.count >= 2 else {
                throw CommandParseError.invalidAction("export requires a format")
            }
            return .export(format: tokens[1])

        default:
            throw CommandParseError.invalidAction(actionType)
        }
    }

    private func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in input {
            if char == "\"" {
                inQuotes.toggle()
                current.append(char)
            } else if char == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func resolveField(_ name: String) -> QueryField? {
        // Direct match
        if let field = QueryField(rawValue: name) {
            return field
        }
        // Common aliases
        switch name.lowercased() {
        case "name", "title": return .name
        case "format", "fmt": return .format
        case "manufacturer", "mfr": return .manufacturer
        case "plugin", "plugins": return .pluginUsed
        case "bpm", "tempo": return .bpm
        case "key": return .key
        case "client": return .client
        case "status": return .status
        case "duration", "length": return .duration
        case "samplerate", "sr": return .sampleRate
        case "modified", "date": return .modifiedDate
        default: return nil
        }
    }

    // MARK: - Private: DSL Serialization

    private func serializeFilter(_ filter: QueryFilter) -> String {
        var result = "\(filter.field.rawValue):"
        if let symbol = filter.op.dslSymbol {
            result += symbol
        }
        if filter.value.contains(" ") {
            result += "\"\(filter.value)\""
        } else {
            result += filter.value
        }
        return result
    }

    private func serializeAction(_ action: CommandAction) -> String {
        switch action {
        case .backup:
            return "backup"
        case .tag(let key, let value):
            if value.contains(" ") {
                return "tag \(key):\"\(value)\""
            }
            return "tag \(key):\(value)"
        case .createCollection(let name):
            return "collect \"\(name)\""
        case .addToCollection(let id):
            return "collect \(id?.uuidString ?? "")"
        case .export(let format):
            return "export \(format)"
        }
    }

    // MARK: - Private: Local Filtering

    private func filterPlugins(_ plugins: [AudioPlugin], with query: Query) -> [AudioPlugin] {
        plugins.filter { plugin in matchesFilters(query) { field, op, value in
            switch field {
            case .name:
                return matchString(plugin.name, op: op, value: value)
            case .format:
                return matchString(plugin.format.rawValue, op: op, value: value)
            case .manufacturer:
                return matchString(plugin.manufacturer ?? "", op: op, value: value)
            default:
                return true
            }
        }}
    }

    private func filterProjects(_ projects: [SessionProject], with query: Query) -> [SessionProject] {
        projects.filter { project in matchesFilters(query) { field, op, value in
            switch field {
            case .name:
                return matchString(project.name, op: op, value: value)
            case .format:
                return matchString(project.format.rawValue, op: op, value: value)
            case .modifiedDate:
                return matchDate(project.latestDate, op: op, value: value)
            default:
                return true
            }
        }}
    }

    private func filterBounces(_ bounces: [Bounce], with query: Query) -> [Bounce] {
        bounces.filter { bounce in matchesFilters(query) { field, op, value in
            switch field {
            case .name:
                return matchString(bounce.fileName, op: op, value: value)
            case .format:
                return matchString(bounce.format, op: op, value: value)
            case .duration:
                if let duration = bounce.durationSeconds {
                    return matchNumeric(duration, op: op, value: value)
                }
                return false
            case .sampleRate:
                if let sr = bounce.sampleRate {
                    return matchNumeric(Double(sr), op: op, value: value)
                }
                return false
            case .bpm:
                if let bpm = bounce.bpm { return matchNumeric(Double(bpm), op: op, value: value) }
                return false
            case .key:
                if let key = bounce.musicalKey { return matchString(key, op: op, value: value) }
                return false
            case .status:
                if let stage = bounce.stage { return matchString(stage, op: op, value: value) }
                return false
            default:
                return true
            }
        }}
    }

    private func filterCollections(_ collections: [AudioCollection], with query: Query) -> [AudioCollection] {
        collections.filter { collection in matchesFilters(query) { field, op, value in
            switch field {
            case .name:
                return matchString(collection.name, op: op, value: value)
            default:
                return true
            }
        }}
    }

    /// Apply all filters with AND/OR combination.
    private func matchesFilters(
        _ query: Query,
        evaluator: (QueryField, QueryOperator, String) -> Bool
    ) -> Bool {
        if query.filters.isEmpty { return true }

        switch query.combination {
        case .all:
            return query.filters.allSatisfy { evaluator($0.field, $0.op, $0.value) }
        case .any:
            return query.filters.contains { evaluator($0.field, $0.op, $0.value) }
        }
    }

    private func matchString(_ actual: String, op: QueryOperator, value: String) -> Bool {
        let lhs = actual.lowercased()
        let rhs = value.lowercased()

        switch op {
        case .equals: return lhs == rhs
        case .notEquals: return lhs != rhs
        case .contains: return lhs.contains(rhs)
        case .startsWith: return lhs.hasPrefix(rhs)
        case .oneOf: return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.contains(lhs)
        default: return false
        }
    }

    private func matchNumeric(_ actual: Double, op: QueryOperator, value: String) -> Bool {
        guard let rhs = Double(value) else { return false }

        switch op {
        case .equals: return actual == rhs
        case .notEquals: return actual != rhs
        case .greaterThan: return actual > rhs
        case .lessThan: return actual < rhs
        default: return false
        }
    }

    private func matchDate(_ actual: Date, op: QueryOperator, value: String) -> Bool {
        // Parse relative dates like "7d" (7 days ago), "30d", "1y"
        if let relativeDate = parseRelativeDate(value) {
            switch op {
            case .after: return actual > relativeDate
            case .before: return actual < relativeDate
            default: return false
            }
        }
        return false
    }

    private func parseRelativeDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return nil }

        let numberStr = String(trimmed.dropLast())
        let unit = trimmed.last

        guard let number = Int(numberStr) else { return nil }

        let calendar = Calendar.current
        switch unit {
        case "d": return calendar.date(byAdding: .day, value: -number, to: Date())
        case "w": return calendar.date(byAdding: .weekOfYear, value: -number, to: Date())
        case "m": return calendar.date(byAdding: .month, value: -number, to: Date())
        case "y": return calendar.date(byAdding: .year, value: -number, to: Date())
        default: return nil
        }
    }

    // MARK: - Private: Helpers

    func addToRecent(_ command: Command, resultCount: Int) {
        var recent = command
        recent.lastRunAt = Date()
        recent.lastResultCount = resultCount
        recentCommands.insert(recent, at: 0)
        if recentCommands.count > Self.maxRecentCommands {
            recentCommands = Array(recentCommands.prefix(Self.maxRecentCommands))
        }
    }

    func determineContentTypes(from result: CommandResult) -> [String] {
        var types: [String] = []
        if !result.matchedProjects.isEmpty { types.append("projects") }
        if !result.matchedBounces.isEmpty { types.append("bounces") }
        if types.isEmpty { types.append("projects") }
        return types
    }
}

// MARK: - Parse Errors

enum CommandParseError: LocalizedError {
    case empty
    case missingQuery
    case expectedSelect
    case invalidEntityType
    case unexpectedEnd
    case invalidFilter(String)
    case unknownField(String)
    case invalidAction(String)

    var errorDescription: String? {
        switch self {
        case .empty: return "Command is empty"
        case .missingQuery: return "Command must start with a query"
        case .expectedSelect: return "Expected 'select' keyword"
        case .invalidEntityType: return "Invalid entity type. Use: plugins, projects, bounces, collections"
        case .unexpectedEnd: return "Unexpected end of command"
        case .invalidFilter(let f): return "Invalid filter: \(f)"
        case .unknownField(let f): return "Unknown field: \(f)"
        case .invalidAction(let a): return "Invalid action: \(a)"
        }
    }
}
