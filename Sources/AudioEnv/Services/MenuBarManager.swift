import AppKit
import SwiftUI
import UserNotifications
import os.log

/// Manages the persistent menu bar presence and background scanning schedule.
@MainActor
class MenuBarManager: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "MenuBar")

    private var statusItem: NSStatusItem?

    /// Whether background scheduled scanning is enabled.
    @Published var backgroundScanEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundScanEnabled, forKey: Self.bgScanKey) }
    }

    /// Scan interval in minutes (15, 30, 60, 120, 240).
    @Published var scanIntervalMinutes: Int {
        didSet {
            UserDefaults.standard.set(scanIntervalMinutes, forKey: Self.intervalKey)
            rescheduleTimer()
        }
    }

    private var scanTimer: Timer?
    private static let bgScanKey = "com.audioenv.backgroundScanEnabled"
    private static let intervalKey = "com.audioenv.scanIntervalMinutes"

    // References to services for background operations
    private weak var scanner: ScannerService?
    private weak var sync: SyncService?
    private weak var auth: AuthenticationService?
    private weak var sessionMonitor: SessionMonitorService?

    init() {
        self.backgroundScanEnabled = UserDefaults.standard.bool(forKey: Self.bgScanKey)
        let saved = UserDefaults.standard.integer(forKey: Self.intervalKey)
        self.scanIntervalMinutes = saved > 0 ? saved : 60
    }

    // MARK: - Setup

    func configure(scanner: ScannerService, sync: SyncService, auth: AuthenticationService, sessionMonitor: SessionMonitorService? = nil) {
        self.scanner = scanner
        self.sync = sync
        self.auth = auth
        self.sessionMonitor = sessionMonitor
        setupStatusItem()
        requestNotificationPermission()
        if backgroundScanEnabled {
            rescheduleTimer()
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform.badge.magnifyingglass", accessibilityDescription: "AudioEnv")
            button.image?.size = NSSize(width: 18, height: 18)
            button.image?.isTemplate = true
        }

        rebuildMenu()
    }

    /// Rebuild the dropdown menu with current state.
    func rebuildMenu() {
        let menu = NSMenu()

        // Last scan time
        let lastScanTitle: String
        if let date = scanner?.lastScanDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            lastScanTitle = "Last scan: \(formatter.localizedString(for: date, relativeTo: Date()))"
        } else {
            lastScanTitle = "No scans yet"
        }
        let lastScanItem = NSMenuItem(title: lastScanTitle, action: nil, keyEquivalent: "")
        lastScanItem.isEnabled = false
        menu.addItem(lastScanItem)

        // Sync status
        let syncTitle: String
        if sync?.isSyncing == true {
            syncTitle = "Syncing..."
        } else if let date = sync?.lastSyncDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            syncTitle = "Last sync: \(formatter.localizedString(for: date, relativeTo: Date()))"
        } else {
            syncTitle = "Not synced"
        }
        let syncItem = NSMenuItem(title: syncTitle, action: nil, keyEquivalent: "")
        syncItem.isEnabled = false
        menu.addItem(syncItem)

        // Live session status
        if let monitor = sessionMonitor, !monitor.activeSessions.isEmpty {
            menu.addItem(NSMenuItem.separator())

            for session in monitor.activeSessions {
                let dawName: String
                switch session.format {
                case .ableton: dawName = "Ableton Live"
                case .logic: dawName = "Logic Pro"
                case .proTools: dawName = "Pro Tools"
                }

                let sessionTitle = "\u{25CF} \(dawName) — \"\(session.projectName)\""
                let sessionItem = NSMenuItem(title: sessionTitle, action: nil, keyEquivalent: "")
                sessionItem.isEnabled = false
                menu.addItem(sessionItem)

                // Stats line: duration, save count, size delta
                var details: [String] = []
                details.append("Open \(session.duration.formatted)")
                if session.saveCount > 0 {
                    details.append("\(session.saveCount) save\(session.saveCount == 1 ? "" : "s")")
                }
                let delta = session.sizeDelta
                if delta != 0 {
                    let sign = delta > 0 ? "+" : ""
                    let mb = Double(abs(delta)) / (1024 * 1024)
                    if mb >= 1 {
                        details.append("\(sign)\(String(format: "%.1f", Double(delta) / (1024 * 1024)))MB")
                    } else {
                        details.append("\(sign)\(delta / 1024)KB")
                    }
                }

                let detailItem = NSMenuItem(title: "   \(details.joined(separator: " · "))", action: nil, keyEquivalent: "")
                detailItem.isEnabled = false
                menu.addItem(detailItem)

                // Process stats if available
                if let daw = monitor.runningDAWs.first(where: { $0.pid == session.dawPID }),
                   let stats = daw.stats {
                    var statsLine: [String] = []
                    statsLine.append("\(String(format: "%.0f", stats.memoryMB))MB RAM")
                    if let device = stats.audioDevice {
                        statsLine.append(device)
                    }
                    if let sr = stats.sampleRate {
                        statsLine.append("\(sr / 1000)kHz")
                    }
                    let statsItem = NSMenuItem(title: "   \(statsLine.joined(separator: " · "))", action: nil, keyEquivalent: "")
                    statsItem.isEnabled = false
                    menu.addItem(statsItem)
                }
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Quick scan
        let scanItem = NSMenuItem(title: "Scan Now", action: #selector(scanNow(_:)), keyEquivalent: "s")
        scanItem.target = self
        scanItem.isEnabled = scanner?.isScanning != true
        menu.addItem(scanItem)

        // Open main window
        let openItem = NSMenuItem(title: "Open AudioEnv", action: #selector(openMainWindow(_:)), keyEquivalent: "o")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        // Background scan toggle
        let bgItem = NSMenuItem(
            title: "Background Scanning",
            action: #selector(toggleBackgroundScan(_:)),
            keyEquivalent: ""
        )
        bgItem.target = self
        bgItem.state = backgroundScanEnabled ? .on : .off
        menu.addItem(bgItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit AudioEnv", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
    }

    // MARK: - Menu Actions

    @objc private func scanNow(_ sender: Any?) {
        guard let scanner, !scanner.isScanning else { return }
        scanner.scanAll()
        rebuildMenu()
    }

    @objc private func openMainWindow(_ sender: Any?) {
        showMainWindow()
    }

    @objc private func toggleBackgroundScan(_ sender: Any?) {
        backgroundScanEnabled.toggle()
        if backgroundScanEnabled {
            rescheduleTimer()
        } else {
            scanTimer?.invalidate()
            scanTimer = nil
        }
        rebuildMenu()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Window Management

    /// Show the main window and switch to regular (Dock) activation policy.
    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Open or bring to front the main window
        if let window = NSApp.windows.first(where: { $0.title.contains("AudioEnv") || $0.isKeyWindow }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // If no window exists, the WindowGroup will create one
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Called when the main window closes — switch to accessory (menu-bar-only) mode.
    func mainWindowDidClose() {
        // Only hide from Dock if no other windows are visible
        let visibleWindows = NSApp.windows.filter { $0.isVisible && !$0.title.isEmpty }
        if visibleWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Background Scanning

    private func rescheduleTimer() {
        scanTimer?.invalidate()
        guard backgroundScanEnabled else { return }

        let interval = TimeInterval(scanIntervalMinutes * 60)
        scanTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in
                self?.performBackgroundScan()
            }
        }
        logger.info("Background scan scheduled every \(self.scanIntervalMinutes) minutes")
    }

    private func performBackgroundScan() {
        guard let scanner, !scanner.isScanning else { return }

        logger.info("Starting background scan")
        scanner.scanAll()
        rebuildMenu()

        // Observe scan completion to auto-sync and send notification
        Task {
            // Poll for scan completion (scanner publishes isScanning)
            while scanner.isScanning {
                try? await Task.sleep(for: .milliseconds(500))
            }

            // Auto-sync if authenticated
            if let auth, let sync, auth.isAuthenticated, let token = auth.authToken {
                await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
            }

            sendNotification(
                title: "Scan Complete",
                body: "\(scanner.plugins.count) plugins, \(scanner.sessions.count) sessions found"
            )
            rebuildMenu()
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                self.logger.warning("Notification permission error: \(error)")
            }
        }
    }

    func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                self.logger.warning("Failed to send notification: \(error)")
            }
        }
    }
}
