import Foundation
import os

/// A project uploaded via the web app that is waiting to be downloaded to this Mac.
struct PendingWebUpload: Identifiable, Decodable {
    let id: String
    let filename: String
    let s3Key: String
    let sizeBytes: Int64?
    let uploadType: String
    let status: String
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, filename, status
        case s3Key = "s3_key"
        case sizeBytes = "size_bytes"
        case uploadType = "upload_type"
        case createdAt = "created_at"
    }
}

/// Surfaces web-uploaded projects that haven't been pulled down to this Mac yet,
/// and downloads them on demand. Backs the "Web Uploads" sidebar section so the
/// user doesn't have to push each upload from the web with "Send to Mac".
@MainActor
class WebUploadsViewModel: ObservableObject {
    private let logger = Logger(subsystem: "com.audioenv.app", category: "WebUploads")

    @Published var pending: [PendingWebUpload] = []
    @Published var isLoading = false
    @Published var downloadingIds: Set<String> = []
    @Published var errorMessage: String?

    private weak var authService: AuthenticationService?
    private weak var remoteCommandService: RemoteCommandService?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    var pendingCount: Int { pending.count }

    func configure(auth: AuthenticationService, remoteCommand: RemoteCommandService) {
        self.authService = auth
        self.remoteCommandService = remoteCommand
    }

    /// Fetch projects that have been uploaded on the web but not yet downloaded here.
    func refresh() async {
        guard let auth = authService, let token = try? await auth.validToken() else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        guard let url = URL(string: "\(baseURL)/api/upload/pending?upload_type=project") else { return }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                errorMessage = "Couldn't load uploads"
                return
            }
            let items = try JSONDecoder().decode([PendingWebUpload].self, from: data)
            // Only items still awaiting download on this Mac (not yet "synced").
            pending = items.filter { $0.status == "uploaded" }
        } catch {
            logger.error("Failed to fetch pending uploads: \(error.localizedDescription)")
            errorMessage = "Couldn't load uploads"
        }
    }

    /// Download a single upload to this Mac, then refresh the list.
    func download(_ item: PendingWebUpload) async {
        guard let rcs = remoteCommandService else { return }
        downloadingIds.insert(item.id)
        defer { downloadingIds.remove(item.id) }
        do {
            _ = try await rcs.downloadUploadedProject(
                fileId: item.id,
                s3Key: item.s3Key,
                filename: item.filename
            )
            await refresh()
        } catch {
            logger.error("Download failed for \(item.filename): \(error.localizedDescription)")
            errorMessage = "Download failed: \(item.filename)"
        }
    }
}
