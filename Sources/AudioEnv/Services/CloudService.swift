import Foundation
import os.log
import AppKit

/// Fetches and manages the unified view of all files in the user's cloud storage.
/// Aggregates backups, web uploads, and shared items from the API.
@MainActor
class CloudService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Cloud")

    // MARK: - Published state

    @Published private(set) var items: [CloudItem] = []
    @Published private(set) var storageUsage: CloudStorageUsage?
    @Published private(set) var isLoading = false
    @Published private(set) var isDownloading = false
    @Published private(set) var downloadProgress: Double = 0
    @Published var lastError: String?
    @Published var selectedFilter: CloudItemType?
    @Published var searchText = ""

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    // MARK: - Filtered items

    var filteredItems: [CloudItem] {
        var result = items
        if let filter = selectedFilter {
            result = result.filter { $0.itemType == filter }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                $0.fileType.lowercased().contains(query) ||
                ($0.format?.lowercased().contains(query) ?? false) ||
                ($0.senderUsername?.lowercased().contains(query) ?? false)
            }
        }
        return result
    }

    var backupCount: Int { items.filter { $0.itemType == .backup }.count }
    var uploadCount: Int { items.filter { $0.itemType == .upload }.count }
    var sharedCount: Int { items.filter { $0.itemType == .shared }.count }

    // MARK: - Load all

    func loadAll(token: String) async {
        isLoading = true
        lastError = nil

        async let files: () = loadCloudFiles(token: token)
        async let shared: () = loadSharedItems(token: token)
        async let storage: () = loadStorageUsage(token: token)
        _ = await (files, shared, storage)

        isLoading = false
    }

    // MARK: - Load cloud files (backups + uploads)

    private func loadCloudFiles(token: String) async {
        let url = URL(string: "\(baseURL)/api/upload/files")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                logger.warning("Cloud files returned status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                return
            }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            var cloudItems: [CloudItem] = []
            var seenKeys: Set<String> = []

            for category in ["plugins", "projects", "bounces"] {
                guard let entries = json[category] as? [[String: Any]] else { continue }
                for entry in entries {
                    guard let s3Key = entry["s3_key"] as? String else { continue }
                    guard !seenKeys.contains(s3Key) else { continue }
                    seenKeys.insert(s3Key)

                    let backupId = entry["backup_id"] as? String
                    let isPending = entry["pending"] as? Bool ?? false
                    let itemType: CloudItemType = backupId != nil ? .backup : .upload

                    let item = CloudItem(
                        id: (entry["id"] as? String) ?? s3Key,
                        name: entry["name"] as? String ?? (s3Key as NSString).lastPathComponent,
                        itemType: itemType,
                        fileType: entry["file_type"] as? String ?? category,
                        s3Key: s3Key,
                        sizeBytes: Int64(entry["size_bytes"] as? Int ?? 0),
                        uploadedAt: parseDate(entry["uploaded_at"]),
                        format: entry["format"] as? String,
                        backupId: backupId,
                        shareId: nil,
                        senderUsername: nil,
                        isPending: isPending,
                        scopeDescription: entry["scope_description"] as? String
                    )
                    cloudItems.append(item)
                }
            }

            // Merge with existing shared items (don't overwrite them)
            let existingShared = items.filter { $0.itemType == .shared }
            items = cloudItems + existingShared
            items.sort { ($0.uploadedAt ?? .distantPast) > ($1.uploadedAt ?? .distantPast) }

        } catch {
            logger.error("Failed to load cloud files: \(error)")
            lastError = "Failed to load cloud files"
        }
    }

    // MARK: - Load shared items

    private func loadSharedItems(token: String) async {
        let url = URL(string: "\(baseURL)/api/sharing/content-share/shared-with-me?per_page=200")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let shareItems = json["items"] as? [[String: Any]] else { return }

            var sharedItems: [CloudItem] = []
            for entry in shareItems {
                let status = entry["status"] as? String ?? ""
                guard status == "active" else { continue }

                let entityType = entry["entity_type"] as? String ?? "file"
                let entityName = entry["entity_name"] as? String ?? "Shared item"
                let shareId = entry["id"] as? String ?? UUID().uuidString

                let item = CloudItem(
                    id: shareId,
                    name: entityName,
                    itemType: .shared,
                    fileType: entityType,
                    s3Key: "shared/\(shareId)",
                    sizeBytes: 0,
                    uploadedAt: parseDate(entry["uploaded_at"] ?? entry["created_at"]),
                    format: nil,
                    backupId: nil,
                    shareId: shareId,
                    senderUsername: entry["owner_username"] as? String,
                    isPending: false,
                    scopeDescription: nil
                )
                sharedItems.append(item)
            }

            // Merge with existing backup/upload items
            let existingNonShared = items.filter { $0.itemType != .shared }
            items = existingNonShared + sharedItems
            items.sort { ($0.uploadedAt ?? .distantPast) > ($1.uploadedAt ?? .distantPast) }

        } catch {
            logger.error("Failed to load shared items: \(error)")
        }
    }

    // MARK: - Load storage usage

    private func loadStorageUsage(token: String) async {
        let url = URL(string: "\(baseURL)/api/backup/storage")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return }

            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            storageUsage = CloudStorageUsage(
                usedBytes: Int64(json["storage_used_bytes"] as? Int ?? 0),
                limitBytes: (json["storage_limit_bytes"] as? Int).map { Int64($0) },
                tier: json["tier"] as? String ?? "free"
            )
        } catch {
            logger.error("Failed to load storage usage: \(error)")
        }
    }

    // MARK: - Download

    func downloadItem(_ item: CloudItem, token: String) async {
        // Get presigned download URL from the appropriate endpoint
        let downloadURL: URL?

        switch item.itemType {
        case .backup:
            downloadURL = await getBackupDownloadURL(item: item, token: token)
        case .upload:
            downloadURL = await getUploadDownloadURL(item: item, token: token)
        case .shared:
            downloadURL = await getSharedDownloadURL(item: item, token: token)
        }

        guard let url = downloadURL else {
            lastError = "Failed to get download URL"
            return
        }

        // Show save panel
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.name
        panel.canCreateDirectories = true
        let response = panel.runModal()
        guard response == .OK, let saveURL = panel.url else { return }

        // Download
        isDownloading = true
        downloadProgress = 0

        do {
            let (tempURL, _) = try await URLSession.shared.download(from: url)
            try FileManager.default.moveItem(at: tempURL, to: saveURL)
            downloadProgress = 1.0
            logger.info("Downloaded \(item.name) to \(saveURL.path)")
        } catch {
            lastError = "Download failed: \(error.localizedDescription)"
            logger.error("Download failed: \(error)")
        }

        isDownloading = false
    }

    private func getBackupDownloadURL(item: CloudItem, token: String) async -> URL? {
        guard let backupId = item.backupId else { return nil }
        let url = URL(string: "\(baseURL)/api/backup/download-url")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["backup_id": backupId, "s3_key": item.s3Key]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["url"] as? String).flatMap { URL(string: $0) }
        } catch { return nil }
    }

    private func getUploadDownloadURL(item: CloudItem, token: String) async -> URL? {
        let url = URL(string: "\(baseURL)/api/upload/download-url")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["s3_key": item.s3Key]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["url"] as? String).flatMap { URL(string: $0) }
        } catch { return nil }
    }

    private func getSharedDownloadURL(item: CloudItem, token: String) async -> URL? {
        guard let shareId = item.shareId else { return nil }
        let url = URL(string: "\(baseURL)/api/sharing/content-share/shared-with-me/download/\(shareId)")!
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (json?["url"] as? String).flatMap { URL(string: $0) }
        } catch { return nil }
    }

    // MARK: - Helpers

    private func parseDate(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}
