import Combine
import Foundation
import os.log

/// Orchestrates search for the global spotlight panel.
/// Supports local-first search against in-memory services and cloud search via API.
@MainActor
final class SpotlightSearchService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "SpotlightSearch")

    // MARK: - Published State

    @Published var query: String = ""
    @Published var results: [SpotlightResultGroup] = []
    @Published var isSearching = false
    @Published var parsedInput: ParsedSpotlightInput = .empty

    /// The currently locked-in verb (set when user types a verb + space)
    @Published var activeVerb: SpotlightVerb?

    /// Currently selected result index (shared with view for quick actions)
    @Published var selectedIndex = 0

    /// Incremented on each reset/show — used to re-trigger text field focus
    @Published var activationCount = 0

    // MARK: - Service References

    private weak var scanner: ScannerService?
    private weak var bounceService: BounceService?
    private weak var collectionService: CollectionService?
    private weak var auth: AuthenticationService?

    private var debounceTask: Task<Void, Never>?
    private var queryCancellable: AnyCancellable?

    private let apiBaseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    // MARK: - Init

    nonisolated init() {
        // Combine pipeline set up in configure() after properties are initialized
    }

    // MARK: - Configuration

    func configure(
        scanner: ScannerService,
        bounceService: BounceService,
        collectionService: CollectionService,
        auth: AuthenticationService
    ) {
        self.scanner = scanner
        self.bounceService = bounceService
        self.collectionService = collectionService
        self.auth = auth

        // Use Combine to observe query changes — this runs on the next RunLoop tick,
        // so programmatic query changes (verb stripping) don't race with SwiftUI's TextField.
        queryCancellable = $query
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleQueryChanged()
            }
    }

    func reset() {
        activeVerb = nil
        query = ""
        results = []
        parsedInput = .empty
        isSearching = false
        selectedIndex = 0
        activationCount += 1
        debounceTask?.cancel()
    }

    // MARK: - Search

    /// Called by the view when a verb+space is detected.
    /// Sets the verb badge and query in one shot — no stripping needed.
    func activateVerb(_ verb: SpotlightVerb, searchQuery: String) {
        activeVerb = verb
        query = searchQuery
        parsedInput = ParsedSpotlightInput(mode: .command, verb: verb, searchQuery: searchQuery)
        if searchQuery.isEmpty {
            // Show recent actionable items for this verb immediately
            results = recentItems(for: verb)
        }
    }

    private func handleQueryChanged() {
        debounceTask?.cancel()

        // Build parsed input from current state
        if let verb = activeVerb {
            parsedInput = ParsedSpotlightInput(mode: .command, verb: verb, searchQuery: query)
        } else {
            parsedInput = SpotlightInputParser.parse(query)
        }

        if parsedInput.searchQuery.isEmpty && parsedInput.verb == nil {
            results = []
            return
        }

        // Show go targets immediately for "go" verb without further query
        if parsedInput.verb == .go && parsedInput.searchQuery.isEmpty {
            results = []
            return
        }

        // When a verb is active but query is empty, show recent items
        if let verb = activeVerb, parsedInput.searchQuery.isEmpty {
            results = recentItems(for: verb)
            return
        }

        debounceTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await performSearch()
        }
    }

    /// Clear the active verb (e.g. when user backspaces on empty query)
    func clearVerb() {
        activeVerb = nil
        parsedInput = .empty
        results = []
    }

    private func performSearch() async {
        isSearching = true

        // Local results appear instantly
        let localResults = searchLocally(parsedInput.searchQuery, verb: parsedInput.verb)
        results = localResults

        // Collect local IDs to deduplicate cloud results
        let localIds = Set(localResults.flatMap { $0.results.map(\.id) })

        // Fire cloud search in parallel — append any results not already local
        let cloudResults = await searchAPI(parsedInput.searchQuery, verb: parsedInput.verb)
        if !cloudResults.isEmpty {
            var merged = results
            for cloudGroup in cloudResults {
                let newResults = cloudGroup.results.filter { !localIds.contains($0.id) }
                guard !newResults.isEmpty else { continue }
                if let idx = merged.firstIndex(where: { $0.type == cloudGroup.type }) {
                    merged[idx] = SpotlightResultGroup(
                        type: cloudGroup.type,
                        results: merged[idx].results + newResults
                    )
                } else {
                    merged.append(SpotlightResultGroup(type: cloudGroup.type, results: newResults))
                }
            }
            results = merged
        }

        isSearching = false
    }

    // MARK: - Local Search

    private func searchLocally(_ query: String, verb: SpotlightVerb?) -> [SpotlightResultGroup] {
        let q = query.lowercased()
        let targetTypes = verb?.targetTypes ?? SpotlightResultType.allCases
        var groups: [SpotlightResultGroup] = []

        if targetTypes.contains(.plugin), let scanner, !q.isEmpty {
            let matchingPlugins = scanner.plugins
                .filter {
                    $0.name.lowercased().contains(q) ||
                    ($0.manufacturer?.lowercased().contains(q) ?? false) ||
                    ($0.auDescription?.lowercased().contains(q) ?? false)
                }

            // Group by plugin name so "Serum" shows once with [VST3, AU, AAX] badges
            let grouped = Dictionary(grouping: matchingPlugins) { $0.name }
            let formatOrder = ["AU", "VST3", "VST", "AAX"]
            let matches = grouped.keys
                .sorted { relevanceScore($0, query: q) > relevanceScore($1, query: q) }
                .prefix(8)
                .compactMap { name -> SpotlightResult? in
                    guard let plugins = grouped[name], let first = plugins.first else { return nil }
                    let sortedPlugins = plugins.sorted { a, b in
                        (formatOrder.firstIndex(of: a.format.rawValue) ?? 99) <
                        (formatOrder.firstIndex(of: b.format.rawValue) ?? 99)
                    }
                    let formats = sortedPlugins.map(\.format.rawValue)
                    let variants = sortedPlugins.map {
                        SpotlightFormatVariant(id: $0.id.uuidString, format: $0.format.rawValue, path: $0.path)
                    }
                    return SpotlightResult(
                        id: first.id.uuidString,
                        type: .plugin,
                        name: name,
                        subtitle: first.manufacturer ?? first.auDescription,
                        format: nil,
                        relevance: relevanceScore(name, query: q),
                        formats: formats,
                        formatVariants: variants
                    )
                }
            if !matches.isEmpty {
                groups.append(SpotlightResultGroup(type: .plugin, results: Array(matches)))
            }
        }

        if targetTypes.contains(.project), let scanner, !q.isEmpty {
            // Exclude backups for "open" verb; sort all by recency
            let filtered = scanner.sessions
                .filter { session in
                    if verb == .open && session.isBackup { return false }
                    let name = session.projectDisplayName.lowercased()
                    return name.contains(q) || session.name.lowercased().contains(q)
                }
                .sorted { $0.modifiedDate > $1.modifiedDate }

            // Deduplicate by project group, keeping the first (best-ranked) session per group
            let seen = NSMutableSet()
            let matches = filtered
                .filter { session in
                    let key = session.projectGroupKey
                    if seen.contains(key) { return false }
                    seen.add(key)
                    return true
                }
                .prefix(8)
                .map {
                    SpotlightResult(
                        id: $0.path,
                        type: .project,
                        name: $0.projectDisplayName,
                        subtitle: $0.format.rawValue,
                        format: nil,
                        relevance: 1.0,
                        dawName: $0.format.rawValue
                    )
                }
            if !matches.isEmpty {
                groups.append(SpotlightResultGroup(type: .project, results: Array(matches)))
            }
        }

        if targetTypes.contains(.bounce), let bounceService, !q.isEmpty {
            let matches = bounceService.bounces
                .filter { $0.fileName.lowercased().contains(q) }
                .sorted { $0.fileModifiedAt > $1.fileModifiedAt }
                .prefix(8)
                .map {
                    var subtitle: String? = nil
                    var parts: [String] = []
                    if let bpm = $0.bpm { parts.append("\(bpm) BPM") }
                    if let key = $0.musicalKey { parts.append(key) }
                    if let stage = $0.stage { parts.append(stage) }
                    if !parts.isEmpty { subtitle = parts.joined(separator: " · ") }

                    return SpotlightResult(
                        id: $0.id.uuidString,
                        type: .bounce,
                        name: $0.fileName,
                        subtitle: subtitle,
                        format: $0.format,
                        relevance: relevanceScore($0.fileName, query: q)
                    )
                }
            if !matches.isEmpty {
                groups.append(SpotlightResultGroup(type: .bounce, results: Array(matches)))
            }
        }

        if targetTypes.contains(.collection), let collectionService, !q.isEmpty {
            let matches = collectionService.collections
                .filter {
                    $0.name.lowercased().contains(q) ||
                    ($0.description?.lowercased().contains(q) ?? false)
                }
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(8)
                .map {
                    SpotlightResult(
                        id: $0.id.uuidString,
                        type: .collection,
                        name: $0.name,
                        subtitle: $0.description,
                        format: nil,
                        relevance: 1.0
                    )
                }
            if !matches.isEmpty {
                groups.append(SpotlightResultGroup(type: .collection, results: Array(matches)))
            }
        }

        return groups
    }

    // MARK: - Recent Items

    /// Returns recent items for a verb's target types (shown when verb is active but query is empty)
    private func recentItems(for verb: SpotlightVerb) -> [SpotlightResultGroup] {
        let targetTypes = verb.targetTypes
        var groups: [SpotlightResultGroup] = []

        if targetTypes.contains(.bounce), let bounceService {
            let recents = bounceService.bounces
                .sorted { $0.fileModifiedAt > $1.fileModifiedAt }
                .prefix(5)
                .map { bounce -> SpotlightResult in
                    var parts: [String] = []
                    if let bpm = bounce.bpm { parts.append("\(bpm) BPM") }
                    if let key = bounce.musicalKey { parts.append(key) }
                    if let stage = bounce.stage { parts.append(stage) }
                    return SpotlightResult(
                        id: bounce.id.uuidString, type: .bounce, name: bounce.fileName,
                        subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
                        format: bounce.format, relevance: 1.0
                    )
                }
            if !recents.isEmpty {
                groups.append(SpotlightResultGroup(type: .bounce, results: Array(recents)))
            }
        }

        if targetTypes.contains(.project), let scanner {
            let seen = NSMutableSet()
            let recents = scanner.sessions
                .filter { !$0.isBackup }
                .sorted { $0.modifiedDate > $1.modifiedDate }
                .filter { session in
                    let key = session.projectGroupKey
                    if seen.contains(key) { return false }
                    seen.add(key)
                    return true
                }
                .prefix(5)
                .map {
                    SpotlightResult(
                        id: $0.path, type: .project, name: $0.projectDisplayName,
                        subtitle: $0.format.rawValue, format: nil, relevance: 1.0,
                        dawName: $0.format.rawValue
                    )
                }
            if !recents.isEmpty {
                groups.append(SpotlightResultGroup(type: .project, results: Array(recents)))
            }
        }

        if targetTypes.contains(.collection), let collectionService {
            let recents = collectionService.collections
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(5)
                .map {
                    SpotlightResult(
                        id: $0.id.uuidString, type: .collection, name: $0.name,
                        subtitle: $0.description, format: nil, relevance: 1.0
                    )
                }
            if !recents.isEmpty {
                groups.append(SpotlightResultGroup(type: .collection, results: Array(recents)))
            }
        }

        return groups
    }

    /// Returns a preview of recent items across all types (for the empty search state)
    func recentPreview() -> [SpotlightResultGroup] {
        var groups: [SpotlightResultGroup] = []

        if let scanner {
            let seen = NSMutableSet()
            let recents = scanner.sessions
                .filter { !$0.isBackup }
                .sorted { $0.modifiedDate > $1.modifiedDate }
                .filter { session in
                    let key = session.projectGroupKey
                    if seen.contains(key) { return false }
                    seen.add(key)
                    return true
                }
                .prefix(3)
                .map {
                    SpotlightResult(
                        id: $0.path, type: .project, name: $0.projectDisplayName,
                        subtitle: $0.format.rawValue, format: nil, relevance: 1.0,
                        dawName: $0.format.rawValue
                    )
                }
            if !recents.isEmpty {
                groups.append(SpotlightResultGroup(type: .project, results: Array(recents)))
            }
        }

        if let bounceService {
            let recents = bounceService.bounces
                .sorted { $0.fileModifiedAt > $1.fileModifiedAt }
                .prefix(3)
                .map {
                    SpotlightResult(
                        id: $0.id.uuidString, type: .bounce, name: $0.fileName,
                        subtitle: nil, format: $0.format, relevance: 1.0
                    )
                }
            if !recents.isEmpty {
                groups.append(SpotlightResultGroup(type: .bounce, results: Array(recents)))
            }
        }

        if let collectionService {
            let recents = collectionService.collections
                .sorted { $0.updatedAt > $1.updatedAt }
                .prefix(2)
                .map {
                    SpotlightResult(
                        id: $0.id.uuidString, type: .collection, name: $0.name,
                        subtitle: $0.description, format: nil, relevance: 1.0
                    )
                }
            if !recents.isEmpty {
                groups.append(SpotlightResultGroup(type: .collection, results: Array(recents)))
            }
        }

        return groups
    }

    /// Simple relevance scoring: prefix match > word boundary > substring
    private func relevanceScore(_ name: String, query: String) -> Double {
        let lower = name.lowercased()
        if lower.hasPrefix(query) { return 1.0 }
        if lower.contains(" \(query)") || lower.contains("-\(query)") || lower.contains("_\(query)") {
            return 0.85
        }
        return 0.7
    }

    // MARK: - API Search

    private func searchAPI(_ query: String, verb: SpotlightVerb?) async -> [SpotlightResultGroup] {
        guard !query.isEmpty else { return [] }
        guard let token = auth?.authToken else {
            logger.warning("No auth token for cloud search")
            return []
        }

        var components = URLComponents(string: "\(apiBaseURL)/api/search/")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "limit", value: "20"),
        ]
        if let verb {
            let types = verb.targetTypes.map(\.rawValue).joined(separator: ",")
            components.queryItems?.append(URLQueryItem(name: "types", value: types))
        }

        guard let url = components.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                logger.warning("Search API returned non-200")
                return []
            }

            let decoded = try JSONDecoder().decode(APISearchResponse.self, from: data)
            return groupAPIResults(decoded.results)
        } catch {
            logger.error("Search API error: \(error)")
            return []
        }
    }

    private func groupAPIResults(_ results: [APISearchResult]) -> [SpotlightResultGroup] {
        let grouped = Dictionary(grouping: results) { $0.type }
        return SpotlightResultType.allCases.compactMap { type in
            guard let items = grouped[type.rawValue], !items.isEmpty else { return nil }
            let spotlightResults = items.map {
                SpotlightResult(
                    id: $0.id,
                    type: type,
                    name: $0.name,
                    subtitle: $0.subtitle,
                    format: $0.format,
                    relevance: $0.relevance
                )
            }
            return SpotlightResultGroup(type: type, results: spotlightResults)
        }
    }

    // MARK: - Flattened Results (for keyboard navigation)

    var flatResults: [SpotlightResult] {
        results.flatMap(\.results)
    }
}

// MARK: - API Response Types

private struct APISearchResponse: Decodable {
    let query: String
    let total: Int
    let results: [APISearchResult]
}

private struct APISearchResult: Decodable {
    let id: String
    let type: String
    let name: String
    let subtitle: String?
    let format: String?
    let relevance: Double
}
