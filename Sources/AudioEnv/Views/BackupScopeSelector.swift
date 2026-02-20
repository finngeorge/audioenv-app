import SwiftUI

/// Interactive UI for selecting what to include in a backup
struct BackupScopeSelector: View {
    @ObservedObject var scanner: ScannerService
    @Binding var selectedScope: BackupScope?
    @Binding var backupName: String

    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var bounceService: BounceService

    @State private var scopeType: ScopeType = .everything
    @State private var collectionProjects: [CollectionService.CollectionProject] = []
    @State private var collectionBounces: [CollectionService.CollectionBounce] = []
    @State private var selectedProject: SessionProject? = nil
    @State private var selectedPlugin: AudioPlugin? = nil
    @State private var selectedCollection: AudioCollection? = nil
    @State private var includeProjectDependencies = true
    @State private var customPlugins: Set<UUID> = []
    @State private var customProjects: Set<String> = []
    @State private var stats: BackupScopeStats? = nil

    @Environment(\.dismiss) private var dismiss

    enum ScopeType: String, CaseIterable, Identifiable {
        case everything = "Complete Environment"
        case collection = "Collection"
        case project = "Project-Based"
        case plugin = "Single Plugin"
        case custom = "Custom Selection"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .everything: return "square.stack.3d.up.fill"
            case .collection: return "tray.full.fill"
            case .project: return "folder.fill"
            case .plugin: return "waveform"
            case .custom: return "checkmark.square"
            }
        }

        var description: String {
            switch self {
            case .everything:
                return "Back up all plugins and projects"
            case .collection:
                return "Back up all projects and plugin dependencies in a collection"
            case .project:
                return "Back up a specific project with optional plugin dependencies"
            case .plugin:
                return "Back up a single plugin only"
            case .custom:
                return "Manually select plugins and projects to include"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Select Backup Scope")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Choose what to include in this backup")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.05))

            ScrollView {
                VStack(spacing: 20) {
                    // Scope Type Picker
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Backup Type")
                            .font(.headline)

                        ForEach(ScopeType.allCases) { type in
                            scopeTypeButton(type)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)

                    // Type-specific options
                    scopeOptionsView()
                        .padding()
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(12)

                    // Backup Name
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Backup Name")
                            .font(.headline)

                        TextField("Enter backup name", text: $backupName)
                            .textFieldStyle(.roundedBorder)

                        Text("Leave blank for auto-generated name")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)

                    // Stats Preview
                    if let stats = stats {
                        statsPreview(stats)
                            .padding()
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(12)
                    }
                }
                .padding()
            }

            // Footer Actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Calculate Size") {
                    calculateStats()
                }
                .buttonStyle(.bordered)
                .disabled(!canCalculate)

                Button("Continue") {
                    applyScope()
                }
                .buttonStyle(.borderedProminent)
                .disabled(stats == nil || stats?.isEmpty == true)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
        }
        .frame(width: 700, height: 600)
        .onAppear {
            updateBackupName()
        }
    }

    // MARK: - Scope Type Button

    private func scopeTypeButton(_ type: ScopeType) -> some View {
        Button(action: {
            scopeType = type
            updateBackupName()
            stats = nil
        }) {
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.title3)
                    .foregroundColor(scopeType == type ? .white : .blue)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(type.rawValue)
                        .font(.headline)
                        .foregroundColor(scopeType == type ? .white : .primary)

                    Text(type.description)
                        .font(.caption)
                        .foregroundColor(scopeType == type ? .white.opacity(0.9) : .secondary)
                }

                Spacer()

                if scopeType == type {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }
            .padding()
            .background(scopeType == type ? Color.blue : Color.clear)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Type-Specific Options

    @ViewBuilder
    private func scopeOptionsView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.headline)

            switch scopeType {
            case .everything:
                Text("This will back up all \(scanner.plugins.count) plugins and all \(SessionProject.groupSessions(scanner.sessions).count) projects.")
                    .foregroundColor(.secondary)

            case .collection:
                collectionOptions()

            case .project:
                projectOptions()

            case .plugin:
                pluginOptions()

            case .custom:
                customOptions()
            }
        }
    }

    private func projectOptions() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Select Project", selection: $selectedProject) {
                Text("Choose a project...").tag(nil as SessionProject?)
                ForEach(SessionProject.groupSessions(scanner.sessions)) { project in
                    Text(project.name).tag(project as SessionProject?)
                }
            }
            .onChange(of: selectedProject) { _, _ in
                updateBackupName()
                stats = nil
            }

            if selectedProject != nil {
                Toggle("Include Plugin Dependencies", isOn: $includeProjectDependencies)
                    .onChange(of: includeProjectDependencies) { _, _ in
                        updateBackupName()
                        stats = nil
                    }

                if let project = selectedProject {
                    Text("Project has \(project.sessions.count) session(s)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func pluginOptions() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Select Plugin", selection: $selectedPlugin) {
                Text("Choose a plugin...").tag(nil as AudioPlugin?)
                ForEach(scanner.plugins) { plugin in
                    Text("\(plugin.name) (\(plugin.format.rawValue))").tag(plugin as AudioPlugin?)
                }
            }
            .onChange(of: selectedPlugin) { _, _ in
                updateBackupName()
                stats = nil
            }

            if let plugin = selectedPlugin {
                Text("Plugin: \(plugin.name)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func collectionOptions() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Select Collection", selection: $selectedCollection) {
                Text("Choose a collection...").tag(nil as AudioCollection?)
                ForEach(collectionService.collections) { collection in
                    Text(collection.name).tag(collection as AudioCollection?)
                }
            }
            .onChange(of: selectedCollection) { _, newCollection in
                updateBackupName()
                stats = nil
                collectionProjects = []
                collectionBounces = []
                if let collection = newCollection, let token = auth.authToken {
                    Task {
                        if collection.hasProjects {
                            collectionProjects = await collectionService.fetchCollectionProjects(
                                collectionId: collection.id, token: token
                            )
                        }
                        if collection.hasBounces {
                            collectionBounces = await collectionService.fetchCollectionBounces(
                                collectionId: collection.id, token: token
                            )
                        }
                    }
                }
            }

            if let collection = selectedCollection {
                Text("Collection \"\(collection.name)\" — \(collection.projectCount) projects, \(collection.bounceCount) bounces")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func customOptions() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Plugins Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Plugins")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(customPlugins.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(scanner.plugins.prefix(20)) { plugin in
                            pluginToggleChip(plugin)
                        }
                    }
                }
                .frame(height: 35)
            }

            // Projects Section
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Projects")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text("\(customProjects.count) selected")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(SessionProject.groupSessions(scanner.sessions).prefix(20)) { project in
                            projectToggleChip(project)
                        }
                    }
                }
                .frame(height: 35)
            }

            Button(action: {
                // Select all
                customPlugins = Set(scanner.plugins.map { $0.id })
                customProjects = Set(SessionProject.groupSessions(scanner.sessions).map { $0.id })
                stats = nil
            }) {
                Text("Select All")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
        }
    }

    private func pluginToggleChip(_ plugin: AudioPlugin) -> some View {
        Button(action: {
            if customPlugins.contains(plugin.id) {
                customPlugins.remove(plugin.id)
            } else {
                customPlugins.insert(plugin.id)
            }
            stats = nil
        }) {
            Text(plugin.name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(customPlugins.contains(plugin.id) ? Color.blue : Color.secondary.opacity(0.1))
                .foregroundColor(customPlugins.contains(plugin.id) ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func projectToggleChip(_ project: SessionProject) -> some View {
        Button(action: {
            if customProjects.contains(project.id) {
                customProjects.remove(project.id)
            } else {
                customProjects.insert(project.id)
            }
            stats = nil
        }) {
            Text(project.name)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(customProjects.contains(project.id) ? Color.cyan : Color.secondary.opacity(0.1))
                .foregroundColor(customProjects.contains(project.id) ? .white : .primary)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stats Preview

    private func statsPreview(_ stats: BackupScopeStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Backup Preview")
                    .font(.headline)
            }

            Divider()

            if stats.isEmpty {
                Text("No items selected")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 8) {
                    if stats.pluginCount > 0 {
                        StatRow(label: "Plugins", value: "\(stats.pluginCount) (\(stats.formattedPluginSize))")
                    }
                    if stats.projectCount > 0 {
                        StatRow(label: "Projects", value: "\(stats.projectCount) projects")
                        StatRow(label: "Sessions", value: "\(stats.sessionCount) files (\(stats.formattedProjectSize))")
                    }
                    if stats.bounceCount > 0 {
                        StatRow(label: "Bounces", value: "\(stats.bounceCount) files (\(stats.formattedBounceSize))")
                    }

                    Divider()

                    StatRow(
                        label: "Total Size",
                        value: stats.formattedTotalSize,
                        highlight: true
                    )
                }
            }
        }
    }

    // MARK: - Helpers

    private var canCalculate: Bool {
        switch scopeType {
        case .everything:
            return true
        case .collection:
            return selectedCollection != nil
        case .project:
            return selectedProject != nil
        case .plugin:
            return selectedPlugin != nil
        case .custom:
            return !customPlugins.isEmpty || !customProjects.isEmpty
        }
    }

    private func calculateStats() {
        guard let scope = buildScope() else { return }
        stats = scope.calculateStats(scanner: scanner)
    }

    private func buildScope() -> BackupScope? {
        switch scopeType {
        case .everything:
            return .everything

        case .collection:
            guard let collection = selectedCollection else { return nil }
            // Match fetched collection projects to local SessionProject objects by name
            let allLocalProjects = SessionProject.groupSessions(scanner.sessions)
            let collectionProjectNames = Set(collectionProjects.map {
                ($0.projectName ?? $0.sessionName ?? "").lowercased()
            }.filter { !$0.isEmpty })

            let matchedProjects: [SessionProject]
            if !collectionProjectNames.isEmpty {
                matchedProjects = allLocalProjects.filter { localProject in
                    collectionProjectNames.contains(localProject.name.lowercased())
                }
            } else {
                matchedProjects = []
            }

            // Resolve plugin dependencies only from matched projects
            let usedPluginNames = Set(matchedProjects.flatMap { project in
                project.sessions.flatMap { session -> [String] in
                    guard let parsed = session.project else { return [] }
                    switch parsed {
                    case .ableton(let p): return p.usedPlugins
                    case .logic(_), .proTools(_): return []
                    }
                }
            })
            let matchedPlugins: [AudioPlugin]
            if usedPluginNames.isEmpty {
                matchedPlugins = []
            } else {
                matchedPlugins = scanner.plugins.filter { plugin in
                    let pluginName = plugin.name.lowercased()
                    return usedPluginNames.contains { usedName in
                        let name = usedName.lowercased()
                        return name.contains(pluginName) || pluginName.contains(name)
                    }
                }
            }

            // Resolve bounces from collection
            let matchedBounces: [Bounce] = collectionBounces.compactMap { cb in
                guard let path = cb.filePath, let id = UUID(uuidString: cb.id) else { return nil }
                let bounce = Bounce(
                    id: id,
                    userId: UUID(),
                    bounceFolderId: UUID(),
                    fileName: cb.fileName,
                    filePath: path,
                    fileSizeBytes: cb.fileSizeBytes ?? 0,
                    format: cb.format ?? "wav",
                    durationSeconds: cb.durationSeconds,
                    sampleRate: cb.sampleRate,
                    bitDepth: cb.bitDepth,
                    createdAt: Date(),
                    fileModifiedAt: Date()
                )
                return bounce.isLocallyAvailable ? bounce : nil
            }

            return .collection(name: collection.name, projects: matchedProjects, plugins: matchedPlugins, bounces: matchedBounces)

        case .project:
            guard let project = selectedProject else { return nil }
            return includeProjectDependencies
                ? .projectWithDependencies(project)
                : .singleProject(project)

        case .plugin:
            guard let plugin = selectedPlugin else { return nil }
            return .singlePlugin(plugin)

        case .custom:
            let plugins = scanner.plugins.filter { customPlugins.contains($0.id) }
            let projects = SessionProject.groupSessions(scanner.sessions)
                .filter { customProjects.contains($0.id) }
            return .custom(plugins: plugins, projects: projects)
        }
    }

    private func updateBackupName() {
        if let scope = buildScope() {
            backupName = scope.generateName()
        }
    }

    private func applyScope() {
        selectedScope = buildScope()
        dismiss()
    }
}

#Preview {
    BackupScopeSelector(
        scanner: ScannerService(),
        selectedScope: .constant(nil),
        backupName: .constant("")
    )
}
