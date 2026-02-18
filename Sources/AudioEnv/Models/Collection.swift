import Foundation

// MARK: - Collection model

/// A user-created collection for organizing projects.
struct AudioCollection: Identifiable, Hashable, Codable {
    let id: UUID
    let userId: UUID
    let name: String
    let description: String?
    let color: String?
    let createdAt: Date
    let updatedAt: Date
    let projectCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, description, color
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case projectCount = "project_count"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AudioCollection, rhs: AudioCollection) -> Bool { lhs.id == rhs.id }
}

// MARK: - Collection project membership

struct CollectionProject: Identifiable, Codable {
    let id: UUID
    let collectionId: UUID
    let scannedSessionId: UUID
    let addedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case collectionId = "collection_id"
        case scannedSessionId = "scanned_session_id"
        case addedAt = "added_at"
    }
}

// MARK: - Tag metadata for sessions

struct SessionTagMetadata: Codable {
    let id: String
    let progressStatus: String?
    let client: [String]?
    let collaborators: [String]?

    enum CodingKeys: String, CodingKey {
        case id
        case progressStatus = "progress_status"
        case client, collaborators
    }
}

// MARK: - Custom progress option

struct ProgressOption: Identifiable, Codable {
    let id: UUID
    let userId: UUID
    let label: String
    let sortOrder: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case label
        case sortOrder = "sort_order"
        case createdAt = "created_at"
    }
}
