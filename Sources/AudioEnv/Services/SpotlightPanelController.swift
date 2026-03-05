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

        isVisible = true
        logger.info("Spotlight panel shown")
    }

    func hide() {
        guard let panel, isVisible else { return }

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

        // Dismiss on click outside
        NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak panel] event in
            guard let self, let panel, self.isVisible else { return event }
            if event.window != panel {
                self.hide()
            }
            return event
        }

        self.panel = panel
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
