import Foundation

// MARK: - Cloud item type

enum CloudItemType: String, CaseIterable, Identifiable {
    case backup  = "Backup"
    case upload  = "Upload"
    case shared  = "Shared"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .backup: return "arrow.up.circle.fill"
        case .upload: return "doc.circle.fill"
        case .shared: return "person.2.circle.fill"
        }
    }
}

// MARK: - Cloud item

/// A single file or backup in the user's cloud storage.
struct CloudItem: Identifiable, Hashable {
    let id: String
    let name: String
    let itemType: CloudItemType
    let fileType: String            // "plugin", "project", "bounce", "collection"
    let s3Key: String
    let sizeBytes: Int64
    let uploadedAt: Date?
    let format: String?             // Plugin format (AU/VST3) or audio format (wav/mp3)
    let backupId: String?           // For backup items, links to BackupListItem
    let shareId: String?            // For shared items
    let senderUsername: String?     // For shared items
    let isPending: Bool             // Pending sync flag
    let scopeDescription: String?   // Verbose backup scope (shown in detail pane only)

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    /// SF Symbol icons for the file type — used in the file list subtitle
    var fileTypeIcons: [String] {
        switch fileType {
        case "plugin":  return ["puzzlepiece.extension"]
        case "project": return ["folder.fill"]
        case "bounce":  return ["waveform"]
        default:        return []
        }
    }

    // Hashable by s3Key for deduplication
    func hash(into hasher: inout Hasher) { hasher.combine(s3Key) }
    static func == (lhs: CloudItem, rhs: CloudItem) -> Bool { lhs.s3Key == rhs.s3Key }
}

// MARK: - Storage usage

struct CloudStorageUsage {
    let usedBytes: Int64
    let limitBytes: Int64?
    let tier: String

    var usagePercent: Double {
        guard let limit = limitBytes, limit > 0 else { return 0 }
        return min(Double(usedBytes) / Double(limit), 1.0)
    }

    var formattedUsed: String {
        ByteCountFormatter.string(fromByteCount: usedBytes, countStyle: .file)
    }

    var formattedLimit: String? {
        guard let limit = limitBytes else { return nil }
        return ByteCountFormatter.string(fromByteCount: limit, countStyle: .file)
    }

    var hasLimit: Bool { limitBytes != nil }
}
