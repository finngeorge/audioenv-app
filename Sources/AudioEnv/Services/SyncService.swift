import Foundation
import os.log

/// Syncs local scan data (plugins + sessions) to the AudioEnv backend.
@MainActor
class SyncService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Sync")

    @Published var isSyncing = false
    @Published var lastSyncDate: Date?
    @Published var lastSyncError: String?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

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

    /// Reference to auth service for token refresh on 401.
    weak var authService: AuthenticationService?

    /// Sync plugins and sessions to the backend.
    func syncToCloud(plugins: [AudioPlugin], sessions: [AudioSession], token: String) async {
        guard !isSyncing else { return }

        isSyncing = true
        lastSyncError = nil
        logger.info("Starting cloud sync: \(plugins.count) plugins, \(sessions.count) sessions")

        do {
            var currentToken = token

            // 1. Register device
            try await registerDevice(token: currentToken)

            // 2. Sync plugins (with 401 retry)
            do {
                try await syncPlugins(plugins, token: currentToken)
            } catch SyncError.unauthorized {
                if let refreshedToken = await refreshAndRetry() {
                    currentToken = refreshedToken
                    try await syncPlugins(plugins, token: currentToken)
                } else {
                    throw SyncError.serverError("Plugin sync failed: authentication expired")
                }
            }

            // 3. Sync sessions (with 401 retry)
            do {
                try await syncSessions(sessions, token: currentToken)
            } catch SyncError.unauthorized {
                if let refreshedToken = await refreshAndRetry() {
                    currentToken = refreshedToken
                    try await syncSessions(sessions, token: currentToken)
                } else {
                    throw SyncError.serverError("Session sync failed: authentication expired")
                }
            }

            lastSyncDate = Date()
            logger.info("Cloud sync completed successfully")
        } catch {
            lastSyncError = error.localizedDescription
            logger.error("Cloud sync failed: \(error)")
        }

        isSyncing = false
    }

    /// Attempt to refresh the auth token via AuthenticationService.
    private func refreshAndRetry() async -> String? {
        guard let auth = authService else { return nil }
        let refreshed = await auth.handleUnauthorized()
        return refreshed ? auth.authToken : nil
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
            var dict: [String: Any?] = [
                "plugin_name": plugin.name,
                "plugin_format": plugin.format.rawValue,
                "bundle_id": plugin.bundleID,
                "version": plugin.version,
                "manufacturer": ManufacturerResolver.displayManufacturer(plugin: plugin, catalogManufacturer: nil),
                "installation_path": plugin.path,
            ]

            // Add file size if available on disk
            let fileURL = URL(fileURLWithPath: plugin.path)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let size = attrs[.size] as? Int64 {
                dict["file_size_bytes"] = size
            }

            return dict
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
            if statusCode == 401 {
                throw SyncError.unauthorized
            }
            throw SyncError.serverError("Plugin sync failed with status \(statusCode)")
        }

        logger.info("Synced \(plugins.count) plugins")
    }

    // MARK: - Session sync fingerprints

    /// Fingerprint for change detection: path → "modifiedDate:fileSize"
    private struct SessionFingerprint: Codable {
        let modifiedDate: TimeInterval  // secondsSince1970
        let fileSize: UInt64
    }

    private static let fingerprintURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("AudioEnv", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session-sync-fingerprints.json")
    }()

    private func loadFingerprints() -> [String: SessionFingerprint] {
        guard let data = try? Data(contentsOf: Self.fingerprintURL),
              let fingerprints = try? JSONDecoder().decode([String: SessionFingerprint].self, from: data) else {
            return [:]
        }
        return fingerprints
    }

    private func saveFingerprints(_ fingerprints: [String: SessionFingerprint]) {
        if let data = try? JSONEncoder().encode(fingerprints) {
            try? data.write(to: Self.fingerprintURL, options: .atomic)
        }
    }

    // MARK: - Session sync

    private func syncSessions(_ sessions: [AudioSession], token: String) async throws {
        let previousFingerprints = loadFingerprints()
        let currentFingerprints = Dictionary(uniqueKeysWithValues: sessions.map { session in
            (session.path, SessionFingerprint(
                modifiedDate: session.modifiedDate.timeIntervalSince1970,
                fileSize: session.fileSize
            ))
        })

        // Compute diff
        let currentPaths = Set(currentFingerprints.keys)
        let previousPaths = Set(previousFingerprints.keys)

        let addedPaths = currentPaths.subtracting(previousPaths)
        let removedPaths = previousPaths.subtracting(currentPaths)
        let commonPaths = currentPaths.intersection(previousPaths)
        let modifiedPaths = commonPaths.filter { path in
            let curr = currentFingerprints[path]!
            let prev = previousFingerprints[path]!
            return curr.fileSize != prev.fileSize
                || abs(curr.modifiedDate - prev.modifiedDate) > 1.0
        }

        let changedPaths = addedPaths.union(modifiedPaths)

        // No changes — skip sync entirely
        if changedPaths.isEmpty && removedPaths.isEmpty {
            logger.info("Sessions unchanged, skipping sync")
            return
        }

        // First sync (no previous fingerprints) → full replace via batched sync
        if previousFingerprints.isEmpty {
            logger.info("First session sync, sending all \(sessions.count) sessions")
            try await syncSessionsFull(sessions, token: token)
            saveFingerprints(currentFingerprints)
            return
        }

        // Delta sync
        let changedSessions = sessions.filter { changedPaths.contains($0.path) }
        logger.info("Delta sync: \(changedSessions.count) upserted, \(removedPaths.count) removed (of \(sessions.count) total)")

        let upsertedPayloads = changedSessions.map { buildSessionPayload($0) }
        let removedKeys = removedPaths.compactMap { path -> [String: Any]? in
            // Reconstruct the natural key from the path
            guard let prev = previousFingerprints[path] else { return nil }
            let sessionName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            var folderPath = (path as NSString).deletingLastPathComponent
            if folderPath.lowercased().hasSuffix("/backups") || folderPath.lowercased().hasSuffix("/backup") {
                folderPath = (folderPath as NSString).deletingLastPathComponent
            }
            // Infer format from extension
            let ext = (path as NSString).pathExtension.lowercased()
            let format: String
            switch ext {
            case "als": format = "Ableton Live"
            case "logicx": format = "Logic Pro"
            case "ptx", "ptf": format = "Pro Tools"
            default: format = "Ableton Live"
            }
            _ = prev // suppress unused warning
            return [
                "session_name": sessionName,
                "session_format": format,
                "folder_path": folderPath,
            ]
        }

        let payload: [String: Any] = [
            "device_uuid": deviceUUID,
            "device_name": deviceName,
            "upserted": upsertedPayloads,
            "removed": removedKeys,
        ]

        let url = URL(string: "\(baseURL)/api/sessions/sync/delta")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 401 {
                throw SyncError.unauthorized
            }
            throw SyncError.serverError("Session delta sync failed with status \(statusCode)")
        }

        saveFingerprints(currentFingerprints)
        logger.info("Delta sync complete: \(changedSessions.count) upserted, \(removedPaths.count) removed")
    }

    /// Full replace sync (batched) for first sync or recovery.
    private func syncSessionsFull(_ sessions: [AudioSession], token: String) async throws {
        let sessionPayloads = sessions.map { buildSessionPayload($0) }

        let batchSize = 500
        let batches = stride(from: 0, to: sessionPayloads.count, by: batchSize).map {
            Array(sessionPayloads[$0..<min($0 + batchSize, sessionPayloads.count)])
        }

        for (index, batch) in batches.enumerated() {
            var wrapper: [String: Any] = [
                "device_uuid": deviceUUID,
                "device_name": deviceName,
                "sessions": batch,
            ]
            if index > 0 {
                wrapper["replace"] = false
            }

            let url = URL(string: "\(baseURL)/api/sessions/sync")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: wrapper)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                if statusCode == 401 {
                    throw SyncError.unauthorized
                }
                throw SyncError.serverError("Session sync batch \(index + 1) failed with status \(statusCode)")
            }

            logger.info("Synced session batch \(index + 1)/\(batches.count) (\(batch.count) sessions)")
        }
    }

    // MARK: - Session payload builder

    private func buildSessionPayload(_ session: AudioSession) -> [String: Any] {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var folderPath = (session.path as NSString).deletingLastPathComponent
        if folderPath.lowercased().hasSuffix("/backups") || folderPath.lowercased().hasSuffix("/backup") {
            folderPath = (folderPath as NSString).deletingLastPathComponent
        }

        var dict: [String: Any] = [
            "session_name": session.name,
            "session_format": session.format.rawValue,
            "file_size_bytes": session.fileSize,
            "modified_date": dateFormatter.string(from: session.modifiedDate),
            "is_backup": session.isBackup,
            "project_name": session.projectDisplayName,
            "folder_path": folderPath,
        ]

        if let project = session.project {
            switch project {
            case .ableton(let ableton):
                dict["track_count"] = ableton.tracks.count
                dict["plugin_count"] = ableton.usedPlugins.count
                dict["sample_count"] = ableton.samplePaths.count
                dict["tempo"] = ableton.tempo
                let hasPluginInfos = ableton.tracks.contains { $0.pluginInfos != nil && !($0.pluginInfos!.isEmpty) }
                if hasPluginInfos {
                    let allInfos = ableton.tracks.flatMap { $0.pluginInfos ?? [] }
                    let uniqueInfos = Array(Set(allInfos))
                    dict["used_plugins"] = uniqueInfos.map { info -> [String: Any] in
                        var obj: [String: Any] = ["name": info.name, "format": info.format]
                        if let preset = info.presetName { obj["preset_name"] = preset }
                        if let mfr = info.manufacturer { obj["manufacturer"] = mfr }
                        if info.isInstalled { obj["is_installed"] = true }
                        return obj
                    }
                } else {
                    dict["used_plugins"] = ableton.usedPlugins
                }
                if let key = ableton.keyRoot { dict["key_signature"] = key }
                if let scale = ableton.keyScale { dict["key_scale"] = scale }
                if let timeSig = ableton.timeSignature { dict["time_signature"] = timeSig }
                dict["tracks"] = ableton.tracks.enumerated().map { (index, track) -> [String: Any] in
                    var t: [String: Any] = [
                        "track_index": index,
                        "track_name": track.name,
                        "track_type": track.type.rawValue,
                        "is_muted": track.isMuted,
                        "is_solo": track.isSolo,
                    ]
                    if let infos = track.pluginInfos, !infos.isEmpty {
                        t["plugins"] = infos.map { info -> [String: Any] in
                            var obj: [String: Any] = ["name": info.name, "format": info.format]
                            if let preset = info.presetName { obj["preset_name"] = preset }
                            if let mfr = info.manufacturer { obj["manufacturer"] = mfr }
                            if info.isInstalled { obj["is_installed"] = true }
                            return obj
                        }
                    } else {
                        t["plugins"] = track.plugins
                    }
                    if let color = track.color { t["color"] = String(color) }
                    return t
                }
            case .logic(let logic):
                dict["sample_count"] = logic.mediaFiles.count
                if let tempo = logic.tempo { dict["tempo"] = tempo }
                if let trackCount = logic.trackCount { dict["track_count"] = trackCount }
                if let key = logic.songKey { dict["key_signature"] = key }
                if let scale = logic.songScale { dict["key_scale"] = scale }
                if let num = logic.timeSignatureNumerator,
                   let den = logic.timeSignatureDenominator {
                    dict["time_signature"] = "\(num)/\(den)"
                }
                if !logic.pluginHints.isEmpty {
                    dict["used_plugins"] = logic.pluginHints
                    dict["plugin_count"] = logic.pluginHints.count
                }
                if !logic.trackNames.isEmpty {
                    dict["tracks"] = logic.trackNames.sorted(by: { $0.key < $1.key }).enumerated().map { (index, entry) -> [String: Any] in
                        var t: [String: Any] = [
                            "track_index": index,
                            "track_name": entry.value,
                        ]
                        if let plugins = logic.trackPlugins[entry.key], !plugins.isEmpty {
                            t["plugins"] = plugins
                        }
                        return t
                    }
                }
            case .proTools(let proTools):
                dict["sample_count"] = proTools.audioFiles.count
                dict["track_count"] = proTools.trackCount
                if !proTools.pluginCatalog.isEmpty {
                    dict["used_plugins"] = proTools.pluginCatalog.map { insert -> [String: Any] in
                        var obj: [String: Any] = ["name": insert.name, "format": "AAX"]
                        if !insert.presetName.isEmpty { obj["preset_name"] = insert.presetName }
                        if !insert.manufacturer.isEmpty { obj["manufacturer"] = insert.manufacturer }
                        if insert.isInstalled { obj["is_installed"] = true }
                        return obj
                    }
                    dict["plugin_count"] = proTools.pluginCatalog.count
                }
                dict["tracks"] = proTools.tracks.map { track -> [String: Any] in
                    [
                        "track_index": track.index,
                        "track_name": track.name,
                        "track_type": track.trackType,
                        "is_stereo": track.isStereo,
                        "plugins": track.plugins.map { insert -> [String: Any] in
                            var obj: [String: Any] = ["name": insert.name, "format": "AAX"]
                            if !insert.presetName.isEmpty { obj["preset_name"] = insert.presetName }
                            if !insert.manufacturer.isEmpty { obj["manufacturer"] = insert.manufacturer }
                            if insert.isInstalled { obj["is_installed"] = true }
                            return obj
                        },
                    ]
                }
            }
        }

        return dict
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

    /// Pull S3 backup config from the backend and save to Keychain.
    /// Returns true if config was restored successfully.
    func fetchS3Config(token: String, userId: String) async -> Bool {
        let url = URL(string: "\(baseURL)/api/backup/config/full")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard statusCode == 200 else {
                logger.warning("Fetch S3 config returned status \(statusCode)")
                return false
            }

            struct ConfigResponse: Decodable {
                let configured: Bool
                let bucket_name: String?
                let region: String?
                let access_key: String?
                let secret_key: String?
            }

            let config = try JSONDecoder().decode(ConfigResponse.self, from: data)
            guard config.configured,
                  let bucket = config.bucket_name,
                  let region = config.region,
                  let accessKey = config.access_key,
                  let secretKey = config.secret_key else {
                return false
            }

            KeychainHelper.shared.saveS3Config(
                bucket: bucket,
                accessKeyId: accessKey,
                secretKey: secretKey,
                region: region,
                forUser: userId
            )
            logger.info("S3 config restored from backend")
            return true
        } catch {
            logger.error("Failed to fetch S3 config: \(error)")
            return false
        }
    }

    // MARK: - Session Activity Sync

    /// Sync a live session's activity data to the backend.
    func syncSessionActivity(session: LiveSession, token: String) async {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var payload: [String: Any] = [
            "project_name": session.projectName,
            "project_path": session.projectPath,
            "session_format": session.format.rawValue,
            "opened_at": dateFormatter.string(from: session.openedAt),
            "duration_seconds": Int(session.duration),
            "save_count": session.saveCount,
            "initial_size_bytes": session.initialFileSize,
            "final_size_bytes": session.currentFileSize,
            "new_audio_files": session.newAudioFiles.count,
            "new_bounces": session.newBounces.count,
            "device_uuid": deviceUUID,
        ]

        if let closedAt = session.closedAt {
            payload["closed_at"] = dateFormatter.string(from: closedAt)
        }

        if !session.snapshots.isEmpty {
            payload["snapshots"] = session.snapshots.map { snapshot -> [String: Any] in
                var dict: [String: Any] = [
                    "timestamp": dateFormatter.string(from: snapshot.timestamp),
                    "file_size": snapshot.fileSize,
                ]
                if let pluginCount = snapshot.pluginCount { dict["plugin_count"] = pluginCount }
                if let trackCount = snapshot.trackCount { dict["track_count"] = trackCount }
                if let tempo = snapshot.tempo { dict["tempo"] = tempo }
                if let key = snapshot.keySignature { dict["key_signature"] = key }
                if let ts = snapshot.timeSignature { dict["time_signature"] = ts }
                return dict
            }
        }

        let url = URL(string: "\(baseURL)/api/sessions/activity")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            if statusCode == 200 || statusCode == 201 {
                logger.info("Session activity synced: \(session.projectName)")
            } else {
                logger.warning("Session activity sync returned status \(statusCode)")
            }
        } catch {
            logger.error("Failed to sync session activity: \(error)")
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
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .serverError(let message):
            return message
        case .unauthorized:
            return "Authentication expired"
        }
    }
}
