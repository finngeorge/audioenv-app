import AppKit
import AVFoundation
import Foundation
import os.log

/// Manages bounce folders, local file scanning, FSEvents watching, and API sync.
@MainActor
class BounceService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Bounces")

    // MARK: - Published State

    @Published var bounceFolders: [BounceFolder] = []
    @Published var bounces: [Bounce] = []
    @Published var suggestions: [BounceSuggestion] = []
    @Published var isLoading = false
    @Published var isScanning = false
    @Published var isDownloading = false
    @Published var lastError: String?
    @Published var lastScanCompletedAt: Date?

    // MARK: - Private State

    private var directoryWatchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var lastScanTime: [UUID: Date] = [:]
    private static let scanThrottleSeconds: TimeInterval = 30

    /// Supported audio file extensions for bounces.
    private static let audioExtensions: Set<String> = ["wav", "mp3", "aiff", "aif", "flac", "m4a"]

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    // MARK: - Folder Management

    /// Link a new bounce folder via API and start watching if auto_scan.
    func linkFolder(path: String, autoScan: Bool, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/bounces/folders")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let payload: [String: Any] = ["folder_path": path, "auto_scan": autoScan]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }

            if http.statusCode == 200 || http.statusCode == 201 {
                let decoder = FlexibleISO8601.makeAPIDecoder()
                let folder = try decoder.decode(BounceFolder.self, from: data)
                bounceFolders.insert(folder, at: 0)
                logger.info("Linked bounce folder: \(path)")

                // Scan immediately
                await scanFolder(folder, token: token)

                // Start watching if auto_scan
                if autoScan {
                    startWatching(folder: folder, token: token)
                }
            } else if http.statusCode == 409 {
                lastError = "Folder already linked"
            } else {
                lastError = "Failed to link folder (status \(http.statusCode))"
            }
        } catch {
            lastError = error.localizedDescription
            logger.error("linkFolder failed: \(error)")
        }
    }

    /// Unlink a bounce folder.
    func unlinkFolder(id: UUID, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/bounces/folders/\(id)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            stopWatching(folderId: id)
            bounceFolders.removeAll { $0.id == id }
            bounces.removeAll { $0.bounceFolderId == id }
            logger.info("Unlinked bounce folder \(id)")
        } catch {
            lastError = error.localizedDescription
            logger.error("unlinkFolder failed: \(error)")
        }
    }

    /// Fetch all linked folders from API.
    func fetchFolders(token: String) async {
        do {
            var components = URLComponents(string: "\(baseURL)/api/bounces/folders")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "10000")]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            bounceFolders = Self.decodeItems(data: data, decoder: decoder) ?? []
        } catch {
            logger.error("fetchFolders failed: \(error)")
        }
    }

    // MARK: - Bounce Listing

    /// Fetch bounces from API with optional filters.
    func fetchBounces(token: String, folderId: UUID? = nil, format: String? = nil, linked: Bool? = nil) async {
        isLoading = true
        defer { isLoading = false }

        do {
            var components = URLComponents(string: "\(baseURL)/api/bounces/")!
            var queryItems: [URLQueryItem] = [URLQueryItem(name: "per_page", value: "10000")]
            if let fid = folderId { queryItems.append(.init(name: "folder_id", value: fid.uuidString)) }
            if let fmt = format { queryItems.append(.init(name: "format", value: fmt)) }
            if let lnk = linked { queryItems.append(.init(name: "linked", value: lnk ? "true" : "false")) }
            components.queryItems = queryItems

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            bounces = Self.decodeItems(data: data, decoder: decoder) ?? []
        } catch {
            logger.error("fetchBounces failed: \(error)")
        }
    }

    // MARK: - Local Scanning

    /// Scan a single folder for audio files and sync results to API.
    func scanFolder(_ folder: BounceFolder, token: String) async {
        // Throttle
        if let lastScan = lastScanTime[folder.id],
           Date().timeIntervalSince(lastScan) < Self.scanThrottleSeconds {
            logger.info("Scan throttled for folder \(folder.displayName)")
            return
        }

        isScanning = true
        lastScanTime[folder.id] = Date()

        let scannedBounces = await scanLocalFiles(in: folder.folderPath)
        logger.info("Scanned \(scannedBounces.count) audio files in \(folder.displayName)")

        if !scannedBounces.isEmpty {
            await syncScanResults(folderId: folder.id, bounces: scannedBounces, token: token)
        }

        // Refresh bounce list
        await fetchBounces(token: token)

        lastScanCompletedAt = Date()
        isScanning = false
    }

    /// Scan all auto-scan folders. Called on app launch.
    func scanAllAutoFolders(token: String) async {
        let autoFolders = bounceFolders.filter(\.autoScan)
        for folder in autoFolders {
            await scanFolder(folder, token: token)
            startWatching(folder: folder, token: token)
        }
    }

    /// Scan a directory for WAV/MP3/AIFF/FLAC files and extract metadata via AVFoundation.
    private nonisolated func scanLocalFiles(in folderPath: String) async -> [LocalBounceInfo] {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: folderPath) else { return [] }

        var results: [LocalBounceInfo] = []

        for fileName in contents {
            let ext = (fileName as NSString).pathExtension.lowercased()
            guard Self.audioExtensions.contains(ext) else { continue }

            let filePath = (folderPath as NSString).appendingPathComponent(fileName)
            guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                  let fileSize = attrs[.size] as? Int,
                  let modDate = attrs[.modificationDate] as? Date else { continue }

            // Determine format
            let format: String
            switch ext {
            case "wav": format = "wav"
            case "mp3": format = "mp3"
            case "aiff", "aif": format = "aiff"
            case "flac": format = "flac"
            case "m4a": format = "m4a"
            default: format = ext
            }

            // Extract audio metadata
            let (duration, sampleRate, bitDepth, bitrate) = await Self.extractAudioMetadata(path: filePath)

            results.append(LocalBounceInfo(
                fileName: fileName,
                filePath: filePath,
                fileSizeBytes: fileSize,
                format: format,
                durationSeconds: duration,
                sampleRate: sampleRate,
                bitDepth: bitDepth,
                bitrate: bitrate,
                fileModifiedAt: modDate
            ))
        }

        return results
    }

    /// Extract duration, sample rate, bit depth, and bitrate from an audio file.
    private nonisolated static func extractAudioMetadata(path: String) async -> (duration: Double?, sampleRate: Int?, bitDepth: Int?, bitrate: Int?) {
        let url = URL(fileURLWithPath: path)
        let ext = (path as NSString).pathExtension.lowercased()

        // AVAudioFile works for WAV, AIFF, FLAC but not MP3/M4A — skip compressed formats to use AVURLAsset for bitrate
        if ext != "mp3" && ext != "m4a", let audioFile = try? AVAudioFile(forReading: url) {
            let format = audioFile.fileFormat
            let duration = Double(audioFile.length) / format.sampleRate
            let sampleRate = Int(format.sampleRate)
            let bitDepth = Int(format.streamDescription.pointee.mBitsPerChannel)
            return (duration, sampleRate, bitDepth > 0 ? bitDepth : nil, nil)
        }

        // AVURLAsset fallback (works for MP3 and others)
        let asset = AVURLAsset(url: url)
        let durationValue = try? await asset.load(.duration)
        let duration = durationValue.map { CMTimeGetSeconds($0) }
        let validDuration = duration != nil && duration!.isFinite && duration! > 0 ? duration : nil

        // Try to get format details from audio tracks
        if let track = try? await asset.loadTracks(withMediaType: .audio).first {
            let descriptions = try? await track.load(.formatDescriptions)
            let estimatedRate = try? await track.load(.estimatedDataRate)
            let bitrateKbps = estimatedRate.flatMap { $0 > 0 ? Int($0 / 1000) : nil }

            if let desc = descriptions?.first {
                let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee
                let sr = asbd.map { Int($0.mSampleRate) }
                let bd = asbd.map { Int($0.mBitsPerChannel) }
                return (validDuration, sr, bd != nil && bd! > 0 ? bd : nil, bitrateKbps)
            }
            return (validDuration, nil, nil, bitrateKbps)
        }

        return (validDuration, nil, nil, nil)
    }

    /// Sync local scan results to the API.
    private func syncScanResults(folderId: UUID, bounces: [LocalBounceInfo], token: String) async {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let bounceDicts = bounces.map { b -> [String: Any?] in
            [
                "bounce_folder_id": folderId.uuidString,
                "file_name": b.fileName,
                "file_path": b.filePath,
                "file_size_bytes": b.fileSizeBytes,
                "format": b.format,
                "duration_seconds": b.durationSeconds,
                "sample_rate": b.sampleRate,
                "bit_depth": b.bitDepth,
                "bitrate": b.bitrate,
                "file_modified_at": dateFormatter.string(from: b.fileModifiedAt),
            ]
        }

        let payload: [String: Any] = [
            "bounce_folder_id": folderId.uuidString,
            "bounces": bounceDicts,
        ]

        do {
            let url = URL(string: "\(baseURL)/api/bounces/scan")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                logger.info("Synced \(bounces.count) bounces for folder \(folderId)")
            } else {
                logger.warning("Bounce scan sync returned \(status)")
            }
        } catch {
            logger.error("syncScanResults failed: \(error)")
        }
    }

    // MARK: - Suggestions

    /// Fetch auto-suggested bounce-project links.
    func fetchSuggestions(token: String) async {
        do {
            var components = URLComponents(string: "\(baseURL)/api/bounces/suggestions")!
            components.queryItems = [URLQueryItem(name: "per_page", value: "10000")]

            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return }

            suggestions = Self.decodeItems(data: data, decoder: FlexibleISO8601.makeAPIDecoder()) ?? []
        } catch {
            logger.error("fetchSuggestions failed: \(error)")
        }
    }

    /// Confirm a suggestion.
    func confirmSuggestion(bounceId: String, sessionId: String, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/bounces/suggestions/confirm")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let payload: [String: Any] = [
                "bounce_id": bounceId,
                "scanned_session_id": sessionId,
                "link_type": "auto_confirmed",
            ]
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)

            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                suggestions.removeAll { $0.bounceId == bounceId && $0.scannedSessionId == sessionId }
                logger.info("Confirmed suggestion: bounce \(bounceId) -> session \(sessionId)")
            }
        } catch {
            logger.error("confirmSuggestion failed: \(error)")
        }
    }

    // MARK: - Manual Linking

    func linkBounceToProject(bounceId: UUID, sessionId: UUID, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/bounces/\(bounceId)/link/\(sessionId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                logger.info("Linked bounce \(bounceId) to session \(sessionId)")
            }
        } catch {
            logger.error("linkBounceToProject failed: \(error)")
        }
    }

    func unlinkBounceFromProject(bounceId: UUID, sessionId: UUID, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/bounces/\(bounceId)/link/\(sessionId)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 {
                logger.info("Unlinked bounce \(bounceId) from session \(sessionId)")
            }
        } catch {
            logger.error("unlinkBounceFromProject failed: \(error)")
        }
    }

    // MARK: - FSEvents Watching

    /// Start watching a folder for new audio files.
    func startWatching(folder: BounceFolder, token: String) {
        guard directoryWatchers[folder.id] == nil else { return }

        let fd = open(folder.folderPath, O_EVTONLY)
        guard fd >= 0 else {
            logger.warning("Could not open folder for watching: \(folder.folderPath)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .global(qos: .utility)
        )

        let folderId = folder.id
        let capturedToken = token
        source.setEventHandler { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard let folder = self.bounceFolders.first(where: { $0.id == folderId }) else { return }
                await self.scanFolder(folder, token: capturedToken)
            }
        }

        source.setCancelHandler {
            close(fd)
        }

        source.resume()
        directoryWatchers[folder.id] = source
        logger.info("Watching bounce folder: \(folder.displayName)")
    }

    /// Stop watching a specific folder.
    func stopWatching(folderId: UUID) {
        if let source = directoryWatchers.removeValue(forKey: folderId) {
            source.cancel()
        }
    }

    /// Stop all watchers.
    func stopAllWatchers() {
        for (_, source) in directoryWatchers {
            source.cancel()
        }
        directoryWatchers.removeAll()
    }

    // MARK: - Cloud Bounce Download

    /// Download a cloud-only bounce to the user's Downloads folder via presigned S3 URL.
    func downloadBounce(_ bounce: Bounce, token: String) async {
        guard !isDownloading else { return }
        isDownloading = true
        lastError = nil

        do {
            // Request a presigned download URL from the API
            let url = URL(string: "\(baseURL)/api/bounces/\(bounce.id)/download-url")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw BounceDownloadError.serverError("Download URL request returned \(status)")
            }

            struct DownloadURLResponse: Decodable {
                let url: String
                let expires_in: Int
            }

            let downloadInfo = try FlexibleISO8601.makeAPIDecoder().decode(DownloadURLResponse.self, from: data)
            guard let downloadURL = URL(string: downloadInfo.url) else {
                throw BounceDownloadError.serverError("Invalid download URL")
            }

            // Download the file
            let (fileData, fileResponse) = try await URLSession.shared.data(from: downloadURL)
            guard let fileHttp = fileResponse as? HTTPURLResponse, fileHttp.statusCode == 200 else {
                throw BounceDownloadError.serverError("File download failed")
            }

            // Save to Downloads folder
            let downloadsURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            let destinationURL = downloadsURL.appendingPathComponent(bounce.fileName)

            // Avoid overwriting — append number if file exists
            var finalURL = destinationURL
            var counter = 1
            while FileManager.default.fileExists(atPath: finalURL.path) {
                let name = (bounce.fileName as NSString).deletingPathExtension
                let ext = (bounce.fileName as NSString).pathExtension
                finalURL = downloadsURL.appendingPathComponent("\(name) (\(counter)).\(ext)")
                counter += 1
            }

            try fileData.write(to: finalURL)
            logger.info("Downloaded bounce to: \(finalURL.path)")

            // Reveal in Finder
            NSWorkspace.shared.activateFileViewerSelecting([finalURL])
        } catch {
            lastError = error.localizedDescription
            logger.error("downloadBounce failed: \(error)")
        }

        isDownloading = false
    }

    // MARK: - Pagination Helper

    /// Decode a list response that may be either a bare array (old API) or
    /// a paginated wrapper `{ "items": [...], ... }` (new API).
    private static func decodeItems<T: Decodable>(data: Data, decoder: JSONDecoder) -> [T]? {
        if let paginated = try? decoder.decode(PaginatedResponse<T>.self, from: data) {
            return paginated.items
        }
        return try? decoder.decode([T].self, from: data)
    }

    // MARK: - Name Matching (Local Pre-filter)

    /// Check if a bounce filename likely matches a project name.
    /// Used for local pre-filtering before sending to API for confirmation.
    nonisolated static func bounceMatchesProject(bounceFileName: String, projectName: String) -> Bool {
        // Strip file extension from bounce
        let bounceName = (bounceFileName as NSString).deletingPathExtension.lowercased()

        // Strip " Project" suffix from Ableton project names
        var normalizedProject = projectName
        if normalizedProject.hasSuffix(" Project") {
            normalizedProject = String(normalizedProject.dropLast(" Project".count))
        }
        let projectLower = normalizedProject.lowercased()

        guard !projectLower.isEmpty else { return false }

        // Strip common bounce suffixes
        let suffixes = ["_bounce", "_mix", "_master", "_v1", "_v2", "_v3", "_v4", "_v5",
                        "_final", "_rough", "_demo", "_stem", "_export"]
        var strippedBounce = bounceName
        for suffix in suffixes {
            if strippedBounce.hasSuffix(suffix) {
                strippedBounce = String(strippedBounce.dropLast(suffix.count))
            }
        }

        // Also strip trailing numbers with underscore (e.g. _01, _02)
        if let range = strippedBounce.range(of: "_\\d+$", options: .regularExpression) {
            strippedBounce = String(strippedBounce[..<range.lowerBound])
        }

        // Case-insensitive contains check
        return strippedBounce.contains(projectLower) || projectLower.contains(strippedBounce)
    }
}

// MARK: - Errors

enum BounceDownloadError: Error, LocalizedError {
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .serverError(let message): return message
        }
    }
}
