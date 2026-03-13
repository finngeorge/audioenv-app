import Foundation

/// Defines the S3 bucket structure and path generation for backups
///
/// Bucket Structure:
/// ```
/// audioenv-backups/                  # Single bucket for all users
///   users/
///     {user-id}/                     # UUID (stable, immutable)
///       plugins/                     # Shared plugin pool (deduplicated)
///         {checksum}.zip             # Each plugin stored once by SHA-256
///       backups/
///         {backup-id}/               # Timestamp + UUID
///           metadata.json            # Backup scope, stats, date, plugin refs
///           projects/
///             {project-name}.zip
///           bounces/
///             {format}/{fileName}
/// ```
///
/// Considerations:
/// - Use user UUID (not username) for path stability
/// - Each backup gets a unique ID for versioning
/// - Plugins stored in shared pool, deduplicated by SHA-256 checksum
/// - Backup manifests reference plugin checksums (no per-backup plugin copies)
/// - Metadata enables restore workflow and backup browsing
/// - S3 "folders" are created implicitly by upload paths
struct BackupPath {

    /// The S3 bucket name (configured by user or auto-created in paid tier)
    static let defaultBucketName = "audioenv-backups"

    /// Generate a unique backup ID (sortable by time)
    static func generateBackupId() -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let uuid = UUID().uuidString.prefix(8)
        return "\(timestamp)-\(uuid)"
    }

    /// Generate S3 key for backup metadata
    /// - Parameters:
    ///   - userId: User's UUID (stable identifier)
    ///   - backupId: Unique backup identifier
    /// - Returns: S3 key like "users/ABC-123/backups/2026-02-06-XYZ/metadata.json"
    static func metadataKey(userId: String, backupId: String) -> String {
        "users/\(userId)/backups/\(backupId)/metadata.json"
    }

    /// Generate S3 key for a plugin in the shared plugin pool (deduplicated across all backups)
    /// - Parameters:
    ///   - userId: User's UUID
    ///   - checksum: SHA-256 checksum of the plugin binary
    /// - Returns: S3 key like "users/ABC-123/plugins/sha256hash.zip"
    static func sharedPluginKey(userId: String, checksum: String) -> String {
        "users/\(userId)/plugins/\(checksum).zip"
    }

    /// Legacy per-backup plugin key (for reading old backups)
    static func pluginKey(userId: String, backupId: String, checksum: String, pluginName: String) -> String {
        "users/\(userId)/backups/\(backupId)/plugins/\(checksum).zip"
    }

    /// Prefix for listing all plugins in the shared pool
    static func sharedPluginsPrefix(userId: String) -> String {
        "users/\(userId)/plugins/"
    }

    /// Generate S3 key for a project session file
    /// - Parameters:
    ///   - userId: User's UUID
    ///   - backupId: Unique backup identifier
    ///   - projectName: Name of the project
    ///   - sessionName: Session file name
    /// - Returns: S3 key like "users/ABC-123/backups/2026-02-06-XYZ/projects/MyProject/MyProject.als"
    static func projectKey(userId: String, backupId: String, projectName: String, sessionName: String) -> String {
        // Sanitize project and session names for S3
        let safeProject = sanitizeForS3(projectName)
        let safeSession = sanitizeForS3(sessionName)
        return "users/\(userId)/backups/\(backupId)/projects/\(safeProject)/\(safeSession)"
    }

    /// Generate S3 key for a project zip (entire project folder)
    /// - Parameters:
    ///   - userId: User's UUID
    ///   - backupId: Unique backup identifier
    ///   - projectName: Name of the project
    /// - Returns: S3 key like "users/ABC-123/backups/2026-02-06-XYZ/projects/MyProject.zip"
    static func projectZipKey(userId: String, backupId: String, projectName: String) -> String {
        let safeProject = sanitizeForS3(projectName)
        return "users/\(userId)/backups/\(backupId)/projects/\(safeProject).zip"
    }

    /// Generate S3 key for a bounce file
    /// - Parameters:
    ///   - userId: User's UUID
    ///   - backupId: Unique backup identifier
    ///   - format: Audio format (wav, mp3, etc.)
    ///   - fileName: Bounce file name
    /// - Returns: S3 key like "users/ABC-123/backups/2026-02-06-XYZ/bounces/wav/MySong.wav"
    static func bounceKey(userId: String, backupId: String, format: String, fileName: String) -> String {
        let safeFormat = sanitizeForS3(format)
        let safeFileName = sanitizeForS3(fileName)
        return "users/\(userId)/backups/\(backupId)/bounces/\(safeFormat)/\(safeFileName)"
    }

    /// List all backups for a user
    /// - Parameter userId: User's UUID
    /// - Returns: S3 prefix like "users/ABC-123/backups/"
    static func userBackupsPrefix(userId: String) -> String {
        "users/\(userId)/backups/"
    }

    /// Get the user's root folder
    /// - Parameter userId: User's UUID
    /// - Returns: S3 prefix like "users/ABC-123/"
    static func userRootPrefix(userId: String) -> String {
        "users/\(userId)/"
    }

    /// Sanitize a string for use in S3 keys
    /// - Parameter name: Original name
    /// - Returns: Safe name (alphanumeric, hyphens, underscores only)
    private static func sanitizeForS3(_ name: String) -> String {
        // Replace invalid characters with hyphens
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. "))
        let sanitized = name.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "-" }
            .joined()

        // Remove consecutive hyphens and trim
        return sanitized
            .replacingOccurrences(of: "--+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}

/// Metadata stored with each backup
struct BackupMetadata: Codable {
    let backupId: String
    let userId: String
    let backupName: String
    let scope: String  // Description of what was backed up
    let createdAt: Date
    let pluginCount: Int
    let projectCount: Int
    let sessionCount: Int
    let totalSizeBytes: UInt64
    let appVersion: String

    /// Format for display
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSizeBytes), countStyle: .file)
    }
}

// MARK: - Bucket Setup Considerations
//
// Production Bucket Strategy (Paid Tier)
//
// 1. Bucket Creation:
//    - Single shared bucket: audioenv-backups (RECOMMENDED)
//    - Shared bucket is simpler, cheaper, easier to manage
//
// 2. Access Control:
//    - IAM policy: Users can only access users/{their-uuid}/*
//    - Use presigned URLs for time-limited access
//
// 3. Storage Classes:
//    - STANDARD for recent backups
//    - STANDARD_IA for older backups
//    - Use lifecycle policies to auto-transition
//
// 4. Cost Optimization:
//    - Plugin deduplication by checksum
//    - Compression (already using .zip)
//    - Set storage quotas per user tier
//
// 5. Database Tracking:
//    - Store s3_key in UserPlugin table
//    - Track storage_used_bytes in User table
//    - Enforce tier limits before upload
