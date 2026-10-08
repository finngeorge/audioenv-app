import Foundation

/// One reason behind a prediction ("Name matches “candy bass”", +0.60).
struct LinkReason: Codable, Hashable {
    let signal: String
    let label: String
    let weight: Double
}

/// A project the bounce might belong to.
struct LinkPrediction: Codable, Hashable, Identifiable {
    let scannedSessionId: UUID
    let projectName: String
    let score: Double
    let reasons: [LinkReason]

    var id: UUID { scannedSessionId }

    enum CodingKeys: String, CodingKey {
        case scannedSessionId = "scanned_session_id"
        case projectName = "project_name"
        case score, reasons
    }
}

struct LinkQueueBounce: Codable, Hashable {
    let id: UUID
    let fileName: String
    let filePath: String
    let format: String
    let fileSizeBytes: Int
    let durationSeconds: Double?
    let bpm: Int?
    let fileModifiedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, format, bpm
        case fileName = "file_name"
        case filePath = "file_path"
        case fileSizeBytes = "file_size_bytes"
        case durationSeconds = "duration_seconds"
        case fileModifiedAt = "file_modified_at"
    }

    /// A playable Bounce for AudioPlayerService (the file is on this Mac).
    var asBounce: Bounce {
        Bounce(id: id, userId: UUID(), bounceFolderId: UUID(), fileName: fileName, filePath: filePath,
               fileSizeBytes: fileSizeBytes, format: format, durationSeconds: durationSeconds,
               sampleRate: nil, bitDepth: nil, bitrate: nil, createdAt: fileModifiedAt,
               fileModifiedAt: fileModifiedAt, bpm: bpm)
    }
}

/// A bounce awaiting review: its predictions, best first.
struct LinkQueueItem: Hashable, Identifiable {
    let bounce: LinkQueueBounce
    let predictions: [LinkPrediction]

    var id: UUID { bounce.id }
}

extension LinkQueueItem: Decodable {
    enum CodingKeys: String, CodingKey {
        case bounce, score, reasons, alternatives
        case scannedSessionId = "scanned_session_id"
        case projectName = "project_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bounce = try c.decode(LinkQueueBounce.self, forKey: .bounce)
        let top = LinkPrediction(
            scannedSessionId: try c.decode(UUID.self, forKey: .scannedSessionId),
            projectName: try c.decode(String.self, forKey: .projectName),
            score: try c.decode(Double.self, forKey: .score),
            reasons: try c.decode([LinkReason].self, forKey: .reasons)
        )
        predictions = [top] + (try c.decode([LinkPrediction].self, forKey: .alternatives))
    }
}

/// Bounces predicted to belong to the same song.
struct LinkQueueGroup: Decodable, Hashable, Identifiable {
    let songKey: String
    let projectName: String
    var items: [LinkQueueItem]

    var id: String { songKey }

    enum CodingKeys: String, CodingKey {
        case items
        case songKey = "song_key"
        case projectName = "project_name"
    }
}

struct LinkQueueResponse: Decodable {
    let totalBounces: Int
    let totalGroups: Int
    let groups: [LinkQueueGroup]

    enum CodingKeys: String, CodingKey {
        case groups
        case totalBounces = "total_bounces"
        case totalGroups = "total_groups"
    }
}

/// A link the user made recently (undoable).
struct RecentLink: Decodable, Identifiable, Hashable {
    let linkId: UUID
    let bounceId: UUID
    let fileName: String
    let scannedSessionId: UUID
    let projectName: String
    let linkType: String
    let createdAt: Date

    var id: UUID { linkId }

    enum CodingKeys: String, CodingKey {
        case linkId = "link_id"
        case bounceId = "bounce_id"
        case fileName = "file_name"
        case scannedSessionId = "scanned_session_id"
        case projectName = "project_name"
        case linkType = "link_type"
        case createdAt = "created_at"
    }
}
