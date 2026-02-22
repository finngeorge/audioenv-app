import Foundation
import UserNotifications
import os.log

/// Real-time sync via WebSocket — receives events from other devices and triggers local updates.
@MainActor
class WebSocketService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "WebSocket")

    @Published var isConnected = false
    @Published var lastEvent: SyncEvent?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "wsBaseURL"), !override.isEmpty {
            return override
        }
        return "wss://api.audioenv.com"
    }()

    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectAttempt = 0
    private var maxReconnectAttempts = 5
    private var maxReconnectDelay: TimeInterval = 30
    private var reconnectTask: Task<Void, Never>?
    private var isIntentionalDisconnect = false

    private weak var scanner: ScannerService?
    private weak var sync: SyncService?
    private weak var auth: AuthenticationService?
    private weak var menuBar: MenuBarManager?

    /// Unique device ID to filter out own events.
    private let deviceUUID: String = {
        let key = "com.audioenv.deviceUUID"
        return UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
    }()

    // MARK: - Models

    struct SyncEvent: Codable {
        let type: String
        let deviceId: String?
        let deviceName: String?
        let timestamp: String?
        let summary: String?

        enum CodingKeys: String, CodingKey {
            case type
            case deviceId = "device_id"
            case deviceName = "device_name"
            case timestamp, summary
        }
    }

    // MARK: - Setup

    func configure(scanner: ScannerService, sync: SyncService, auth: AuthenticationService, menuBar: MenuBarManager) {
        self.scanner = scanner
        self.sync = sync
        self.auth = auth
        self.menuBar = menuBar
    }

    // MARK: - Connection Management

    func connect(token: String) {
        guard !isConnected, webSocketTask == nil else { return }
        isIntentionalDisconnect = false

        let urlString = "\(baseURL)/api/ws/sync?token=\(token)&device_id=\(deviceUUID)"
        guard let url = URL(string: urlString) else {
            logger.error("Invalid WebSocket URL")
            return
        }

        logger.info("WebSocket connecting to \(self.baseURL)...")

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: url)
        webSocketTask = task
        task.resume()

        // Wait for the handshake to complete before marking connected
        task.sendPing { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let error {
                    self.logger.warning("WebSocket handshake failed: \(error.localizedDescription)")
                    self.webSocketTask = nil
                    self.handleDisconnect()
                } else {
                    self.isConnected = true
                    self.reconnectAttempt = 0
                    self.logger.info("WebSocket connected")
                    self.receiveMessage()
                }
            }
        }
    }

    func disconnect() {
        isIntentionalDisconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
        logger.info("WebSocket disconnected")
    }

    // MARK: - Receive Loop

    private func receiveMessage() {
        guard let task = webSocketTask else { return }

        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch result {
                case .success(let message):
                    self.handleMessage(message)
                    self.receiveMessage() // continue listening

                case .failure(let error):
                    self.logger.warning("WebSocket receive error: \(error)")
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            guard let textData = text.data(using: .utf8) else { return }
            data = textData
        case .data(let binaryData):
            data = binaryData
        @unknown default:
            return
        }

        guard let event = try? JSONDecoder().decode(SyncEvent.self, from: data) else {
            logger.warning("Failed to decode WebSocket event")
            return
        }

        // Ignore events from this device
        if let eventDeviceId = event.deviceId, eventDeviceId == deviceUUID {
            return
        }

        lastEvent = event
        logger.info("Received event: \(event.type) from \(event.deviceName ?? "unknown")")

        handleEvent(event)
    }

    // MARK: - Event Handling

    private func handleEvent(_ event: SyncEvent) {
        let deviceName = event.deviceName ?? "Another device"

        switch event.type {
        case "scan_completed":
            sendNotification(
                title: "Scan Completed",
                body: event.summary ?? "\(deviceName) completed a plugin scan"
            )
            triggerDataRefresh()

        case "backup_completed":
            sendNotification(
                title: "Backup Completed",
                body: event.summary ?? "\(deviceName) completed a backup"
            )

        case "plugin_updated":
            sendNotification(
                title: "Plugins Updated",
                body: event.summary ?? "\(deviceName) updated plugin inventory"
            )
            triggerDataRefresh()

        case "session_synced":
            sendNotification(
                title: "Sessions Synced",
                body: event.summary ?? "\(deviceName) synced session data"
            )
            triggerDataRefresh()

        default:
            logger.info("Unknown event type: \(event.type)")
        }
    }

    private func triggerDataRefresh() {
        guard let auth, let sync, let scanner,
              auth.isAuthenticated, let token = auth.authToken else { return }

        Task {
            await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
        }
    }

    // MARK: - Reconnection

    private func handleDisconnect() {
        webSocketTask = nil
        isConnected = false

        guard !isIntentionalDisconnect else { return }

        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()

        guard reconnectAttempt < maxReconnectAttempts else {
            logger.info("Max reconnect attempts (\(self.maxReconnectAttempts)) reached, giving up. Use Sync to retry.")
            return
        }

        let delay = min(pow(2.0, Double(reconnectAttempt)), maxReconnectDelay)
        reconnectAttempt += 1

        logger.info("Scheduling reconnect in \(delay)s (attempt \(self.reconnectAttempt)/\(self.maxReconnectAttempts))")

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))

            guard let self, !Task.isCancelled else { return }

            guard let auth = self.auth, auth.isAuthenticated, let token = auth.authToken else {
                self.logger.info("Not authenticated, skipping reconnect")
                return
            }

            self.connect(token: token)
        }
    }

    // MARK: - Notifications

    private func sendNotification(title: String, body: String) {
        // Use MenuBarManager's notification method if available
        if let menuBar {
            menuBar.sendNotification(title: title, body: body)
        } else if Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            // Attach app icon
            if let iconURL = Bundle.main.url(forResource: "audioenv", withExtension: "icns"),
               let attachment = try? UNNotificationAttachment(
                   identifier: "appIcon",
                   url: iconURL,
                   options: [UNNotificationAttachmentOptionsTypeHintKey: "public.icns"]
               ) {
                content.attachments = [attachment]
            }

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
    }
}
