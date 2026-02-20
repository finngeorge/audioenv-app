import SwiftUI

/// Rich collection content builder following the BackupScopeSelector pattern.
struct CollectionBuilderPopup: View {
    let collectionId: UUID

    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var patternService: PatternService
    @EnvironmentObject var commandService: CommandService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var sourceType: SourceType = .manual
    @State private var selectedProjectIds: Set<String> = []
    @State private var selectedBounceIds: Set<UUID> = []
    @State private var query = Query(entityType: .projects)
    @State private var selectedPatternId: UUID?
    @State private var queryResult: CommandResult?
    @State private var showPatternBuilder = false
    @State private var projectSearch = ""
    @State private var bounceSearch = ""

    enum SourceType: String, CaseIterable, Identifiable {
        case manual = "Manual Pick"
        case query = "Query-Based"
        case pattern = "Pattern-Based"
        case smart = "Smart (Auto-Update)"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .manual: return "hand.tap"
            case .query: return "magnifyingglass"
            case .pattern: return "textformat.abc"
            case .smart: return "sparkles"
            }
        }

        var description: String {
            switch self {
            case .manual: return "Browse and select items individually"
            case .query: return "Use a query to find matching items"
            case .pattern: return "Match bounces by naming pattern"
            case .smart: return "Auto-updates when new items match"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Add Content")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Choose how to add items to this collection")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.05))

            ScrollView {
                VStack(spacing: 20) {
                    // Source type picker
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Source Type")
                            .font(.headline)

                        ForEach(SourceType.allCases) { type in
                            sourceTypeButton(type)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)

                    // Type-specific options
                    sourceOptionsView()
                        .padding()
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(12)

                    // Stats preview
                    if let stats = computeStats() {
                        statsPreview(stats)
                            .padding()
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(12)
                    }
                }
                .padding()
            }

            // Footer actions
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Add to Collection") {
                    addContent()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canAdd)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
        }
        .frame(width: 700, height: 600)
        .sheet(isPresented: $showPatternBuilder) {
            PatternBuilderView()
        }
    }

    // MARK: - Source Type Button

    private func sourceTypeButton(_ type: SourceType) -> some View {
        Button(action: {
            sourceType = type
            queryResult = nil
        }) {
            HStack(spacing: 12) {
                Image(systemName: type.icon)
                    .font(.title3)
                    .foregroundColor(sourceType == type ? .white : .blue)
                    .frame(width: 30)

                VStack(alignment: .leading, spacing: 4) {
                    Text(type.rawValue)
                        .font(.headline)
                        .foregroundColor(sourceType == type ? .white : .primary)

                    Text(type.description)
                        .font(.caption)
                        .foregroundColor(sourceType == type ? .white.opacity(0.9) : .secondary)
                }

                Spacer()

                if sourceType == type {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.white)
                }
            }
            .padding()
            .background(sourceType == type ? Color.blue : Color.clear)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Source-Specific Options

    @ViewBuilder
    private func sourceOptionsView() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.headline)

            switch sourceType {
            case .manual:
                manualPickOptions()
            case .query:
                queryOptions()
            case .pattern:
                patternOptions()
            case .smart:
                smartOptions()
            }
        }
    }

    // MARK: - Manual Pick

    @ViewBuilder
    private func manualPickOptions() -> some View {
        // Projects section
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Projects")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(selectedProjectIds.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            TextField("Search projects...", text: $projectSearch)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let projects = filteredProjects
                    ForEach(projects.prefix(30)) { project in
                        Button {
                            if selectedProjectIds.contains(project.id) {
                                selectedProjectIds.remove(project.id)
                            } else {
                                selectedProjectIds.insert(project.id)
                            }
                        } label: {
                            Text(project.name)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedProjectIds.contains(project.id) ? Color.blue : Color.secondary.opacity(0.1))
                                .foregroundColor(selectedProjectIds.contains(project.id) ? .white : .primary)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 35)
        }

        // Bounces section
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bounces")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("\(selectedBounceIds.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            TextField("Search bounces...", text: $bounceSearch)
                .textFieldStyle(.roundedBorder)
                .font(.caption)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    let bounces = filteredBounces
                    ForEach(bounces.prefix(30)) { bounce in
                        Button {
                            if selectedBounceIds.contains(bounce.id) {
                                selectedBounceIds.remove(bounce.id)
                            } else {
                                selectedBounceIds.insert(bounce.id)
                            }
                        } label: {
                            Text(bounce.fileName)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(selectedBounceIds.contains(bounce.id) ? Color.cyan : Color.secondary.opacity(0.1))
                                .foregroundColor(selectedBounceIds.contains(bounce.id) ? .white : .primary)
                                .cornerRadius(8)
                                .lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 35)
        }
    }

    // MARK: - Query Options

    @ViewBuilder
    private func queryOptions() -> some View {
        CommandVisualBuilder(query: $query) {
            // Auto-execute query for live preview
            queryResult = commandService.executeQueryLocally(
                query,
                scanner: scanner,
                bounceService: bounceService,
                collectionService: collectionService
            )
        }

        if let result = queryResult {
            Text("\(result.totalMatchCount) items match this query")
                .font(.caption)
                .foregroundColor(.blue)
                .padding(.top, 4)
        }
    }

    // MARK: - Pattern Options

    @ViewBuilder
    private func patternOptions() -> some View {
        if patternService.patterns.isEmpty {
            VStack(spacing: 12) {
                Text("No patterns defined yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Button("Create Pattern") {
                    showPatternBuilder = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else {
            Picker("Select Pattern", selection: $selectedPatternId) {
                Text("Choose a pattern...").tag(nil as UUID?)
                ForEach(patternService.patterns) { pattern in
                    Text("\(pattern.name) — \(pattern.patternString)").tag(pattern.id as UUID?)
                }
            }
            .onChange(of: selectedPatternId) { _, newValue in
                if let id = newValue,
                   let pattern = patternService.patterns.first(where: { $0.id == id }) {
                    let matches = patternService.applyPatternToBounces(pattern, bounces: bounceService.bounces)
                    selectedBounceIds = Set(matches.map { $0.0.id })
                }
            }

            Button("Create New Pattern") {
                showPatternBuilder = true
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    // MARK: - Smart Options

    @ViewBuilder
    private func smartOptions() -> some View {
        CommandVisualBuilder(query: $query) {
            queryResult = commandService.executeQueryLocally(
                query,
                scanner: scanner,
                bounceService: bounceService,
                collectionService: collectionService
            )
        }

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .foregroundColor(.purple)
                Text("Smart Collection")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text("This collection will automatically update when new items match the query. Items are added during sync.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.purple.opacity(0.05))
        .cornerRadius(8)

        if let result = queryResult {
            Text("\(result.totalMatchCount) items currently match")
                .font(.caption)
                .foregroundColor(.purple)
        }
    }

    // MARK: - Stats Preview

    private func statsPreview(_ stats: ContentStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Preview")
                    .font(.headline)
            }

            Divider()

            if stats.totalCount == 0 {
                Text("No items selected")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                VStack(spacing: 8) {
                    if stats.projectCount > 0 {
                        StatRow(label: "Projects", value: "\(stats.projectCount)")
                    }
                    if stats.bounceCount > 0 {
                        StatRow(label: "Bounces", value: "\(stats.bounceCount)")
                    }
                    if !stats.formatBreakdown.isEmpty {
                        Divider()
                        ForEach(Array(stats.formatBreakdown.sorted(by: { $0.key < $1.key })), id: \.key) { format, count in
                            StatRow(label: format.uppercased(), value: "\(count)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private var filteredProjects: [SessionProject] {
        let all = SessionProject.groupSessions(scanner.sessions)
        if projectSearch.isEmpty { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(projectSearch) }
    }

    private var filteredBounces: [Bounce] {
        if bounceSearch.isEmpty { return bounceService.bounces }
        return bounceService.bounces.filter { $0.fileName.localizedCaseInsensitiveContains(bounceSearch) }
    }

    private var canAdd: Bool {
        switch sourceType {
        case .manual:
            return !selectedProjectIds.isEmpty || !selectedBounceIds.isEmpty
        case .query, .smart:
            return queryResult != nil && !queryResult!.isEmpty
        case .pattern:
            return !selectedBounceIds.isEmpty
        }
    }

    private func computeStats() -> ContentStats? {
        switch sourceType {
        case .manual:
            guard !selectedProjectIds.isEmpty || !selectedBounceIds.isEmpty else { return nil }
            let selectedBouncesList = bounceService.bounces.filter { selectedBounceIds.contains($0.id) }
            let formatBreakdown = Dictionary(grouping: selectedBouncesList, by: { $0.format })
                .mapValues(\.count)
            return ContentStats(
                projectCount: selectedProjectIds.count,
                bounceCount: selectedBounceIds.count,
                formatBreakdown: formatBreakdown
            )

        case .query, .smart:
            guard let result = queryResult else { return nil }
            let formatBreakdown = Dictionary(grouping: result.matchedBounces, by: { $0.format })
                .mapValues(\.count)
            return ContentStats(
                projectCount: result.matchedProjects.count,
                bounceCount: result.matchedBounces.count,
                formatBreakdown: formatBreakdown
            )

        case .pattern:
            let selectedBouncesList = bounceService.bounces.filter { selectedBounceIds.contains($0.id) }
            let formatBreakdown = Dictionary(grouping: selectedBouncesList, by: { $0.format })
                .mapValues(\.count)
            return ContentStats(
                projectCount: 0,
                bounceCount: selectedBounceIds.count,
                formatBreakdown: formatBreakdown
            )
        }
    }

    private func addContent() {
        guard let token = auth.authToken else { return }

        Task {
            switch sourceType {
            case .manual:
                // Add selected projects
                if !selectedProjectIds.isEmpty {
                    let projects = SessionProject.groupSessions(scanner.sessions)
                        .filter { selectedProjectIds.contains($0.id) }
                    let backendIds = await collectionService.resolveSessionIds(for: projects, token: token)
                    if !backendIds.isEmpty {
                        await collectionService.addProjects(collectionId: collectionId, sessionIds: backendIds, token: token)
                    }
                }
                // Add selected bounces
                if !selectedBounceIds.isEmpty {
                    await collectionService.addBounces(collectionId: collectionId, bounceIds: Array(selectedBounceIds), token: token)
                }

            case .query:
                if let result = queryResult {
                    await addResultToCollection(result, token: token)
                }

            case .pattern:
                if !selectedBounceIds.isEmpty {
                    await collectionService.addBounces(collectionId: collectionId, bounceIds: Array(selectedBounceIds), token: token)
                }

            case .smart:
                if let result = queryResult {
                    await addResultToCollection(result, token: token)
                    // TODO: Save smart collection rule via API
                }
            }

            // Refresh collections
            await collectionService.fetchCollections(token: token)
            dismiss()
        }
    }

    private func addResultToCollection(_ result: CommandResult, token: String) async {
        if !result.matchedProjects.isEmpty {
            let backendIds = await collectionService.resolveSessionIds(for: result.matchedProjects, token: token)
            if !backendIds.isEmpty {
                await collectionService.addProjects(collectionId: collectionId, sessionIds: backendIds, token: token)
            }
        }
        if !result.matchedBounces.isEmpty {
            let bounceIds = result.matchedBounces.map(\.id)
            await collectionService.addBounces(collectionId: collectionId, bounceIds: bounceIds, token: token)
        }
    }
}

// MARK: - Content Stats

struct ContentStats {
    let projectCount: Int
    let bounceCount: Int
    let formatBreakdown: [String: Int]

    var totalCount: Int { projectCount + bounceCount }
}
