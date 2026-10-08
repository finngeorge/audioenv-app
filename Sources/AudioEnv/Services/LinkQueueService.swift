import Foundation
import os

/// Backs the "Link Bounces" review queue: predictions of which project each
/// bounce belongs to, reviewed one card at a time. Nothing is linked unless the
/// user confirms it. Decisions apply locally first (so keys feel instant) and
/// are rolled back if the API call fails.
@MainActor
final class LinkQueueService: ObservableObject {
    private let logger = Logger(subsystem: "com.audioenv.app", category: "LinkQueue")

    @Published private(set) var groups: [LinkQueueGroup] = []
    @Published private(set) var recent: [RecentLink] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Index into `groups` of the group being reviewed.
    @Published var groupIndex = 0
    /// Index into the current item's predictions (0 = best).
    @Published var predictionIndex = 0

    var remainingCount: Int { groups.reduce(0) { $0 + $1.items.count } }
    var currentGroup: LinkQueueGroup? { groups.indices.contains(groupIndex) ? groups[groupIndex] : nil }
    var currentItem: LinkQueueItem? { currentGroup?.items.first }
    var canUndo: Bool { !undoStack.isEmpty }

    private enum Action { case confirm, reject }

    /// One undoable step: a single card, or a whole group confirmed at once.
    private struct UndoEntry {
        let id = UUID()
        let group: LinkQueueGroup          // the group as it was before (for restoring order)
        let groupPosition: Int
        let decisions: [(item: LinkQueueItem, sessionId: UUID, action: Action)]
    }

    private var undoStack: [UndoEntry] = []
    private weak var authService: AuthenticationService?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    func configure(auth: AuthenticationService) {
        authService = auth
    }

    // MARK: - Loading

    /// Fetch the whole queue (paged by group).
    func refresh() async {
        guard let token = await token() else { return }
        isLoading = true
        defer { isLoading = false }
        var all: [LinkQueueGroup] = []
        var offset = 0
        do {
            while true {
                let page: LinkQueueResponse = try await get("/api/bounces/link-queue?limit=500&offset=\(offset)", token: token)
                all += page.groups
                offset += page.groups.count
                if page.groups.isEmpty || offset >= page.totalGroups { break }
            }
            replaceGroups(all)
            errorMessage = nil
        } catch {
            logger.error("Failed to load link queue: \(error.localizedDescription)")
            errorMessage = "Couldn't load suggestions"
        }
    }

    func loadRecent() async {
        guard let token = await token() else { return }
        do {
            recent = try await get("/api/bounces/link-queue/recent?days=30", token: token)
        } catch {
            logger.error("Failed to load recent links: \(error.localizedDescription)")
        }
    }

    /// Swap in a fresh queue, staying on the same song if it's still there.
    func replaceGroups(_ newGroups: [LinkQueueGroup]) {
        let previousSong = currentGroup?.songKey
        groups = newGroups
        groupIndex = previousSong.flatMap { song in newGroups.firstIndex { $0.songKey == song } } ?? 0
        predictionIndex = 0
    }

    // MARK: - Navigation

    func selectGroup(_ index: Int) {
        guard groups.indices.contains(index) else { return }
        groupIndex = index
        predictionIndex = 0
    }

    func movePrediction(by delta: Int) {
        guard let item = currentItem else { return }
        predictionIndex = min(max(predictionIndex + delta, 0), item.predictions.count - 1)
    }

    /// Move the current card to the back of its group; nothing is recorded.
    func skip() {
        guard groups.indices.contains(groupIndex), groups[groupIndex].items.count > 0 else { return }
        if groups[groupIndex].items.count == 1 {
            let group = groups.remove(at: groupIndex)
            groups.append(group)
            groupIndex = min(groupIndex, groups.count - 1)
        } else {
            let item = groups[groupIndex].items.removeFirst()
            groups[groupIndex].items.append(item)
        }
        predictionIndex = 0
    }

    // MARK: - Decisions

    // Decisions change local state synchronously (so the view can animate the
    // card away in the same transaction) and save to the API in the background.

    /// → : link the bounce to the highlighted project.
    func confirmCurrent() {
        guard let item = currentItem, item.predictions.indices.contains(predictionIndex) else { return }
        apply([(item, item.predictions[predictionIndex].scannedSessionId, .confirm)])
    }

