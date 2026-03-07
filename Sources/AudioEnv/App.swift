import SwiftUI
import Sparkle
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
    @StateObject private var remoteCommand = RemoteCommandService()
    @StateObject private var updater = UpdaterService()
    @StateObject private var spotlight = SpotlightPanelController()
    @StateObject private var hotkeyManager = HotkeyManager()
    @StateObject private var colorTokens = ColorTokens.shared

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
                .environmentObject(audioPlayer.timeObserver)
                .environmentObject(commandService)
                .environmentObject(patternService)
                .environmentObject(remoteCommand)
                .environmentObject(updater)
                .environmentObject(colorTokens)
                .environmentObject(hotkeyManager)
                .handlesExternalEvents(preferring: Set(arrayLiteral: "*"), allowing: Set(arrayLiteral: "*"))
                .onAppear {
                    // Set app icon programmatically so it works when running from Xcode / swift run
                    Self.setAppIconIfNeeded()

                    // Fetch remote color scheme
                    let colorBaseURL = UserDefaults.standard.string(forKey: "apiBaseURL") ?? "https://api.audioenv.com"
                    ColorTokens.shared.fetch(baseURL: colorBaseURL)

                    // Wire auth into sync for 401 retry
                    sync.authService = auth

                    // Configure menu bar manager with services
                    menuBar.configure(scanner: scanner, sync: sync, auth: auth, sessionMonitor: sessionMonitor)

                    // Configure session monitor
                    sessionMonitor.configure(scanner: scanner, backup: backup, sync: sync, auth: auth)

                    // Configure WebSocket service
                    webSocket.configure(scanner: scanner, sync: sync, auth: auth, menuBar: menuBar)

                    // Configure remote command service
                    remoteCommand.configure(
                        scanner: scanner,
                        backup: backup,
                        sync: sync,
                        bounce: bounceService,
                        auth: auth,
                        webSocket: webSocket
                    )
                    webSocket.remoteCommandService = remoteCommand

                    if auth.isAuthenticated, let token = auth.authToken {
                        webSocket.connect(token: token)
                    }

                    // Configure spotlight search panel
                    spotlight.configure(
                        scanner: scanner,
                        bounceService: bounceService,
                        collectionService: collectionService,
                        audioPlayer: audioPlayer,
                        auth: auth,
                        menuBar: menuBar
                    )

                    // Register global hotkey (Ctrl+Space)
                    hotkeyManager.register()

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

                    // Preload bounces and collections on launch so spotlight works immediately
                    if auth.isAuthenticated, let token = auth.authToken {
                        Task {
                            await bounceService.fetchFolders(token: token)
                            async let b: () = bounceService.fetchBounces(token: token)
                            async let c: () = collectionService.fetchCollections(token: token)
                            _ = await (b, c)
                            // Scan tracked bounce folders for new local files
                            await bounceService.scanAllAutoFolders(token: token)
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
                    if newUserId != nil, auth.isAuthenticated,
                       !scanner.plugins.isEmpty || !scanner.sessions.isEmpty {
                        Task {
                            guard let token = try? await auth.validToken() else { return }
                            await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
                        }
                    }

                    // Preload bounces and collections on login so spotlight search works immediately
                    if newUserId != nil, auth.isAuthenticated, let token = auth.authToken {
                        Task {
                            await bounceService.fetchFolders(token: token)
                            async let b: () = bounceService.fetchBounces(token: token)
                            async let c: () = collectionService.fetchCollections(token: token)
                            _ = await (b, c)
                            await bounceService.scanAllAutoFolders(token: token)
                        }
                    }
                }
                .onChange(of: scanner.isScanning) { oldValue, newValue in
                    // Auto-sync when scan completes
                    if oldValue == true && newValue == false, auth.isAuthenticated {
                        Task {
                            guard let token = try? await auth.validToken() else { return }
                            await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
                        }
                    }
                    // Rebuild menu bar to reflect scan state
                    menuBar.rebuildMenu()
                }
                .onChange(of: backup.destination != nil) { _, hasDestination in
                    if hasDestination {
                        Task { await backup.loadAvailableBackups() }
                    }
                }
                .onChange(of: sync.isSyncing) { _, _ in
                    menuBar.rebuildMenu()
                }
                .onChange(of: sessionMonitor.activeSessions.count) { _, _ in
                    menuBar.rebuildMenu()
                }
                .onChange(of: bounceService.lastScanCompletedAt) { _, _ in
                    guard auth.isAuthenticated, let token = auth.authToken else { return }
                    Task {
                        await collectionService.evaluateSmartCollections(
                            bounceService: bounceService,
                            commandService: commandService,
                            scanner: scanner,
                            backup: backup,
                            token: token
                        )
                    }
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
                .onReceive(NotificationCenter.default.publisher(for: .spotlightHotkeyPressed)) { _ in
                    spotlight.toggle()
                }
                .onReceive(NotificationCenter.default.publisher(for: .toggleSpotlight)) { _ in
                    spotlight.toggle()
                }
                .onOpenURL { url in
                    Self.handleURL(url, scanner: scanner, sync: sync, auth: auth)
                }
        }
        .handlesExternalEvents(matching: Set(arrayLiteral: "*"))
        .windowStyle(.hiddenTitleBar)
        .commands {
            AudioEnvCommands()

            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            CommandGroup(after: .help) {
                Button("How to Scan") {
                    NotificationCenter.default.post(name: .showHowToScan, object: nil)
                }
                .keyboardShortcut("?", modifiers: [.command, .shift])
            }
        }
    }

    // MARK: - Private Helpers

    /// Set the application icon from the bundled .icns file.
    /// This ensures the correct icon appears in the Dock and notifications
    /// even when running via Xcode or `swift run` (no .app bundle wrapper).
    private static func setAppIconIfNeeded() {
        // Try app bundle first (when running as .app)
        if let url = Bundle.main.url(forResource: "audioenv", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
            return
        }
        // Try SPM resource bundle
        let bundleName = "AudioEnv_AudioEnv.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(bundleName),
        ]
        for case let candidateURL? in candidates {
            if let bundle = Bundle(path: candidateURL.path),
               let url = bundle.url(forResource: "audioenv", withExtension: "icns"),
               let icon = NSImage(contentsOf: url) {
                NSApplication.shared.applicationIconImage = icon
                return
            }
        }
    }

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

        // Google OAuth callback from default browser
        if url.scheme == "com.googleusercontent.apps.809075910499-o01a42a6k9vo2e6a1sfcnifpei3bqnv9" {
            auth.handleGoogleOAuthCallback(url)
            return
        }

        guard url.scheme == "audioenv" else { return }

        switch url.host {
        case "scan":
            NotificationCenter.default.post(name: .navigateToSummary, object: nil)
            if !scanner.isScanning {
                scanner.scanAll()
            }
        case "sync":
            if auth.isAuthenticated {
                Task {
                    guard let token = try? await auth.validToken() else { return }
                    await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
                }
            }
        default:
            // "open" or anything else — just bring to front (handled by onOpenURL)
            break
        }
    }
}
