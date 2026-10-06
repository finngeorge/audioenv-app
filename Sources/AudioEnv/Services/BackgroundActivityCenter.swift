import Foundation
import os.log

/// Central registry of background work (library sync, bounce linking, backups)
/// so the menu bar and the in-app Activity panel can show what is running,
/// how far along it is, and what triggered it — not just the console log.
@MainActor
final class BackgroundActivityCenter: ObservableObject {
    static let shared = BackgroundActivityCenter()

    enum Kind {
        case librarySync
        case bounceLinking
        case backup

        var symbolName: String {
            switch self {
            case .librarySync:   return "arrow.triangle.2.circlepath"
            case .bounceLinking: return "link"
            case .backup:        return "icloud.and.arrow.up"
            }
        }
    }

    enum Outcome {
        case succeeded
        case failed(String)
    }

    struct Job: Identifiable {
        let id: UUID
        let kind: Kind
        let title: String
        /// Why this job started, e.g. "After scan" or "Auto-backup: smart collection 'x'".
        let trigger: String
        /// Short live status line, e.g. "340 / 1,012 folders" or a file name.
        var detail: String?
        /// 0…1 when known; nil renders as indeterminate.
        var progress: Double?
        let startedAt: Date
        var finishedAt: Date?
        var outcome: Outcome?
    }

    @Published private(set) var running: [Job] = []
    @Published private(set) var recent: [Job] = []

    /// Automatic uploads at or above this size post a macOS notification.
    static let largeUploadNotifyBytes: Int64 = 500 * 1024 * 1024

    /// Set by the app layer to deliver user notifications (MenuBarManager.sendNotification).
    var notify: ((_ title: String, _ body: String) -> Void)?

    private let logger = Logger(subsystem: "com.audioenv.app", category: "BackgroundActivity")
    private static let recentLimit = 20

    var isBusy: Bool { !running.isEmpty }

    @discardableResult
    func start(_ kind: Kind, title: String, trigger: String, detail: String? = nil) -> UUID {
        let job = Job(id: UUID(), kind: kind, title: title, trigger: trigger,
                      detail: detail, progress: nil, startedAt: Date())
        running.append(job)
        logger.info("Started: \(title, privacy: .public) (\(trigger, privacy: .public))")
        return job.id
    }

    func update(_ id: UUID, progress: Double? = nil, detail: String? = nil) {
        guard let i = running.firstIndex(where: { $0.id == id }) else { return }
        if let progress { running[i].progress = min(max(progress, 0), 1) }
        if let detail { running[i].detail = detail }
    }

    func finish(_ id: UUID, _ outcome: Outcome = .succeeded, detail: String? = nil) {
        guard let i = running.firstIndex(where: { $0.id == id }) else { return }
        var job = running.remove(at: i)
        job.finishedAt = Date()
        job.outcome = outcome
        if let detail { job.detail = detail }
        recent.insert(job, at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
    }
}
