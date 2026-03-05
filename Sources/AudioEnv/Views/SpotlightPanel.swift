import AppKit

/// A non-activating floating panel that appears above all apps without stealing focus.
/// Behaves like Raycast/Alfred — the frontmost app (e.g. Ableton) keeps focus
/// while this panel accepts keyboard input for the search field.
class SpotlightPanel: NSPanel {

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow

        // Hide traffic light buttons so no titlebar chrome is visible
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true

        // Remove the titlebar visual effect view (the bar peeking through)
        if let titlebarContainer = contentView?.superview?.subviews.first(where: {
            $0.className.contains("NSTitlebarContainerView")
        }) {
            titlebarContainer.isHidden = true
        }

        centerOnScreen()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Position: center horizontally, upper third of screen.
    /// Uses the screen containing the mouse cursor so it always appears
    /// on the display the user is actively looking at.
    func centerOnScreen() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let screenFrame = screen.frame
        let x = screenFrame.midX - frame.width / 2
        let y = screenFrame.midY + (screenFrame.height / 6) - frame.height / 2
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}
