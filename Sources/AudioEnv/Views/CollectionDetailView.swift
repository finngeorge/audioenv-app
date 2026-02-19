import SwiftUI

/// Detail view for a selected collection — shows its projects and/or bounces based on content_types.
struct CollectionDetailView: View {
    let collectionId: UUID
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var bounceService: BounceService

    @State private var showEditSheet = false
    @State private var showAddProjectsSheet = false
    @State private var showAddBouncesSheet = false
    @State private var showDeleteConfirmation = false
    @State private var projects: [CollectionService.CollectionProject] = []
    @State private var bounces: [CollectionService.CollectionBounce] = []
    @State private var isLoadingProjects = false
    @State private var isLoadingBounces = false

    /// Live collection from service array — updates when fetchCollections refreshes.
    private var collection: AudioCollection? {
        collectionService.collections.first(where: { $0.id == collectionId })
    }

    var body: some View {
        if let collection {
            content(collection)
        } else {
            Text("Collection not found")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ collection: AudioCollection) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                header(collection)

                Divider()

                // Projects section (if content_types includes "projects")
                if collection.hasProjects {
                    projectsSection(collection)
                }

                // Bounces section (if content_types includes "bounces")
                if collection.hasBounces {
                    bouncesSection(collection)
                }

                // Quick actions
                VStack(alignment: .leading, spacing: 12) {
                    Text("Actions")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 12) {
                        Button {
                            showEditSheet = true
                        } label: {
                            Label("Edit Collection", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)

                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                Spacer()
            }
            .padding(20)
        }
        .sheet(isPresented: $showEditSheet) {
            EditCollectionSheet(collection: collection)
        }
        .sheet(isPresented: $showAddProjectsSheet) {
            AddProjectsSheet(collectionId: collectionId)
        }
        .sheet(isPresented: $showAddBouncesSheet) {
            AddBouncesSheet(collectionId: collectionId)
        }
        .task(id: collectionId) {
            await loadContent()
        }
        .onChange(of: collection.projectCount) { _, _ in
            Task { await loadProjects() }
        }
        .onChange(of: collection.bounceCount) { _, _ in
            Task { await loadBounces() }
        }
        .confirmationDialog(
            "Delete \"\(collection.name)\"?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    if let token = auth.authToken {
                        await collectionService.deleteCollection(id: collectionId, token: token)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove the collection but not the projects or bounces themselves.")
        }
    }

    // MARK: - Projects Section

