import Foundation
import os.log

/// Syncs local scan data (plugins + sessions) to the AudioEnv backend.
@MainActor
class SyncService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Sync")

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastSyncError: String?

    #if DEBUG
    private let baseURL = "http://localhost:8001"
    #else
    private let baseURL = "https://api.audioenv.com"
    #endif

    // MARK: - Device identification

    /// Stable UUID for this device, generated once and stored in UserDefaults.
    var deviceUUID: String {
        let key = "com.audioenv.deviceUUID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newUUID = UUID().uuidString
        UserDefaults.standard.set(newUUID, forKey: key)
        return newUUID
    }

    /// Human-readable name for this Mac.
    var deviceName: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    // MARK: - Public API

    /// Sync plugins and sessions to the backend.
    func syncToCloud(plugins: [AudioPlugin], sessions: [AudioSession], token: String) async {
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        logger.info("Starting cloud sync: \(plugins.count) plugins, \(sessions.count) sessions")

        do {
            // 1. Register device
            try await registerDevice(token: token)

            // 2. Sync plugins
            try await syncPlugins(plugins, token: token)

            // 3. Sync sessions (enriched with device + project info)
            try await syncSessions(sessions, token: token)

            lastSyncDate = Date()
            logger.info("Cloud sync completed successfully")
        } catch {
            lastSyncError = error.localizedDescription
            logger.error("Cloud sync failed: \(error)")
        }

        isSyncing = false
    }

    // MARK: - Device registration

    private func registerDevice(token: String) async throws {
        let payload: [String: Any] = [
            "device_uuid": deviceUUID,
            "device_name": deviceName,
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
        ]

        let url = URL(string: "\(baseURL)/api/devices/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.warning("Device registration returned status \(statusCode), continuing sync")
            return
        }

        logger.info("Device registered: \(self.deviceName)")
    }

    // MARK: - Plugin sync

    private func syncPlugins(_ plugins: [AudioPlugin], token: String) async throws {
        let payload = plugins.map { plugin -> [String: Any?] in
            [
                "plugin_name": plugin.name,
                "plugin_format": plugin.format.rawValue,
                "bundle_id": plugin.bundleID,
                "version": plugin.version,
                "manufacturer": plugin.manufacturer,
            ]
        }

        let url = URL(string: "\(baseURL)/api/plugins/scan")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SyncError.serverError("Plugin sync failed with status \(statusCode)")
        }

        logger.info("Synced \(plugins.count) plugins")
    }

    // MARK: - Session sync

    private func syncSessions(_ sessions: [AudioSession], token: String) async throws {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let sessionPayloads = sessions.compactMap { session -> [String: Any]? in
            var dict: [String: Any] = [
                "session_name": session.name,
                "session_format": session.format.rawValue,
                "file_size_bytes": session.fileSize,
                "modified_date": dateFormatter.string(from: session.modifiedDate),
                "is_backup": session.isBackup,
                "project_name": session.projectDisplayName,
            ]

            // Extract metadata from ParsedProject
            if let project = session.project {
                switch project {
                case .ableton(let ableton):
                    dict["track_count"] = ableton.tracks.count
                    dict["plugin_count"] = ableton.usedPlugins.count
                    dict["sample_count"] = ableton.samplePaths.count
                    dict["tempo"] = ableton.tempo
                    dict["used_plugins"] = ableton.usedPlugins
                case .logic(let logic):
                    dict["sample_count"] = logic.mediaFiles.count
                    if let tempo = logic.tempo {
                        dict["tempo"] = tempo
                    }
                    if !logic.pluginHints.isEmpty {
                        dict["used_plugins"] = logic.pluginHints
                        dict["plugin_count"] = logic.pluginHints.count
                    }
                case .proTools(let proTools):
                    dict["sample_count"] = proTools.audioFiles.count
                    if !proTools.pluginNames.isEmpty {
                        dict["used_plugins"] = proTools.pluginNames
                        dict["plugin_count"] = proTools.pluginNames.count
                    }
                }
            }

            return dict
        }

        // Wrap in device-aware envelope
        let wrapper: [String: Any] = [
            "device_uuid": deviceUUID,
            "device_name": deviceName,
            "sessions": sessionPayloads,
        ]

        let url = URL(string: "\(baseURL)/api/sessions/sync")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: wrapper)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SyncError.serverError("Session sync failed with status \(statusCode)")
        }

        logger.info("Synced \(sessions.count) sessions")
    }

    // MARK: - S3 Config Sync

    /// Sync S3 backup configuration to the backend.
    func syncS3Config(bucket: String, region: String, accessKey: String, secretKey: String, token: String) async {
        let payload: [String: Any] = [
            "bucket_name": bucket,
            "region": region,
            "access_key": accessKey,
            "secret_key": secretKey,
        ]

        let url = URL(string: "\(baseURL)/api/backup/config")!
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 200 {
                logger.info("S3 config synced to backend")
            } else {
                logger.warning("S3 config sync returned status \(statusCode)")
            }
        } catch {
            logger.error("Failed to sync S3 config: \(error)")
        }
    }

    // MARK: - Backup Manifest Sync

    /// Sync a backup manifest to the backend after successful backup.
    func syncBackupManifest(manifest: BackupManifest, token: String) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        guard let manifestData = try? encoder.encode(manifest),
              let manifestDict = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any] else {
            logger.error("Failed to encode manifest for sync")
            return
        }

        let payload: [String: Any] = [
            "backup_id": manifest.backupId,
            "backup_name": manifest.backupName,
            "scope_description": manifest.scopeDescription,
            "plugin_count": manifest.pluginCount,
            "project_count": manifest.projectCount,
            "session_count": manifest.sessionCount,
            "total_size_bytes": manifest.totalSizeBytes,
            "s3_prefix": "users/\(manifest.userId)/backups/\(manifest.backupId)",
            "manifest_json": manifestDict,
            "device_uuid": deviceUUID,
        ]

        let url = URL(string: "\(baseURL)/api/backup/manifests")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 200 {
                logger.info("Backup manifest synced to backend: \(manifest.backupId)")
            } else {
                logger.warning("Manifest sync returned status \(statusCode)")
            }
        } catch {
            logger.error("Failed to sync backup manifest: \(error)")
        }
    }
}

// MARK: - Errors

enum SyncError: Error, LocalizedError {
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .serverError(let message):
            return message
        }
    }
}
