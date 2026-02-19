import Foundation

// MARK: - Collection model

/// A user-created collection for organizing projects and/or bounces.
struct AudioCollection: Identifiable, Hashable, Codable {
    let id: UUID
    let userId: UUID
    let name: String
    let description: String?
    let color: String?
    let contentTypes: [String]
    let createdAt: Date
    let updatedAt: Date
    let projectCount: Int
    let bounceCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name, description, color
        case contentTypes = "content_types"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case projectCount = "project_count"
        case bounceCount = "bounce_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        userId = try container.decode(UUID.self, forKey: .userId)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        contentTypes = try container.decodeIfPresent([String].self, forKey: .contentTypes) ?? ["projects"]
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        projectCount = try container.decodeIfPresent(Int.self, forKey: .projectCount) ?? 0
        bounceCount = try container.decodeIfPresent(Int.self, forKey: .bounceCount) ?? 0
    }

    var hasProjects: Bool { contentTypes.contains("projects") }
    var hasBounces: Bool { contentTypes.contains("bounces") }
    var hasPluginDeps: Bool { contentTypes.contains("plugin_deps") }

    /// Total item count across projects and bounces.
    var totalItemCount: Int { projectCount + bounceCount }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: AudioCollection, rhs: AudioCollection) -> Bool { lhs.id == rhs.id }
}

// MARK: - Content type enum for UI

enum CollectionContentType: String, CaseIterable, Identifiable {
    case projects
    case bounces
    case pluginDeps = "plugin_deps"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .projects: return "Projects"
        case .bounces: return "Bounces"
        case .pluginDeps: return "Plugin Deps"
        }
    }

    var icon: String {
        switch self {
        case .projects: return "folder"
        case .bounces: return "waveform"
        case .pluginDeps: return "puzzlepiece"
        }
    }
}

// MARK: - Collection project membership

struct CollectionProjectMembership: Identifiable, Codable {
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

// MARK: - Collection bounce membership

struct CollectionBounceMembership: Identifiable, Codable {
    let id: UUID
    let collectionId: UUID
    let bounceId: UUID
    let addedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case collectionId = "collection_id"
        case bounceId = "bounce_id"
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
