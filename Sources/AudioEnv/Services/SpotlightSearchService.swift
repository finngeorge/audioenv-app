import Foundation
import os.log

/// Orchestrates search for the global spotlight panel.
/// Supports local-first search against in-memory services and cloud search via API.
@MainActor
final class SpotlightSearchService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "SpotlightSearch")

    // MARK: - Published State

    @Published var query: String = "" {
        didSet { debouncedSearch() }
    }
    @Published var results: [SpotlightResultGroup] = []
    @Published var isSearching = false
    @Published var searchMode: SearchMode = .local
    @Published var parsedInput: ParsedSpotlightInput = .empty

    /// The currently locked-in verb (set when user types a verb + space)
    @Published var activeVerb: SpotlightVerb?

    enum SearchMode: String, CaseIterable {
        case local = "Local"
        case cloud = "Cloud"
    }

    // MARK: - Service References

    private weak var scanner: ScannerService?
    private weak var bounceService: BounceService?
    private weak var collectionService: CollectionService?
    private weak var auth: AuthenticationService?

    private var debounceTask: Task<Void, Never>?

    private let apiBaseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

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
    }

    func reset() {
        activeVerb = nil
        isStrippingVerb = false
        query = ""
        results = []
        parsedInput = .empty
        isSearching = false
        debounceTask?.cancel()
    }

    // MARK: - Search

    private var isStrippingVerb = false

    private func debouncedSearch() {
        debounceTask?.cancel()

        // Don't re-trigger when we're programmatically stripping the verb text
        guard !isStrippingVerb else { return }

        // If we already have a locked-in verb, treat the entire query as the search term
        if let verb = activeVerb {
            parsedInput = ParsedSpotlightInput(mode: .command, verb: verb, searchQuery: query)
        } else {
            // Check if the user just typed a verb followed by a space
            let parsed = SpotlightInputParser.parse(query)
            if let verb = parsed.verb, query.contains(" ") {
                // Lock in the verb and strip it from the text field
                activeVerb = verb
                parsedInput = ParsedSpotlightInput(mode: .command, verb: verb, searchQuery: parsed.searchQuery)
                isStrippingVerb = true
                query = parsed.searchQuery
                isStrippingVerb = false
                return
            }
            parsedInput = parsed
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
        defer { isSearching = false }

        switch searchMode {
        case .local:
            results = searchLocally(parsedInput.searchQuery, verb: parsedInput.verb)
        case .cloud:
            results = await searchAPI(parsedInput.searchQuery, verb: parsedInput.verb)
        }
    }

    // MARK: - Local Search

    private func searchLocally(_ query: String, verb: SpotlightVerb?) -> [SpotlightResultGroup] {
        let q = query.lowercased()
        let targetTypes = verb?.targetTypes ?? SpotlightResultType.allCases
        var groups: [SpotlightResultGroup] = []

        if targetTypes.contains(.plugin), let scanner, !q.isEmpty {
            let matches = scanner.plugins
                .filter {
                    $0.name.lowercased().contains(q) ||
                    ($0.manufacturer?.lowercased().contains(q) ?? false) ||
                    ($0.auDescription?.lowercased().contains(q) ?? false)
                }
                .sorted { relevanceScore($0.name, query: q) > relevanceScore($1.name, query: q) }
                .prefix(8)
                .map {
                    SpotlightResult(
                        id: $0.id.uuidString,
                        type: .plugin,
                        name: $0.name,
                        subtitle: $0.manufacturer ?? $0.auDescription,
                        format: $0.format.rawValue,
                        relevance: relevanceScore($0.name, query: q)
                    )
                }
            if !matches.isEmpty {
                groups.append(SpotlightResultGroup(type: .plugin, results: Array(matches)))
            }
        }

        if targetTypes.contains(.project), let scanner, !q.isEmpty {
            // Group sessions by project and search project names
            let seen = NSMutableSet()
            let matches = scanner.sessions
                .filter {
                    let name = $0.projectDisplayName.lowercased()
                    return name.contains(q) || $0.name.lowercased().contains(q)
                }
                .sorted { relevanceScore($0.projectDisplayName, query: q) > relevanceScore($1.projectDisplayName, query: q) }
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
                        relevance: relevanceScore($0.projectDisplayName, query: q)
                    )
                }
            if !matches.isEmpty {
                groups.append(SpotlightResultGroup(type: .project, results: Array(matches)))
            }
        }

        if targetTypes.contains(.bounce), let bounceService, !q.isEmpty {
            let matches = bounceService.bounces
                .filter { $0.fileName.lowercased().contains(q) }
                .sorted { relevanceScore($0.fileName, query: q) > relevanceScore($1.fileName, query: q) }
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
                .sorted { relevanceScore($0.name, query: q) > relevanceScore($1.name, query: q) }
                .prefix(8)
                .map {
                    SpotlightResult(
                        id: $0.id.uuidString,
                        type: .collection,
                        name: $0.name,
                        subtitle: $0.description,
                        format: nil,
                        relevance: relevanceScore($0.name, query: q)
                    )
                }
            if !matches.isEmpty {
                groups.append(SpotlightResultGroup(type: .collection, results: Array(matches)))
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
