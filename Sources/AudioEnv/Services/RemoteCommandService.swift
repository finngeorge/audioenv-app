import Foundation
import os

struct RemoteCommandInfo: Identifiable {
    let id: String  // command_id from server
    let commandType: String
    let payload: [String: Any]
    var status: String  // running, completed, failed
}

struct RemoteCommandMessage {
    let commandId: String
    let commandType: String
    let payload: [String: Any]
}

@MainActor
class RemoteCommandService: ObservableObject {
    private let logger = Logger(subsystem: "com.audioenv.app", category: "RemoteCommand")

    @Published var activeCommand: RemoteCommandInfo?

    // Service references (set via configure)
    private weak var scannerService: ScannerService?
    private weak var backupService: BackupService?
    private weak var syncService: SyncService?
    private weak var bounceService: BounceService?
    private weak var authService: AuthenticationService?
    private weak var webSocketService: WebSocketService?

    func configure(
        scanner: ScannerService,
        backup: BackupService,
        sync: SyncService,
        bounce: BounceService,
        auth: AuthenticationService,
        webSocket: WebSocketService
    ) {
        self.scannerService = scanner
        self.backupService = backup
        self.syncService = sync
        self.bounceService = bounce
        self.authService = auth
        self.webSocketService = webSocket
    }

    func execute(_ command: RemoteCommandMessage) async {
        let commandId = command.commandId
        logger.info("Executing remote command: \(command.commandType) [\(commandId)]")

        activeCommand = RemoteCommandInfo(
            id: commandId,
            commandType: command.commandType,
            payload: command.payload,
            status: "running"
        )

        // Send running status
        webSocketService?.sendCommandStatus(
            commandId: commandId,
            status: "running",
            result: nil,
            errorMessage: nil
        )

        do {
            var result: [String: Any]?

            switch command.commandType {
            case "scan":
                guard let scanner = scannerService else { throw RemoteCommandError.serviceUnavailable("ScannerService") }
                guard authService?.authToken != nil else { throw RemoteCommandError.notAuthenticated }
                scanner.scanAll()
                result = ["plugin_count": scanner.plugins.count, "session_count": scanner.sessions.count]

            case "sync":
                guard let sync = syncService else { throw RemoteCommandError.serviceUnavailable("SyncService") }
                guard let scanner = scannerService else { throw RemoteCommandError.serviceUnavailable("ScannerService") }
                guard let token = authService?.authToken else { throw RemoteCommandError.notAuthenticated }
                await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)

            case "backup_plugin":
                guard let backup = backupService else { throw RemoteCommandError.serviceUnavailable("BackupService") }
                guard let scanner = scannerService else { throw RemoteCommandError.serviceUnavailable("ScannerService") }
                guard authService?.authToken != nil else { throw RemoteCommandError.notAuthenticated }
                guard let bundleId = command.payload["bundle_id"] as? String else {
                    throw RemoteCommandError.invalidPayload("Missing bundle_id")
                }
                if let plugin = scanner.plugins.first(where: { $0.bundleID == bundleId }) {
                    await backup.backupPlugins([plugin], backupName: "Remote: \(plugin.name)")
                } else {
                    throw RemoteCommandError.invalidPayload("Plugin not found: \(bundleId)")
                }

            case "backup_session":
                guard let backup = backupService else { throw RemoteCommandError.serviceUnavailable("BackupService") }
                guard authService?.authToken != nil else { throw RemoteCommandError.notAuthenticated }
                guard let path = command.payload["path"] as? String else {
                    throw RemoteCommandError.invalidPayload("Missing path")
                }
                guard let scanner = scannerService else { throw RemoteCommandError.serviceUnavailable("ScannerService") }
                if let session = scanner.sessions.first(where: { $0.path == path }) {
                    await backup.backupSession(session)
                } else {
                    throw RemoteCommandError.invalidPayload("Session not found: \(path)")
                }

            case "backup_bounce":
                guard let backup = backupService else { throw RemoteCommandError.serviceUnavailable("BackupService") }
                guard authService?.authToken != nil else { throw RemoteCommandError.notAuthenticated }
                guard let bounceIdStr = command.payload["bounce_id"] as? String,
                      let bounceId = UUID(uuidString: bounceIdStr) else {
                    throw RemoteCommandError.invalidPayload("Missing or invalid bounce_id")
                }
                guard let bounce = bounceService else { throw RemoteCommandError.serviceUnavailable("BounceService") }
                if let bounceItem = bounce.bounces.first(where: { $0.id == bounceId }) {
                    await backup.backupBounce(bounceItem)
                } else {
                    throw RemoteCommandError.invalidPayload("Bounce not found: \(bounceIdStr)")
                }

            case "parse_session":
                guard let scanner = scannerService else { throw RemoteCommandError.serviceUnavailable("ScannerService") }
                guard let path = command.payload["path"] as? String else {
                    throw RemoteCommandError.invalidPayload("Missing path")
                }
                scanner.parseIndividualSession(path: path)

            default:
                throw RemoteCommandError.unknownCommand(command.commandType)
            }

            // Send completed status
            activeCommand?.status = "completed"
            webSocketService?.sendCommandStatus(
                commandId: commandId,
                status: "completed",
                result: result,
                errorMessage: nil
            )
            logger.info("Remote command completed: \(command.commandType) [\(commandId)]")

        } catch {
            activeCommand?.status = "failed"
            webSocketService?.sendCommandStatus(
                commandId: commandId,
                status: "failed",
                result: nil,
                errorMessage: error.localizedDescription
            )
            logger.error("Remote command failed: \(command.commandType) [\(commandId)] - \(error)")
        }

        // Clear active command after a delay
        try? await Task.sleep(for: .seconds(2))
        if activeCommand?.id == commandId {
            activeCommand = nil
        }
    }
}

enum RemoteCommandError: LocalizedError {
    case serviceUnavailable(String)
    case notAuthenticated
    case invalidPayload(String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .serviceUnavailable(let name): return "\(name) is not available"
        case .notAuthenticated: return "Not authenticated"
        case .invalidPayload(let msg): return "Invalid payload: \(msg)"
        case .unknownCommand(let type): return "Unknown command type: \(type)"
        }
    }
}
