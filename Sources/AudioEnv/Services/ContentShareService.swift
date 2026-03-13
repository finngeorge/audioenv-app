import Foundation

@MainActor
class ContentShareService: ObservableObject {
    @Published var isSharing = false
    @Published var lastError: String?
    @Published var lastSuccess: String?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    struct ContentShareResponse: Codable {
        let id: String
        let owner_id: String
        let owner_username: String?
        let recipient_id: String
        let recipient_username: String?
        let entity_type: String
        let entity_id: String
        let entity_name: String?
        let permissions: String
        let message: String?
        let status: String
        let created_at: String
    }

    func share(
        entityType: String,
        entityId: String,
        recipientUsername: String? = nil,
        recipientEmail: String? = nil,
        permissions: String = "download",
        message: String? = nil,
        token: String
    ) async throws -> ContentShareResponse {
        isSharing = true
        lastError = nil
        lastSuccess = nil
        defer { isSharing = false }

        guard let url = URL(string: "\(baseURL)/api/sharing/content-share") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "entity_type": entityType,
            "entity_id": entityId,
            "permissions": permissions,
        ]
        if let username = recipientUsername, !username.isEmpty {
            body["recipient_username"] = username
        }
        if let email = recipientEmail, !email.isEmpty {
            body["recipient_email"] = email
        }
        if let msg = message, !msg.isEmpty {
            body["message"] = msg
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if httpResponse.statusCode == 200 || httpResponse.statusCode == 201 {
            let result = try JSONDecoder().decode(ContentShareResponse.self, from: data)
            lastSuccess = "Shared with \(result.recipient_username ?? "user")"
            return result
        } else {
            // Try to extract error detail
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let detail = errorJson["detail"] as? String {
                lastError = detail
                throw NSError(domain: "ContentShare", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: detail])
            }
            lastError = "Share failed (\(httpResponse.statusCode))"
            throw URLError(.badServerResponse)
        }
    }
}
