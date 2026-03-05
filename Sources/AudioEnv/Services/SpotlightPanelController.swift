import AppKit
import SwiftUI
import os.log

/// Owns the floating spotlight panel, manages show/hide lifecycle,
/// hosts the SwiftUI view, and bridges commands to app services.
@MainActor
final class SpotlightPanelController: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "SpotlightPanel")

    private var panel: SpotlightPanel?
    private let searchService = SpotlightSearchService()
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var keyMonitor: Any?
    private var deactivationObserver: Any?

    @Published var isVisible = false

    // Service references (injected via configure)
    private weak var scanner: ScannerService?
    private weak var bounceService: BounceService?
    private weak var collectionService: CollectionService?
    private weak var audioPlayer: AudioPlayerService?
    private weak var auth: AuthenticationService?
    private weak var menuBar: MenuBarManager?

    // MARK: - Configuration

    func configure(
        scanner: ScannerService,
        bounceService: BounceService,
        collectionService: CollectionService,
        audioPlayer: AudioPlayerService,
        auth: AuthenticationService,
        menuBar: MenuBarManager
    ) {
        self.scanner = scanner
        self.bounceService = bounceService
        self.collectionService = collectionService
        self.audioPlayer = audioPlayer
        self.auth = auth
        self.menuBar = menuBar

        searchService.configure(
            scanner: scanner,
            bounceService: bounceService,
            collectionService: collectionService,
            auth: auth
        )
    }

    // MARK: - Show / Hide

    func toggle() {
        if isVisible { hide() } else { show() }
    }

    func show() {
        // Require authentication — don't show spotlight if not logged in
        guard let auth, auth.isAuthenticated else {
            logger.info("Spotlight blocked: not authenticated")
            menuBar?.showMainWindow()
            return
        }

        if panel == nil { createPanel() }

        searchService.reset()

        guard let panel else { return }
        panel.centerOnScreen()
        panel.alphaValue = 0

        panel.orderFrontRegardless()
        panel.makeKey()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        installEventMonitors()
        isVisible = true
        logger.info("Spotlight panel shown")
    }

    func hide() {
        guard let panel, isVisible else { return }

        removeEventMonitors()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.isVisible = false
            self?.logger.info("Spotlight panel hidden")
        })
    }

    // MARK: - Panel Creation

    private func createPanel() {
        let rootView = SpotlightPanelView(
            searchService: searchService,
            audioPlayer: audioPlayer ?? AudioPlayerService(),
            onExecute: { [weak self] verb, result in
                self?.executeCommand(verb: verb, result: result)
            },
            onQuickAction: { [weak self] action, result in
                self?.executeQuickAction(action, result: result)
            },
            onNavigateSection: { [weak self] section in
                self?.navigateToSection(section)
            },
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 680, height: 420)

        let panel = SpotlightPanel()
        panel.contentView = hostingView

        self.panel = panel
    }

    // MARK: - Event Monitors

    private func installEventMonitors() {
        // Dismiss on click inside another app window
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak panel] event in
            guard let self, let panel, self.isVisible else { return event }
            if event.window != panel {
                self.hide()
            }
            return event
        }

        let dismissOnFocusLoss = UserDefaults.standard.object(forKey: "spotlightDismissOnFocusLoss") as? Bool ?? true

        if dismissOnFocusLoss {
            // Dismiss on click outside the app entirely (like Raycast)
            globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isVisible else { return }
                    self.hide()
                }
            }

            // Dismiss when the app loses focus (e.g. Cmd+Tab away)
            deactivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isVisible else { return }
                    self.hide()
                }
            }
        }

        // Handle modifier+Return for quick actions
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak panel] event in
            guard let self, self.isVisible, event.window == panel else { return event }
            guard event.keyCode == 36 else { return event }

            let mods = event.modifierFlags.intersection([.command, .option, .shift])

            if mods == .command {
                self.executeQuickActionForSelected(.showInFinder)
                return nil
            } else if mods == .option {
                self.executeQuickActionForSelected(.openInDAW)
                return nil
            } else if mods == .shift {
                self.executeQuickActionForSelected(.openInQuickLook)
                return nil
            }
            return event
        }
    }

    private func removeEventMonitors() {
        if let monitor = localClickMonitor {
            NSEvent.removeMonitor(monitor)
            localClickMonitor = nil
        }
        if let monitor = globalClickMonitor {
            NSEvent.removeMonitor(monitor)
            globalClickMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        if let observer = deactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            deactivationObserver = nil
        }
    }

    private func executeQuickActionForSelected(_ action: SpotlightQuickAction) {
        let flat = searchService.flatResults
        let index = searchService.selectedIndex
        guard index >= 0 && index < flat.count else { return }
        let result = flat[index]
        guard SpotlightQuickAction.actions(for: result.type).contains(where: { $0.id == action.id }) else { return }
        executeQuickAction(action, result: result)
    }

    // MARK: - Command Execution

    private func executeCommand(verb: SpotlightVerb?, result: SpotlightResult) {
        let effectiveVerb = verb ?? defaultVerb(for: result.type)

        switch effectiveVerb {
        case .play:
            guard result.type == .bounce, let bounce = findBounce(id: result.id) else {
                navigateToResult(result)
                break
            }
            audioPlayer?.play(bounce: bounce)
            hide()

        case .queue:
            guard result.type == .bounce, let bounce = findBounce(id: result.id) else { break }
            audioPlayer?.addToQueue(bounce: bounce)
            hide()

        case .download:
            guard result.type == .bounce else { break }
            downloadBounce(id: result.id)
            hide()

        case .go:
            navigateToResult(result)
            hide()

        case .share:
            guard result.type == .project else { break }
            navigateToSection(.projects)
            NotificationCenter.default.post(
                name: .navigateToProject,
                object: nil,
                userInfo: ["projectPath": result.id]
            )
            hide()
        }
    }

    /// Default verb when user selects a result in plain search mode (no verb typed)
    private func defaultVerb(for type: SpotlightResultType) -> SpotlightVerb {
        switch type {
        case .bounce: return .play
        case .plugin, .project, .collection: return .go
        }
    }

    private func navigateToResult(_ result: SpotlightResult) {
        let section: AppSection
        switch result.type {
        case .plugin: section = .plugins
        case .project: section = .projects
        case .bounce: section = .bounces
        case .collection: section = .collections
        }
        navigateToSection(section)

        // For projects, also navigate to the specific project
        if result.type == .project {
            NotificationCenter.default.post(
                name: .navigateToProject,
                object: nil,
                userInfo: ["projectPath": result.id]
            )
        }
    }

    private func navigateToSection(_ section: AppSection) {
        menuBar?.showMainWindow()
        NotificationCenter.default.post(
            name: .navigateToSection,
            object: nil,
            userInfo: ["section": section.rawValue]
        )
    }

    // MARK: - Quick Actions

    private func executeQuickAction(_ action: SpotlightQuickAction, result: SpotlightResult) {
        switch action {
        case .showInFinder:
            revealInFinder(result)
            hide()

        case .openInDAW:
            openInDAW(result)
            hide()

        case .openInQuickLook:
            quickLookFile(result)
            hide()

        case .revealPlugin:
            revealInFinder(result)
            hide()
        }
    }

    private func revealInFinder(_ result: SpotlightResult) {
        let path: String?
        switch result.type {
        case .bounce:
            path = findBounce(id: result.id)?.filePath
        case .project:
            // result.id is the session path
            path = result.id
        case .plugin:
            // Find the plugin path from scanner
            if let uuid = UUID(uuidString: result.id) {
                path = scanner?.plugins.first(where: { $0.id == uuid })?.path
            } else {
                path = nil
            }
        case .collection:
            path = nil
        }
        guard let path else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func openInDAW(_ result: SpotlightResult) {
        guard result.type == .project, let scanner else { return }
        // result.id is a session path — find the project group and pick the
        // latest non-backup session so we don't open an auto-save
        guard let matchedSession = scanner.sessions.first(where: { $0.path == result.id }) else { return }

        let projectKey = matchedSession.projectGroupKey
        let latestSession = scanner.sessions
            .filter { $0.projectGroupKey == projectKey && !$0.isBackup }
            .sorted { $0.modifiedDate > $1.modifiedDate }
            .first
            ?? matchedSession  // fallback to matched session if all are backups

        let url = URL(fileURLWithPath: latestSession.path)
        let session = latestSession

        // Open with the appropriate DAW based on session format
        let bundleID: String
        switch session.format {
        case .ableton:
            bundleID = "com.ableton.live"
        case .logic:
            bundleID = "com.apple.logic10"
        case .proTools:
            bundleID = "com.avid.ProTools"
        }

        let config = NSWorkspace.OpenConfiguration()
        if let dawURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.open([url], withApplicationAt: dawURL, configuration: config)
        } else {
            // Fallback: open with default app
            NSWorkspace.shared.open(url)
        }
    }

    private func quickLookFile(_ result: SpotlightResult) {
        let path: String?
        switch result.type {
        case .bounce:
            path = findBounce(id: result.id)?.filePath
        case .project:
            path = result.id
        default:
            path = nil
        }
        guard let path else { return }
        // Open in Quick Look via default handler
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Helpers

    private func findBounce(id: String) -> Bounce? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return bounceService?.bounces.first { $0.id == uuid }
    }

    private func downloadBounce(id: String) {
        guard let bounce = findBounce(id: id),
              let token = auth?.authToken else { return }

        Task {
            await bounceService?.downloadBounce(bounce, token: token)
        }
    }
}