    @ViewBuilder
    private func projectsSection(_ collection: AudioCollection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Projects", systemImage: "folder")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showAddProjectsSheet = true
                } label: {
                    Label("Add Projects", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if collection.projectCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No projects in this collection")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Add Projects") {
                        showAddProjectsSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if isLoadingProjects {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading projects...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(projects) { project in
                    projectRow(project)
                    if project.id != projects.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    private func projectRow(_ project: CollectionService.CollectionProject) -> some View {
        HStack(spacing: 10) {
            Image(systemName: formatIcon(project.sessionFormat))
                .font(.title3)
                .foregroundColor(formatColor(project.sessionFormat))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.displayName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let fmt = project.sessionFormat {
                        Text(fmt)
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(formatColor(fmt).opacity(0.15))
                            .foregroundColor(formatColor(fmt))
                            .cornerRadius(3)
                    }
                    if let tracks = project.trackCount, tracks > 0 {
                        Text("\(tracks) tracks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let plugins = project.pluginCount, plugins > 0 {
                        Text("\(plugins) plugins")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let size = project.fileSizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button(role: .destructive) {
                Task {
                    if let token = auth.authToken,
                       let sessionId = UUID(uuidString: project.id) {
                        await collectionService.removeProject(
                            collectionId: collectionId,
                            sessionId: sessionId,
                            token: token
                        )
                        await loadProjects()
                    }
                }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from collection")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bounces Section

    @ViewBuilder
    private func bouncesSection(_ collection: AudioCollection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Bounces", systemImage: "waveform")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    showAddBouncesSheet = true
                } label: {
                    Label("Add Bounces", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if collection.bounceCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No bounces in this collection")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Add Bounces") {
                        showAddBouncesSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if isLoadingBounces {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading bounces...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ForEach(bounces) { bounce in
                    bounceRow(bounce)
                    if bounce.id != bounces.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    private func bounceRow(_ bounce: CollectionService.CollectionBounce) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.title3)
                .foregroundColor(bounceFormatColor(bounce.format))
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(bounce.fileName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if let fmt = bounce.format {
                        Text(fmt.uppercased())
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(bounceFormatColor(fmt).opacity(0.15))
                            .foregroundColor(bounceFormatColor(fmt))
                            .cornerRadius(3)
                    }
                    if let duration = bounce.durationSeconds {
                        Text(formatDuration(duration))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let sr = bounce.sampleRate {
                        Text("\(sr / 1000)kHz")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let size = bounce.fileSizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button(role: .destructive) {
                Task {
                    if let token = auth.authToken,
                       let bounceId = UUID(uuidString: bounce.id) {
                        await collectionService.removeBounce(
                            collectionId: collectionId,
                            bounceId: bounceId,
                            token: token
                        )
                        await loadBounces()
                    }
                }
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from collection")
        }
        .padding(.vertical, 4)
    }

    // MARK: - Data Loading

    private func loadContent() async {
        guard let collection else { return }
        if collection.hasProjects { await loadProjects() }
        if collection.hasBounces { await loadBounces() }
    }

    private func loadProjects() async {
        guard let token = auth.authToken else { return }
        isLoadingProjects = true
        projects = await collectionService.fetchCollectionProjects(collectionId: collectionId, token: token)
        isLoadingProjects = false
    }

    private func loadBounces() async {
        guard let token = auth.authToken else { return }
        isLoadingBounces = true
        bounces = await collectionService.fetchCollectionBounces(collectionId: collectionId, token: token)
        isLoadingBounces = false
    }

    // MARK: - Helpers

    private func formatIcon(_ format: String?) -> String {
        switch format?.lowercased() {
        case "ableton live": return "circle.fill"
        case "logic pro":    return "circle.fill"
        case "pro tools":    return "circle.fill"
        default:             return "doc.fill"
        }
    }

    private func formatColor(_ format: String?) -> Color {
        switch format?.lowercased() {
        case "ableton live": return .teal
        case "logic pro":    return .blue
        case "pro tools":    return .purple
        default:             return .secondary
        }
    }

    private func bounceFormatColor(_ format: String?) -> Color {
        switch format?.lowercased() {
        case "wav":  return Color(hex: "a8d8ea") ?? .blue
        case "mp3":  return Color(hex: "f0c987") ?? .orange
        case "aiff": return Color(hex: "c9b3e6") ?? .purple
        case "flac": return Color(hex: "a8e6cf") ?? .green
        default:     return .secondary
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func header(_ collection: AudioCollection) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let color = collection.color {
                    Circle()
                        .fill(Color(hex: color) ?? .blue)
                        .frame(width: 16, height: 16)
                }

                Text(collection.name)
                    .font(.title)
                    .fontWeight(.bold)
            }

            if let desc = collection.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                // Content type chips
                ForEach(collection.contentTypes, id: \.self) { ct in
                    Text(ct.capitalized)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(4)
                }

                if collection.hasProjects {
                    Label("\(collection.projectCount) projects", systemImage: "folder")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if collection.hasBounces {
                    Label("\(collection.bounceCount) bounces", systemImage: "waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Edit Collection Sheet

struct EditCollectionSheet: View {
    let collection: AudioCollection
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var description: String
    @State private var selectedColor: String
    @State private var selectedContentTypes: Set<CollectionContentType>

    private let colorOptions = [
        "3B82F6", "EF4444", "10B981", "F59E0B",
        "8B5CF6", "EC4899", "06B6D4", "F97316",
    ]

    init(collection: AudioCollection) {
        self.collection = collection
        _name = State(initialValue: collection.name)
        _description = State(initialValue: collection.description ?? "")
        _selectedColor = State(initialValue: collection.color ?? "3B82F6")
        let types = Set(collection.contentTypes.compactMap { CollectionContentType(rawValue: $0) })
        _selectedContentTypes = State(initialValue: types.isEmpty ? [.projects] : types)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Collection")
                .font(.title2)
                .bold()

            Form {
                TextField("Name", text: $name)
                TextField("Description", text: $description)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Content Types")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(CollectionContentType.allCases) { ct in
                            Button {
                                if selectedContentTypes.contains(ct) {
                                    if selectedContentTypes.count > 1 {
                                        selectedContentTypes.remove(ct)
                                    }
                                } else {
                                    selectedContentTypes.insert(ct)
                                }
                            } label: {
                                Label(ct.label, systemImage: ct.icon)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(selectedContentTypes.contains(ct) ? Color.blue : Color.secondary.opacity(0.1))
                                    .foregroundColor(selectedContentTypes.contains(ct) ? .white : .primary)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Color")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(colorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: selectedColor == hex ? 2 : 0)
                                )
                                .onTapGesture { selectedColor = hex }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Button("Save") {
                    Task {
                        if let token = auth.authToken {
                            let types = selectedContentTypes.map(\.rawValue)
                            await collectionService.updateCollection(
                                id: collection.id,
                                name: name,
                                description: description.isEmpty ? nil : description,
                                color: selectedColor,
                                contentTypes: types,
                                token: token
                            )
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 420)
    }
}

// MARK: - Add Projects Sheet

struct AddProjectsSheet: View {
    let collectionId: UUID
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var scanner: ScannerService
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var selectedSessionIds: Set<String> = []

    private var projects: [SessionProject] {
        let all = SessionProject.groupSessions(scanner.sessions)
        if search.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Projects to Collection")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Select projects to add")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search projects...", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            Divider().padding(.top, 8)

            // Project list
            List {
                ForEach(projects) { project in
                    HStack {
                        Image(systemName: selectedSessionIds.contains(project.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(selectedSessionIds.contains(project.id) ? .blue : .secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.name)
                                .font(.body)
                                .fontWeight(.medium)
                            Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s") - \(project.format.rawValue)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if selectedSessionIds.contains(project.id) {
                            selectedSessionIds.remove(project.id)
                        } else {
                            selectedSessionIds.insert(project.id)
                        }
                    }
                }
            }
            .listStyle(.inset)

            // Footer
            HStack {
                Text("\(selectedSessionIds.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Add to Collection") {
                    Task {
                        if let token = auth.authToken {
                            // Resolve local project group IDs to backend session UUIDs
                            let selectedProjects = projects.filter { selectedSessionIds.contains($0.id) }
                            let backendIds = await collectionService.resolveSessionIds(
                                for: selectedProjects, token: token
                            )
                            if !backendIds.isEmpty {
                                await collectionService.addProjects(
                                    collectionId: collectionId,
                                    sessionIds: backendIds,
                                    token: token
                                )
                            }
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedSessionIds.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
    }
}

// MARK: - Add Bounces Sheet

struct AddBouncesSheet: View {
    let collectionId: UUID
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var bounceService: BounceService
    @Environment(\.dismiss) private var dismiss

    @State private var search = ""
    @State private var selectedBounceIds: Set<String> = []

    private var filteredBounces: [Bounce] {
        if search.isEmpty { return bounceService.bounces }
        return bounceService.bounces.filter {
            $0.fileName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Bounces to Collection")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Select bounces to add")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search bounces...", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            Divider().padding(.top, 8)

            // Bounce list
            if bounceService.bounces.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No bounces available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Link a bounce folder and scan to find audio files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredBounces) { bounce in
                        HStack {
                            Image(systemName: selectedBounceIds.contains(bounce.id.uuidString) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(selectedBounceIds.contains(bounce.id.uuidString) ? .blue : .secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(bounce.fileName)
                                    .font(.body)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(bounce.format.uppercased())
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    if let duration = bounce.durationSeconds {
                                        let mins = Int(duration) / 60
                                        let secs = Int(duration) % 60
                                        Text(String(format: "%d:%02d", mins, secs))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(ByteCountFormatter.string(fromByteCount: Int64(bounce.fileSizeBytes), countStyle: .file))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let id = bounce.id.uuidString
                            if selectedBounceIds.contains(id) {
                                selectedBounceIds.remove(id)
                            } else {
                                selectedBounceIds.insert(id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }

            // Footer
            HStack {
                Text("\(selectedBounceIds.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Button("Add to Collection") {
                    Task {
                        if let token = auth.authToken {
                            let ids = selectedBounceIds.compactMap { UUID(uuidString: $0) }
                            if !ids.isEmpty {
                                await collectionService.addBounces(
                                    collectionId: collectionId,
                                    bounceIds: ids,
                                    token: token
                                )
                            }
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedBounceIds.isEmpty)
            }
            .padding()
        }
        .frame(width: 500, height: 500)
    }
}
