import SwiftUI

// MARK: – Top-level navigation category

enum AppSection: String, CaseIterable, Identifiable {
    case summary     = "Summary"
    case plugins     = "Plugins"
    case projects    = "Projects"
    case collections = "Collections"
    case activity    = "Activity"
    case bounces     = "Bounces"
    case patterns    = "Patterns"
    case commands    = "Commands"
    case scan        = "Scan"
    case spotlight    = "Spotlight"
    case transfers   = "Transfers"
    case cloud       = "Cloud"
    case backup      = "Backup"
    case profile     = "Profile"

    var id: String { rawValue }
}

// MARK: – Root view

/// Three-column NavigationSplitView layout:
///   1. Sidebar   – category picker (Summary / Plugins / Sessions)
///   2. Content   – list for the selected category
///   3. Detail    – session detail when a session is selected
struct ContentView: View {
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var backup: BackupService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var remoteCommand: RemoteCommandService
    @EnvironmentObject var activityService: ActivityService

    @State private var section:         AppSection?    = .summary
    @State private var selectedProject: SessionProject? = nil
    @State private var selectedPlugin:  AudioPlugin?   = nil
    @State private var selectedBackup:     BackupListItem? = nil
    @State private var selectedCollection: AudioCollection?     = nil
    @State private var selectedBounce:     Bounce?         = nil
    @State private var selectedActivity: ActivityRecord?  = nil
    @State private var selectedCommand:  Command?        = nil
    @State private var selectedPattern:  BouncePattern?  = nil
    @State private var selectedCloudItem: CloudItem?     = nil
    @State private var projectFormatFilter: SessionFormat? = nil
    @State private var showPaths                      = false
    @State private var showHowToScan                  = false
    @State private var showRescanConfirmation         = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var projectCount: Int = 0