    /// ← : none of these. Rejects every prediction shown for the bounce.
    func rejectCurrent() {
        guard let item = currentItem else { return }
        apply(item.predictions.map { (item, $0.scannedSessionId, .reject) })
    }

    /// ⇧→ : link every remaining bounce in this group to its top prediction.
    func confirmGroup() {
        guard let group = currentGroup else { return }
        apply(group.items.compactMap { item in
            item.predictions.first.map { (item, $0.scannedSessionId, .confirm) }
        })
    }

    private func apply(_ decisions: [(item: LinkQueueItem, sessionId: UUID, action: Action)]) {
        guard !decisions.isEmpty, groups.indices.contains(groupIndex) else { return }
        let entry = UndoEntry(group: groups[groupIndex], groupPosition: groupIndex, decisions: decisions)
        removeLocally(itemIds: Set(decisions.map(\.item.id)))
        undoStack.append(entry)
        Task { await send(entry) }
    }

    private func send(_ entry: UndoEntry) async {
        let decisions = entry.decisions
        let body = decisions.map { d in
            ["bounce_id": d.item.id.uuidString, "scanned_session_id": d.sessionId.uuidString,
             "action": d.action == .confirm ? "confirm" : "reject"]
        }
        do {
            guard let token = await token() else { throw URLError(.userAuthenticationRequired) }
            try await post("/api/bounces/link-queue/decide", body: ["decisions": body], token: token)
        } catch {
            logger.error("Decision failed: \(error.localizedDescription)")
            errorMessage = "Couldn't save that — restored the card"
            restore(entry)
            undoStack.removeAll { $0.id == entry.id }
        }
    }

    /// ⌘Z : reverse the last decision (or whole-group confirm).
    func undo() {
        guard let entry = undoStack.popLast() else { return }
        restore(entry)
        Task { await sendUndo(entry) }
    }

    private func sendUndo(_ entry: UndoEntry) async {
        guard let token = await token() else { return }
        for d in entry.decisions {
            let body = ["bounce_id": d.item.id.uuidString, "scanned_session_id": d.sessionId.uuidString,
                        "action": d.action == .confirm ? "confirm" : "reject"]
            do {
                try await post("/api/bounces/link-queue/undo", body: body, token: token)
            } catch {
                logger.error("Undo failed for \(d.item.bounce.fileName): \(error.localizedDescription)")
                errorMessage = "Couldn't undo on the server; refresh to see the current state"
            }
        }
    }

    /// Undo a link from the "Recently linked" list.
    func unlink(_ link: RecentLink) async {
        guard let token = await token() else { return }
        let body = ["bounce_id": link.bounceId.uuidString, "scanned_session_id": link.scannedSessionId.uuidString,
                    "action": "confirm"]
        do {
            try await post("/api/bounces/link-queue/undo", body: body, token: token)
            recent.removeAll { $0.id == link.id }
        } catch {
            errorMessage = "Couldn't undo that link"
        }
    }

    // MARK: - Local state

    private func removeLocally(itemIds: Set<UUID>) {
        groups[groupIndex].items.removeAll { itemIds.contains($0.id) }
        if groups[groupIndex].items.isEmpty {
            groups.remove(at: groupIndex)
            groupIndex = groups.isEmpty ? 0 : min(groupIndex, groups.count - 1)
        }
        predictionIndex = 0
    }

    /// Put the decided items back at the front of their group and show them.
    private func restore(_ entry: UndoEntry) {
        let restoredIds = Set(entry.decisions.map(\.item.id))
        let restoredItems = entry.group.items.filter { restoredIds.contains($0.id) }
        if let i = groups.firstIndex(where: { $0.songKey == entry.group.songKey }) {
            groups[i].items.removeAll { restoredIds.contains($0.id) }
            groups[i].items.insert(contentsOf: restoredItems, at: 0)
            groupIndex = i
        } else {
            var group = entry.group
            group.items = restoredItems
            let position = min(entry.groupPosition, groups.count)
            groups.insert(group, at: position)
            groupIndex = position
        }
        predictionIndex = 0
    }

    // MARK: - HTTP

    private func token() async -> String? {
        try? await authService?.validToken()
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try FlexibleISO8601.makeAPIDecoder().decode(T.self, from: data)
    }

    private func post(_ path: String, body: [String: Any], token: String) async throws {
        guard let url = URL(string: baseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
    }
}
