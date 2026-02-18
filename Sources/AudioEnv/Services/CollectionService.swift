import Foundation
import os.log

/// Manages collections and session tag metadata via the API.
@MainActor
class CollectionService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Collections")

    // MARK: - Published State

    @Published var collections: [Collection] = []
    @Published var isLoading = false
    @Published var lastError: String?

    /// Preset progress labels (always available)
    let presetProgressLabels = ["Demo", "Tracking", "Mixing", "Mastering", "Archived"]

    /// User-created custom progress options
    @Published var customProgressOptions: [ProgressOption] = []

    /// Autocomplete cache
    @Published var knownCollaborators: [String] = []
    @Published var knownClients: [String] = []

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    // MARK: - Collections CRUD

    func fetchCollections(token: String) async {
        isLoading = true
        lastError = nil

        do {
            var components = URLComponents(string: "\(baseURL)/api/collections/")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "10000")]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw CollectionServiceError.serverError("GET /collections returned \(status)")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            collections = Self.decodeItems(data: data, decoder: decoder) ?? []
            logger.info("Fetched \(self.collections.count) collections")
        } catch {
            lastError = error.localizedDescription
            logger.error("fetchCollections failed: \(error)")
        }

        isLoading = false
    }

    func createCollection(name: String, description: String?, color: String?, token: String) async -> Collection? {
        do {
            let url = URL(string: "\(baseURL)/api/collections/")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            var payload: [String: Any] = ["name": name]
            if let desc = description { payload["description"] = desc }
            if let col = color { payload["color"] = col }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw CollectionServiceError.serverError("POST /collections returned \(status)")
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let collection = try decoder.decode(Collection.self, from: data)
            collections.insert(collection, at: 0)
            logger.info("Created collection: \(collection.name)")
            return collection
        } catch {
            lastError = error.localizedDescription
            logger.error("createCollection failed: \(error)")
            return nil
        }
    }

    func updateCollection(id: UUID, name: String?, description: String?, color: String?, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/collections/\(id)")!
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            var payload: [String: Any] = [:]
            if let n = name { payload["name"] = n }
            if let d = description { payload["description"] = d }
            if let c = color { payload["color"] = c }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let updated = try decoder.decode(Collection.self, from: data)
            if let idx = collections.firstIndex(where: { $0.id == id }) {
                collections[idx] = updated
            }
        } catch {
            lastError = error.localizedDescription
            logger.error("updateCollection failed: \(error)")
        }
    }

    func deleteCollection(id: UUID, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/collections/\(id)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            collections.removeAll { $0.id == id }
            logger.info("Deleted collection \(id)")
        } catch {
            lastError = error.localizedDescription
            logger.error("deleteCollection failed: \(error)")
        }
    }

    // MARK: - Collection Projects

    func addProjects(collectionId: UUID, sessionIds: [UUID], token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/collections/\(collectionId)/projects")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let payload = sessionIds.map { ["scanned_session_id": $0.uuidString] }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            // Refresh collections to update project counts
            await fetchCollections(token: token)
            logger.info("Added \(sessionIds.count) projects to collection \(collectionId)")
        } catch {
            lastError = error.localizedDescription
            logger.error("addProjects failed: \(error)")
        }
    }

    func removeProject(collectionId: UUID, sessionId: UUID, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/collections/\(collectionId)/projects/\(sessionId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            await fetchCollections(token: token)
        } catch {
            lastError = error.localizedDescription
            logger.error("removeProject failed: \(error)")
        }
    }

    // MARK: - Session Tag Metadata

    func updateSessionMetadata(sessionId: UUID, progressStatus: String?, client: [String]?, collaborators: [String]?, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/tags/sessions/\(sessionId)/metadata")!
            var request = URLRequest(url: url)
            request.httpMethod = "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            var payload: [String: Any] = [:]
            if let ps = progressStatus { payload["progress_status"] = ps }
            if let cl = client { payload["client"] = cl }
            if let co = collaborators { payload["collaborators"] = co }
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                logger.info("Updated metadata for session \(sessionId)")
            } else {
                logger.warning("Tag update returned \(status)")
            }
        } catch {
            logger.error("updateSessionMetadata failed: \(error)")
        }
    }

    func fetchSessionMetadata(sessionId: UUID, token: String) async -> SessionTagMetadata? {
        do {
            let url = URL(string: "\(baseURL)/api/tags/sessions/\(sessionId)/metadata")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }

            return try JSONDecoder().decode(SessionTagMetadata.self, from: data)
        } catch {
            logger.error("fetchSessionMetadata failed: \(error)")
            return nil
        }
    }

    // MARK: - Progress Options

    func fetchProgressOptions(token: String) async {
        do {
            var components = URLComponents(string: "\(baseURL)/api/tags/progress-options")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "10000")]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            customProgressOptions = Self.decodeItems(data: data, decoder: decoder) ?? []
        } catch {
            logger.error("fetchProgressOptions failed: \(error)")
        }
    }

    /// All available progress labels: presets + custom
    var allProgressLabels: [String] {
        presetProgressLabels + customProgressOptions.map(\.label)
    }

    // MARK: - Autocomplete

    func fetchAutocompleteData(token: String) async {
        // Collaborators
        do {
            var components = URLComponents(string: "\(baseURL)/api/tags/collaborators")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "10000")]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                knownCollaborators = Self.decodeItems(data: data, decoder: JSONDecoder()) ?? []
            }
        } catch {
            logger.error("fetchCollaborators failed: \(error)")
        }

        // Clients
        do {
            var components = URLComponents(string: "\(baseURL)/api/tags/clients")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "10000")]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                knownClients = Self.decodeItems(data: data, decoder: JSONDecoder()) ?? []
            }
        } catch {
            logger.error("fetchClients failed: \(error)")
        }
    }

    // MARK: - Pagination Helper

    /// Decode a list response that may be either a bare array (old API) or
    /// a paginated wrapper `{ "items": [...], ... }` (new API).
    private static func decodeItems<T: Decodable>(data: Data, decoder: JSONDecoder) -> [T]? {
        // Try paginated wrapper first (new format)
        if let paginated = try? decoder.decode(PaginatedResponse<T>.self, from: data) {
            return paginated.items
        }
        // Fall back to bare array (old format, for backwards compat during rollout)
        return try? decoder.decode([T].self, from: data)
    }
}

// MARK: - Errors

enum CollectionServiceError: Error, LocalizedError {
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .serverError(let message): return message
        }
    }
}
