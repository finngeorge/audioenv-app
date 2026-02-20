import SwiftUI
import os.log

@main
struct AudioEnvApp: App {
    @StateObject private var scanner = ScannerService()
    @StateObject private var backup  = BackupService()
    @StateObject private var auth    = AuthenticationService()
    @StateObject private var sampleCollector = SampleCollectionService()
    @StateObject private var sync    = SyncService()
    @StateObject private var tempRestore = TempRestoreService()
    @StateObject private var menuBar = MenuBarManager()
    @StateObject private var webSocket = WebSocketService()
    @StateObject private var sessionMonitor = SessionMonitorService()
    @StateObject private var collectionService = CollectionService()
    @StateObject private var bounceService = BounceService()
    @StateObject private var audioPlayer = AudioPlayerService()
    @StateObject private var commandService = CommandService()
    @StateObject private var patternService = PatternService()

    @Environment(\.scenePhase) private var scenePhase

    private static let logger = Logger(subsystem: "com.audioenv.app", category: "App")

    var body: some Scene {
        WindowGroup("AudioEnv") {
            ContentView()
                .environmentObject(scanner)
                .environmentObject(backup)
                .environmentObject(auth)
                .environmentObject(sampleCollector)
                .environmentObject(sync)
                .environmentObject(tempRestore)
                .environmentObject(menuBar)
                .environmentObject(webSocket)
                .environmentObject(sessionMonitor)
                .environmentObject(collectionService)
                .environmentObject(bounceService)
                .environmentObject(audioPlayer)
                .environmentObject(commandService)
                .environmentObject(patternService)
                .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
                .onAppear {
                    // Configure menu bar manager with services
                    menuBar.configure(scanner: scanner, sync: sync, auth: auth, sessionMonitor: sessionMonitor)

                    // Configure session monitor
                    sessionMonitor.configure(scanner: scanner, backup: backup, sync: sync, auth: auth)

                    // Configure WebSocket service
                    webSocket.configure(scanner: scanner, sync: sync, auth: auth, menuBar: menuBar)
                    if auth.isAuthenticated, let token = auth.authToken {
                        webSocket.connect(token: token)
                    }

                    // Check for orphaned temp restore sessions
                    tempRestore.checkForOrphanedSessions()

                    // Sync user ID from auth to backup service
                    backup.userId = auth.currentUser?.id

                    // Wire up manifest sync callback
                    backup.onManifestUploaded = { manifest in
                        guard let token = auth.authToken else { return }
                        Task {
                            await sync.syncBackupManifest(manifest: manifest, token: token)
                        }
                    }

                    // Load S3 config for current user if logged in
                    if let userId = auth.currentUser?.id {
                        Self.loadS3ConfigForUser(userId, backup: backup)

                        if let token = auth.authToken {
                            if let config = KeychainHelper.shared.loadS3Config(forUser: userId) {
                                // Push local config to API to keep it in sync
                                Task {
                                    await sync.syncS3Config(
                                        bucket: config.bucket,
                                        region: config.region,
                                        accessKey: config.accessKeyId,
                                        secretKey: config.secretKey,
                                        token: token
                                    )
                                }
                            } else {
                                // No local config — try restoring from API
                                Self.restoreS3ConfigFromAPI(userId: userId, token: token, sync: sync, backup: backup)
                            }
                        }
                    }
                }
                .onChange(of: auth.currentUser?.id) { oldUserId, newUserId in
                    // Update backup service when user logs in/out
                    backup.userId = newUserId

                    // Clear old user's S3 config from memory when user changes
                    if let oldId = oldUserId, oldId != newUserId {
                        backup.configure(destination: nil)
                    }

                    // Load new user's S3 config from keychain, or restore from API
                    if let newId = newUserId {
                        Self.loadS3ConfigForUser(newId, backup: backup)

                        if let token = auth.authToken {
                            Self.restoreS3ConfigFromAPI(userId: newId, token: token, sync: sync, backup: backup)
                        }
                    }

                    // Connect/disconnect WebSocket on auth changes
                    if let _ = newUserId, auth.isAuthenticated, let token = auth.authToken {
                        webSocket.connect(token: token)
                    } else if newUserId == nil {
                        webSocket.disconnect()
                    }

                    // Auto-sync on login if scanner has data
                    if newUserId != nil, auth.isAuthenticated, let token = auth.authToken,
                       !scanner.plugins.isEmpty || !scanner.sessions.isEmpty {
                        Task {
                            await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
                        }
                    }
                }
                .onChange(of: scanner.isScanning) { oldValue, newValue in
                    // Auto-sync when scan completes
                    if oldValue == true && newValue == false,
                       auth.isAuthenticated, let token = auth.authToken {
                        Task {
                            await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
                        }
                    }
                    // Rebuild menu bar to reflect scan state
                    menuBar.rebuildMenu()
                }
                .onChange(of: sync.isSyncing) { _, _ in
                    menuBar.rebuildMenu()
                }
                .onChange(of: sessionMonitor.activeSessions.count) { _, _ in
                    menuBar.rebuildMenu()
                }
                .onReceive(NotificationCenter.default.publisher(for: .sessionSnapshotCaptured)) { _ in
                    menuBar.rebuildMenu()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                    if let window = notification.object as? NSWindow,
                       window.title.contains("AudioEnv") {
                        menuBar.mainWindowDidClose()
                    }
                }
                .onOpenURL { url in
                    Self.handleURL(url, scanner: scanner, sync: sync, auth: auth)
                }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .windowStyle(.hiddenTitleBar)
        .commands {
            AudioEnvCommands()

            CommandGroup(after: .help) {
                Button("How to Scan") {
                    NotificationCenter.default.post(name: .showHowToScan, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Private Helpers

    @MainActor
    private static func loadS3ConfigForUser(_ userId: String, backup: BackupService) {
        // First attempt migration from old unscoped config
        KeychainHelper.shared.migrateS3ConfigIfNeeded(forUser: userId)

        // Then load user-scoped config from keychain
        if let config = KeychainHelper.shared.loadS3Config(forUser: userId) {
            let destination = S3BackupDestination(
                bucketName: config.bucket,
                region: config.region,
                credentials: (config.accessKeyId, config.secretKey)
            )
            backup.configure(destination: destination)
        }
    }

    /// Try to restore S3 config from the API if keychain is empty.
    @MainActor
    private static func restoreS3ConfigFromAPI(userId: String, token: String, sync: SyncService, backup: BackupService) {
        // Only fetch from API if local keychain has nothing
        guard KeychainHelper.shared.loadS3Config(forUser: userId) == nil else { return }

        Task {
            let restored = await sync.fetchS3Config(token: token, userId: userId)
            if restored {
                // Now load from keychain (fetchS3Config saved it there)
                loadS3ConfigForUser(userId, backup: backup)
            }
        }
    }

    @MainActor
    private static func handleURL(_ url: URL, scanner: ScannerService, sync: SyncService, auth: AuthenticationService) {
        logger.info("Received URL: \(url)")

        guard url.scheme == "audioenv" else { return }

        switch url.host {
        case "scan":
            NotificationCenter.default.post(name: .navigateToSummary, object: nil)
            if !scanner.isScanning {
                scanner.scanAll()
            }
        case "sync":
            if auth.isAuthenticated, let token = auth.authToken {
                Task {
                    await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
                }
            }
        default:
            // "open" or anything else — just bring to front (handled by onOpenURL)
            break
        }
    }
}
