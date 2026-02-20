import SwiftUI

// MARK: – Top-level navigation category

enum AppSection: String, CaseIterable, Identifiable {
    case summary     = "Summary"
    case plugins     = "Plugins"
    case projects    = "Projects"
    case collections = "Collections"
    case bounces     = "Bounces"
    case commands    = "Commands"
    case scan        = "Scan"
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

    @State private var section:         AppSection?    = .summary
    @State private var selectedProject: SessionProject? = nil
    @State private var selectedPlugin:  AudioPlugin?   = nil
    @State private var selectedBackup:     BackupListItem? = nil
    @State private var selectedCollection: AudioCollection?     = nil
    @State private var selectedBounce:     Bounce?         = nil
    @State private var selectedCommand:  Command?        = nil
    @State private var projectFormatFilter: SessionFormat? = nil
    @State private var showPaths                      = false
    @State private var showHowToScan                  = false
    @State private var showRescanConfirmation         = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if !auth.isAuthenticated {
            LoginGateView()
                .onAppear { resizeWindow(width: 500, height: 600) }
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
                        .badge(SessionProject.groupSessions(scanner.sessions).count)
                        .tag(AppSection.projects)

                    Label("Collections", systemImage: "rectangle.stack")
                        .tag(AppSection.collections)

                    Label("Bounces", systemImage: "waveform")
                        .tag(AppSection.bounces)

                    Label("Commands", systemImage: "terminal")
                        .tag(AppSection.commands)
                }

                Section("Settings") {
                    Label("Scan", systemImage: "viewfinder.circle")
                        .tag(AppSection.scan)
                }

                Section("Cloud") {
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
                case .bounces:
                    BounceBrowserView(selectedBounce: $selectedBounce)
                case .commands:
                    CommandBrowserView(selectedCommand: $selectedCommand)
                case .scan:
                    ScanView()
                case .backup:
                    BackupConfigView(scanner: scanner, backup: backup, selectedBackup: $selectedBackup)
                case .profile:
                    ProfileView()
                case .none:
                    Spacer()
                }
            }
            .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
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
            case .bounces:
                if let bounce = selectedBounce {
                    BounceDetailPanel(bounce: bounce)
                } else {
                    emptyDetail()
                }
            case .commands:
                if let command = selectedCommand {
                    CommandDetailView(command: command)
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
            default:
                Color.clear
            }
        }
        .frame(minWidth: 1200, idealWidth: 1360, minHeight: 620, idealHeight: 780)
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
        .onAppear { resizeWindow(width: 1360, height: 780, minWidth: 1200, minHeight: 620) }
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
                    InfoRow(label: "Projects", value: "\(SessionProject.groupSessions(scanner.sessions).count)")
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
                                        .fill(pluginFormatColor(format))
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
                    InfoRow(label: "Projects", value: "\(SessionProject.groupSessions(scanner.sessions).count)")
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

    private func pluginFormatColor(_ format: PluginFormat) -> Color {
        switch format {
        case .audioUnit: return Color(red: 0.98, green: 0.85, blue: 0.93)  // #f9d9ee
        case .vst:       return Color(red: 0.60, green: 0.80, blue: 0.95)  // #9accf3
        case .vst3:      return Color(red: 0.62, green: 0.86, blue: 0.74)  // #9edbbd
        case .aax:       return Color(red: 0.99, green: 0.95, blue: 0.85)  // #fdf3d8
        }
    }

    private func lastScannedText() -> String {
        guard let date = scanner.lastScanDate else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
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
