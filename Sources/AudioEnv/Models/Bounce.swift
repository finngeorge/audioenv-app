import Foundation

// MARK: - Bounce folder

/// A linked folder that contains audio bounces/exports.
struct BounceFolder: Identifiable, Hashable, Codable {
    let id: UUID
    let userId: UUID
    let folderPath: String
    let autoScan: Bool
    let lastScannedAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case folderPath = "folder_path"
        case autoScan = "auto_scan"
        case lastScannedAt = "last_scanned_at"
        case createdAt = "created_at"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: BounceFolder, rhs: BounceFolder) -> Bool { lhs.id == rhs.id }

    /// Display name: last path component
    var displayName: String {
        (folderPath as NSString).lastPathComponent
    }
}

// MARK: - Bounce

/// A single audio bounce file (WAV, MP3, AIFF, FLAC).
struct Bounce: Identifiable, Hashable, Codable {
    let id: UUID
    let userId: UUID
    let bounceFolderId: UUID
    let fileName: String
    let filePath: String
    let fileSizeBytes: Int
    let format: String
    let durationSeconds: Double?
    let sampleRate: Int?
    let bitDepth: Int?
    let createdAt: Date
    let fileModifiedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case bounceFolderId = "bounce_folder_id"
        case fileName = "file_name"
        case filePath = "file_path"
        case fileSizeBytes = "file_size_bytes"
        case format
        case durationSeconds = "duration_seconds"
        case sampleRate = "sample_rate"
        case bitDepth = "bit_depth"
        case createdAt = "created_at"
        case fileModifiedAt = "file_modified_at"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: Bounce, rhs: Bounce) -> Bool { lhs.id == rhs.id }

    /// Whether the file exists on the local filesystem.
    var isLocallyAvailable: Bool {
        FileManager.default.fileExists(atPath: filePath)
    }

    /// Formatted file size
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSizeBytes), countStyle: .file)
    }

    /// Formatted duration (mm:ss)
    var formattedDuration: String? {
        guard let dur = durationSeconds else { return nil }
        let mins = Int(dur) / 60
        let secs = Int(dur) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    /// Formatted sample rate (e.g. "48 kHz")
    var formattedSampleRate: String? {
        guard let sr = sampleRate else { return nil }
        if sr >= 1000 {
            return "\(sr / 1000) kHz"
        }
        return "\(sr) Hz"
    }
}

// MARK: - Bounce-project link

struct BounceProjectLink: Identifiable, Codable {
    let id: UUID
    let bounceId: UUID
    let scannedSessionId: UUID
    let linkType: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case bounceId = "bounce_id"
        case scannedSessionId = "scanned_session_id"
        case linkType = "link_type"
        case createdAt = "created_at"
    }
}

// MARK: - Bounce suggestion

struct BounceSuggestion: Identifiable, Codable {
    let bounceId: String
    let bounceFileName: String
    let scannedSessionId: String
    let projectName: String
    let confidence: Double

    var id: String { "\(bounceId)-\(scannedSessionId)" }

    enum CodingKeys: String, CodingKey {
        case bounceId = "bounce_id"
        case bounceFileName = "bounce_file_name"
        case scannedSessionId = "scanned_session_id"
        case projectName = "project_name"
        case confidence
    }
}

// MARK: - Local scan result (before API sync)

/// Represents a locally scanned bounce file with metadata extracted via AVFoundation.
struct LocalBounceInfo {
    let fileName: String
    let filePath: String
    let fileSizeBytes: Int
    let format: String
    let durationSeconds: Double?
    let sampleRate: Int?
    let bitDepth: Int?
    let fileModifiedAt: Date
}