    var body: some View {
        if !auth.isAuthenticated {
            LoginGateView()
                .background(WindowAccessor { window in
                    window.maxSize = NSSize(width: 500, height: 600)
                    window.minSize = NSSize(width: 500, height: 600)
                    let size = NSSize(width: 500, height: 600)
                    let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
                    let screenFrame = screen?.visibleFrame ?? .zero
                    let newOrigin = NSPoint(
                        x: screenFrame.midX - size.width / 2,
                        y: screenFrame.midY - size.height / 2
                    )
                    let newFrame = NSRect(origin: newOrigin, size: size)
                    window.setFrame(newFrame, display: true, animate: true)
                })
        } else {
        VStack(spacing: 0) {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // ── Sidebar ─────────────────────────────────────────
            List(selection: $section) {
                Section("Library") {
                    Label("Summary",  systemImage: "chart.bar")
                        .badge(0)
                        .tag(AppSection.summary)

                    Label("Plugins",  systemImage: scanner.hasCatalogMatches ? "puzzlepiece.extension" : "waveform")
                        .badge(scanner.plugins.count)
                        .tag(AppSection.plugins)

                    Label("Projects", systemImage: "folder.fill")
                        .badge(projectCount)
                        .tag(AppSection.projects)

                    Label("Collections", systemImage: "rectangle.stack")
                        .tag(AppSection.collections)

                    Label("Activity", systemImage: "clock.arrow.circlepath")
                        .tag(AppSection.activity)

                    Label("Bounces", systemImage: "waveform")
                        .tag(AppSection.bounces)

                    Label("Patterns", systemImage: "text.viewfinder")
                        .tag(AppSection.patterns)

                    Label("Commands", systemImage: "terminal")
                        .tag(AppSection.commands)
                }

                Section("Settings") {
                    Label("Scan", systemImage: "viewfinder.circle")
                        .tag(AppSection.scan)

                    Label("Spotlight", systemImage: "sparkle.magnifyingglass")
                        .tag(AppSection.spotlight)

                    Label("Transfers", systemImage: "arrow.down.circle")
                        .tag(AppSection.transfers)
                }

                Section("Cloud") {
                    Label("Files", systemImage: "cloud")
                        .tag(AppSection.cloud)
                    Label("Backup", systemImage: "arrow.up.circle")
                        .tag(AppSection.backup)
                }

                Section("Account") {
                    HStack {
                        Label("Profile", systemImage: auth.isAuthenticated ? "person.crop.circle.fill.badge.checkmark" : "person.crop.circle")
                        if auth.isAuthenticated {
                            Spacer()
                            Circle()
                                .fill(Color.green)
                                .frame(width: 8, height: 8)
                        }
                    }
                    .tag(AppSection.profile)
                }

                if backup.isUploading {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: "icloud.and.arrow.up")
                                    .foregroundColor(.blue)
                                Text("Backing up...")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                Text("\(Int(backup.uploadProgress * 100))%")
                                    .font(.caption)
                                    .monospacedDigit()
                            }
                            ProgressView(value: backup.uploadProgress)
                                .progressViewStyle(.linear)
                            if let name = backup.currentBackupName {
                                Text(name)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                if scanner.isScanning || scanner.isParsingIndividual {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Image(systemName: scanner.isScanning ? "viewfinder.circle" : "doc.text.magnifyingglass")
                                    .foregroundColor(.blue)
                                Text(scanner.isScanning ? "Scanning..." : "Parsing...")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                Spacer()
                                if scanner.isScanning {
                                    Text("\(Int(scanner.scanProgress * 100))%")
                                        .font(.caption)
                                        .monospacedDigit()
                                }
                            }
                            if scanner.isScanning {
                                ProgressView(value: scanner.scanProgress)
                                    .progressViewStyle(.linear)
                            } else {
                                ProgressView()
                                    .controlSize(.small)
                            }
                            Text(scanner.statusMessage)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 220)
            .navigationTitle("AudioEnv")

        } content: {
            // ── Content column ──────────────────────────────────
            Group {
                switch section {
                case .summary:
                    SummaryView(
                        onNavigateToPlugins: { section = .plugins },
                        onNavigateToProjects: { format in
                            projectFormatFilter = format
                            section = .projects
                        }
                    )
                case .plugins:
                    PluginBrowserView(selectedPlugin: $selectedPlugin)
                case .projects:
                    SessionBrowserView(selectedProject: $selectedProject, formatFilter: $projectFormatFilter)
                case .collections:
                    CollectionBrowserView(selectedCollection: $selectedCollection)
                case .activity:
                    ActivityBrowserView(selectedActivity: $selectedActivity)
                case .bounces:
                    BounceBrowserView(selectedBounce: $selectedBounce)
                case .patterns:
                    PatternBrowserView(selectedPattern: $selectedPattern)
                case .commands:
                    CommandBrowserView(selectedCommand: $selectedCommand)
                case .scan:
                    ScanView()
                case .spotlight:
                    SpotlightSettingsView()
                case .transfers:
                    WebTransfersSettingsView()
                case .cloud:
                    CloudBrowserView(selectedItem: $selectedCloudItem)
                case .backup:
                    BackupConfigView(scanner: scanner, backup: backup, selectedBackup: $selectedBackup)
                case .profile:
                    ProfileView()
                case .none:
                    Spacer()
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 400, max: 520)
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            // Clear detail selection whenever the sidebar category changes.
            .onChange(of: section) { oldValue, newValue in
                // Only clear selections if we're actually changing sections
                guard oldValue != newValue else { return }
                // Only clear the selections that were set
                if selectedProject != nil { selectedProject = nil }
                if selectedPlugin != nil { selectedPlugin = nil }
                if selectedBackup != nil { selectedBackup = nil }
                if selectedCollection != nil { selectedCollection = nil }
                if selectedBounce != nil { selectedBounce = nil }
                if selectedActivity != nil { selectedActivity = nil }
                if selectedCloudItem != nil { selectedCloudItem = nil }
                if selectedCommand != nil { selectedCommand = nil }

                columnVisibility = .all
            }

        } detail: {
            // ── Detail column ───────────────────────────────────
            switch section {
            case .projects:
                if let project = selectedProject {
                    ProjectDetailView(project: project)
                } else {
                    emptyDetail()
                }
            case .plugins:
                if let plugin = selectedPlugin {
                    PluginDetailView(plugin: plugin)
                } else {
                    emptyDetail()
                }
            case .collections:
                if let collection = selectedCollection {
                    CollectionDetailView(collectionId: collection.id)
                } else {
                    emptyDetail()
                }
            case .activity:
                if let activity = selectedActivity {
                    ActivityDetailView(activity: activity)
                } else {
                    emptyDetail()
                }
            case .bounces:
                if let bounce = selectedBounce {
                    BounceDetailPanel(bounce: bounce)
                } else {
                    emptyDetail()
                }
            case .patterns:
                if let pattern = selectedPattern {
                    PatternDetailPanel(pattern: pattern)
                } else {
                    emptyDetail()
                }
            case .commands:
                if let command = selectedCommand {
                    CommandDetailView(command: command)
                } else {
                    emptyDetail()
                }
            case .cloud:
                if let cloudItem = selectedCloudItem {
                    CloudItemDetailView(item: cloudItem)
                } else {
                    emptyDetail()
                }
            case .backup:
                if let backupItem = selectedBackup {
                    BackupDetailView(backup: backupItem, backupService: backup)
                } else {
                    emptyDetail()
                }
            case .summary:
                summaryDetailPanel()
            case .scan:
                scanDetailPanel()
            case .spotlight:
                spotlightDetailPanel()
            case .transfers:
                transfersDetailPanel()
            default:
                Color.clear
            }
        }
        .frame(minWidth: 1200, idealWidth: 1500, minHeight: 620, idealHeight: 780)
        .onChange(of: columnVisibility) { _, newValue in
            // Prevent macOS from auto-collapsing the sidebar
            if newValue != .all {
                columnVisibility = .all
            }
        }
        .toolbar {
            // Only show scan buttons on the Scan page
            if section == .scan {
                Button(action: { showPaths.toggle() }) {
                    Label("Manage Paths", systemImage: "folder.badge.gear")
                }
                Button(action: { showRescanConfirmation = true }) {
                    Label(
                        scanner.isScanning ? "Scanning…" : "Scan",
                        systemImage: scanner.isScanning ? "circle.dotted" : "magnifyingglass"
                    )
                }
                .disabled(scanner.isScanning)
            }
        }
        .sheet(isPresented: $showPaths) {
            PathManagerView()
                .environmentObject(scanner)
        }
        .sheet(isPresented: $showHowToScan) {
            HowToScanView()
        }
        .sheet(item: $remoteCommand.pendingDownloadPrompt) { prompt in
            WebDownloadPromptView(prompt: prompt)
        }
        .confirmationDialog(
            "Are you sure you want to rescan?",
            isPresented: $showRescanConfirmation,
            titleVisibility: .visible
        ) {
            Button("Scan") {
                scanner.scanAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will scan your system for plugins and projects. This may take a while.")
        }
        .onReceive(NotificationCenter.default.publisher(for: .showHowToScan)) { _ in
            showHowToScan = true
        }
        // Keyboard shortcuts
        .onReceive(NotificationCenter.default.publisher(for: .triggerRescan)) { _ in
            showRescanConfirmation = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .showPathManager)) { _ in
            showPaths = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSummary)) { _ in
            section = .summary
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToCommands)) { _ in
            section = .commands
        }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayPause)) { _ in
            audioPlayer.togglePlayPause()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToSection)) { notification in
            if let raw = notification.userInfo?["section"] as? String,
               let target = AppSection(rawValue: raw) {
                section = target
            }
        }
        .onAppear {
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // Space bar play/pause — skip if a text field has focus
                if event.keyCode == 49,
                   event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                   !(NSApp.keyWindow?.firstResponder is NSTextView) {
                    audioPlayer.togglePlayPause()
                    return nil
                }
                return event
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToProject)) { notification in
            guard let projectPath = notification.userInfo?["projectPath"] as? String else { return }
            section = .projects
            // Find the matching project group and select it
            let projects = SessionProject.groupSessions(scanner.sessions)
            if let match = projects.first(where: { project in
                project.sessions.contains { $0.path == projectPath }
            }) {
                selectedProject = match
            }
        }

        PlayerBarView()
        } // end VStack
        .background(WindowAccessor { window in
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            window.minSize = NSSize(width: 1200, height: 620)
            let size = NSSize(width: 1360, height: 780)
            let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first
            let screenFrame = screen?.visibleFrame ?? .zero
            let newOrigin = NSPoint(
                x: screenFrame.midX - size.width / 2,
                y: screenFrame.midY - size.height / 2
            )
            let newFrame = NSRect(origin: newOrigin, size: size)
            window.setFrame(newFrame, display: true, animate: true)
        })
        .onAppear {
            projectCount = SessionProject.groupSessions(scanner.sessions).count
        }
        .onChange(of: scanner.sessions) { _, newSessions in
            projectCount = SessionProject.groupSessions(newSessions).count
        }
        } // end if authenticated
    }

    private func resizeWindow(width: CGFloat, height: CGFloat, minWidth: CGFloat? = nil, minHeight: CGFloat? = nil) {
        guard let window = NSApplication.shared.mainWindow else { return }
        let newSize = NSSize(width: width, height: height)
        // Set minSize *before* resizing so the frame isn't clamped
        window.minSize = NSSize(width: minWidth ?? width, height: minHeight ?? height)
        let oldFrame = window.frame
        let newOrigin = NSPoint(
            x: oldFrame.midX - width / 2,
            y: oldFrame.midY - height / 2
        )
        let newFrame = NSRect(origin: newOrigin, size: newSize)
        window.setFrame(newFrame, display: true, animate: true)
    }

    // ── Detail placeholder ──────────────────────────────────────

    private func emptyDetail() -> some View {
        Group {
            switch section {
            case .plugins:
                VStack(spacing: 14) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a Plugin")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Select a plugin to see its details and associated projects.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .projects:
                VStack(spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a Project")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Choose a project from the list to view its sessions.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .collections:
                VStack(spacing: 14) {
                    Image(systemName: "rectangle.stack")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a Collection")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Choose a collection to view its projects and details.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .bounces:
                VStack(spacing: 14) {
                    Image(systemName: "waveform")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a Bounce")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Choose a bounce to view its audio details and linked projects.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .patterns:
                VStack(spacing: 14) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a Pattern")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Patterns extract metadata like BPM, key, and version from bounce filenames.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .commands:
                VStack(spacing: 14) {
                    Image(systemName: "terminal")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("Select a Command")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("Choose a command or recipe to view its details, or create a new one.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            case .backup:
                VStack(spacing: 14) {
                    Image(systemName: backup.destination == nil ? "cloud" : "externaldrive.badge.icloud")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text(backup.destination == nil ? "Create a Backup" : "Select a Backup")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(backup.destination == nil
                         ? "Configure S3 backup to get started."
                         : "Select a backup from the list to view details.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            default:
                // For other sections - show minimal or no detail
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: – Detail panels for Summary and Scan

    private func summaryDetailPanel() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                        Spacer()
                    }
                    Text("Library Overview")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Quick insights about your audio production environment")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.bottom, 8)

                Divider()

                // Quick Stats
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick Stats")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    InfoRow(label: "Total Plugins", value: "\(scanner.plugins.count)")
                    InfoRow(label: "Projects", value: "\(projectCount)")
                    InfoRow(label: "Sessions", value: "\(scanner.sessions.count)")

                    if scanner.lastScanDate != nil {
                        InfoRow(label: "Last Scan", value: lastScannedText())
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Format Breakdown
                if !scanner.plugins.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Plugin Formats")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        ForEach(PluginFormat.allCases) { format in
                            let count = scanner.plugins.filter { $0.format == format }.count
                            if count > 0 {
                                HStack {
                                    Circle()
                                        .fill(ColorTokens.shared.pluginFormatColor(format))
                                        .frame(width: 8, height: 8)
                                    Text(format.rawValue)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(count)")
                                        .fontWeight(.medium)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)
                }

                Spacer()
            }
            .padding(20)
        }
    }

    private func scanDetailPanel() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "viewfinder.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                        Spacer()
                    }
                    Text("Scan Status")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Overview of discovered audio plugins and sessions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.bottom, 8)

                Divider()

                // Discovered counts
                VStack(alignment: .leading, spacing: 12) {
                    Text("Discovered")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    InfoRow(label: "Plugins", value: "\(scanner.plugins.count)")
                    InfoRow(label: "Sessions", value: "\(scanner.sessions.count)")
                    InfoRow(label: "Projects", value: "\(projectCount)")
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Scan info
                VStack(alignment: .leading, spacing: 12) {
                    Text("Scan Info")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    InfoRow(label: "Last Scan", value: lastScannedText())
                    InfoRow(label: "Status", value: scanner.isScanning ? "Scanning…" : "Idle")
                    InfoRow(label: "Cache", value: scanner.plugins.isEmpty && scanner.sessions.isEmpty ? "Empty" : "Populated")
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Scan button
                Button(action: { showRescanConfirmation = true }) {
                    HStack {
                        Image(systemName: scanner.isScanning ? "circle.dotted" : "magnifyingglass")
                        Text(scanner.isScanning ? "Scanning…" : "Run Scan")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanner.isScanning)

                Spacer()
            }
            .padding(20)
        }
    }


    private func spotlightDetailPanel() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "sparkle.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                        Spacer()
                    }
                    Text("Spotlight Search")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Global search for plugins, projects, bounces, and collections")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.bottom, 8)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("How to Use")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    InfoRow(label: "Trigger", value: "Press the global hotkey from any app")
                    InfoRow(label: "Search", value: "Type to search across all items")
                    InfoRow(label: "Commands", value: "Type play, go, share, queue, or download")
                    InfoRow(label: "Navigate", value: "Arrow keys to move, Enter to select")
                    InfoRow(label: "Dismiss", value: "Escape or click outside the panel")
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                Spacer()
            }
            .padding(20)
        }
    }

    private func transfersDetailPanel() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.blue)
                        Spacer()
                    }
                    Text("Web Transfers")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Configure where projects sent from the web app are saved on this Mac")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.bottom, 8)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("How it Works")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    InfoRow(label: "Upload", value: "Upload a project zip on the web app")
                    InfoRow(label: "Send", value: "Click \"Send to Mac\" on the web dashboard")
                    InfoRow(label: "Receive", value: "Choose where to save on this Mac")
                    InfoRow(label: "Scan", value: "Project is auto-scanned after download")
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Saved Paths")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    ForEach(SessionFormat.allCases) { format in
                        let path = WebDownloadPaths.path(for: format)
                        InfoRow(
                            label: format.rawValue,
                            value: path.map { abbreviateHomePath($0) } ?? "Not set"
                        )
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                Spacer()
            }
            .padding(20)
        }
    }

    private func abbreviateHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func lastScannedText() -> String {
        guard let date = scanner.lastScanDate else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Web Download Prompt Sheet

struct WebDownloadPromptView: View {
    let prompt: WebDownloadPrompt

    @State private var savePath: String
    @State private var selectedFormat: SessionFormat?
    @State private var rememberChoice = false
    @State private var userChangedPath = false
    @Environment(\.dismiss) private var dismiss

    init(prompt: WebDownloadPrompt) {
        self.prompt = prompt
        self._savePath = State(initialValue: prompt.suggestedPath)
        self._selectedFormat = State(initialValue: prompt.detectedFormat)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 36))
                    .foregroundColor(.blue)

                Text("Project from Web")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("Choose where to save this project")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            // File info + format picker
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("File")
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .leading)
                    Text(prompt.filename)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                HStack {
                    Text("Type")
                        .foregroundColor(.secondary)
                        .frame(width: 60, alignment: .leading)

                    Picker("", selection: $selectedFormat) {
                        Text("Unknown").tag(SessionFormat?.none)
                        ForEach(SessionFormat.allCases) { format in
                            Text(format.rawValue).tag(SessionFormat?.some(format))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 160)
                    .onChange(of: selectedFormat) { _, newFormat in
                        // Re-infer path when user changes format (unless they manually browsed)
                        guard !userChangedPath else { return }
                        if let format = newFormat {
                            if let saved = WebDownloadPaths.path(for: format) {
                                savePath = saved
                            } else if let inferred = WebDownloadPaths.inferPath(for: format, from: prompt.sessions) {
                                savePath = inferred
                            }
                        } else {
                            savePath = prompt.suggestedPath
                        }
                    }

                    if prompt.detectedFormat != nil && selectedFormat == prompt.detectedFormat {
                        Text("auto-detected")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            // Path selection
            VStack(alignment: .leading, spacing: 8) {
                Text("Save Location")
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(abbreviatePath(savePath))
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)

                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseFiles = false
                        panel.canChooseDirectories = true
                        panel.allowsMultipleSelection = false
                        panel.message = "Choose where to save \"\(prompt.filename)\""
                        panel.directoryURL = URL(fileURLWithPath: savePath)
                        if panel.runModal() == .OK, let url = panel.url {
                            savePath = url.path
                            userChangedPath = true
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Remember toggle
            if selectedFormat != nil {
                Toggle(isOn: $rememberChoice) {
                    Text("Always save \(selectedFormat!.rawValue) projects here")
                        .font(.subheadline)
                }
            }

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    prompt.continuation.resume(returning: WebDownloadPromptResult(
                        savePath: prompt.suggestedPath,
                        selectedFormat: nil,
                        rememberForFormat: false
                    ))
                    dismiss()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save Here") {
                    prompt.continuation.resume(returning: WebDownloadPromptResult(
                        savePath: savePath,
                        selectedFormat: selectedFormat,
                        rememberForFormat: rememberChoice
                    ))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Login Gate

/// Full-window login view shown when the user is not authenticated.
struct LoginGateView: View {
    @EnvironmentObject var auth: AuthenticationService

    @State private var showingRegister = false
    @State private var email = ""
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 28) {
                // App icon + branding
                VStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 80, height: 80)
                        .cornerRadius(16)

                    Text("AudioEnv")
                        .font(.largeTitle)
                        .fontWeight(.bold)

                    Text("Sign in to manage your plugins, projects, and backups")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320)
                }

                // Form
                VStack(spacing: 14) {
                    if showingRegister {
                        TextField("Username", text: $username)
                            .textFieldStyle(.roundedBorder)
                            .textContentType(.username)
                    }

                    TextField("Email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)

                    SecureField("Password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(showingRegister ? .newPassword : .password)
                        .onSubmit {
                            if isFormValid {
                                Task { await submitForm() }
                            }
                        }
                }
                .frame(width: 300)

                // Error
                if let error = auth.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .frame(maxWidth: 300)
                }

                // Submit
                Button {
                    Task { await submitForm() }
                } label: {
                    HStack {
                        if auth.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(showingRegister ? "Create Account" : "Sign In")
                    }
                    .frame(width: 300)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(auth.isLoading || !isFormValid)

                // OAuth divider
                HStack {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Rectangle()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(height: 1)
                }
                .frame(width: 300)

                // OAuth buttons
                VStack(spacing: 10) {
                    Button {
                        Task {
                            do {
                                try await auth.signInWithApple()
                            } catch {
                                auth.errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "apple.logo")
                            Text(showingRegister ? "Sign up with Apple" : "Sign in with Apple")
                        }
                        .frame(width: 300)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.black)
                    .controlSize(.large)
                    .disabled(auth.isLoading)

                    Button {
                        Task {
                            do {
                                try await auth.signInWithGoogle()
                            } catch {
                                auth.errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        HStack {
                            Text("G")
                                .fontWeight(.bold)
                                .foregroundColor(.blue)
                            Text(showingRegister ? "Sign up with Google" : "Sign in with Google")
                        }
                        .frame(width: 300)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(auth.isLoading)
                }

                // Toggle
                Button {
                    showingRegister.toggle()
                    auth.errorMessage = nil
                } label: {
                    Text(showingRegister
                         ? "Already have an account? Sign In"
                         : "Don't have an account? Sign Up")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(width: 500, height: 600)
    }

    private var isFormValid: Bool {
        if showingRegister {
            return !email.isEmpty && !username.isEmpty && !password.isEmpty && password.count >= 6
        }
        return !email.isEmpty && !password.isEmpty
    }

    private func submitForm() async {
        do {
            if showingRegister {
                try await auth.register(email: email, username: username, password: password)
            } else {
                try await auth.login(email: email, password: password)
            }
            email = ""
            username = ""
            password = ""
        } catch {
            auth.errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Window Accessor

/// NSViewRepresentable that reliably captures the hosting NSWindow.
/// Unlike NSApplication.shared.mainWindow (which can be nil during onAppear),
/// this walks the view hierarchy to find the window once it's available.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onWindow(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
