import SwiftUI

/// Detail column for the Commands tab — editor, visual builder, actions, and results preview.
struct CommandDetailView: View {
    let command: Command

    @EnvironmentObject var commandService: CommandService
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var collectionService: CollectionService
    @EnvironmentObject var auth: AuthenticationService

    @State private var commandText: String = ""
    @State private var isVisualMode = false
    @State private var editableQuery: Query
    @State private var editableActions: [CommandAction]
    @State private var result: CommandResult?
    @State private var recipeName = ""
    @State private var recipeDescription = ""
    @State private var showSaveRecipe = false
    @State private var showCreateCollection = false
    @State private var newCollectionName = ""
    @State private var newCollectionColor = "3B82F6"
    @State private var pendingCommand: Command?

    init(command: Command) {
        self.command = command
        _editableQuery = State(initialValue: command.query)
        _editableActions = State(initialValue: command.actions)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                header

                Divider()

                // Command editor
                editorSection

                // Visual builder (when toggled)
                if isVisualMode {
                    CommandVisualBuilder(
                        query: $editableQuery,
                        onQueryChanged: { syncTextFromVisual() }
                    )
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)
                }

                // Piped actions
                actionsSection

                // Results preview
                if let result {
                    resultsSection(result)
                }

                // Footer buttons
                footerActions

                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            syncFromCommand()
        }
        .onChange(of: command) { _, _ in
            syncFromCommand()
        }
        .sheet(isPresented: $showSaveRecipe) {
            saveRecipeSheet
        }
        .sheet(isPresented: $showCreateCollection) {
            createCollectionSheet
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "terminal")
                    .font(.system(size: 40))
                    .foregroundColor(.blue)
                Spacer()
            }

            if let name = command.name {
                Text(name)
                    .font(.title)
                    .fontWeight(.bold)
            } else {
                Text("Ad-hoc Command")
                    .font(.title)
                    .fontWeight(.bold)
            }

            if let desc = command.description, !desc.isEmpty {
                Text(desc)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 16) {
                Label(command.query.entityType.label, systemImage: command.query.entityType.icon)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !command.query.filters.isEmpty {
                    Label("\(command.query.filters.count) filters", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if !command.actions.isEmpty {
                    Label("\(command.actions.count) actions", systemImage: "arrow.right.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Editor

    private var editorSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Command")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()

                Picker("Mode", selection: $isVisualMode) {
                    Text("Text").tag(false)
                    Text("Visual").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                .onChange(of: isVisualMode) { _, newValue in
                    if newValue {
                        syncVisualFromText()
                    } else {
                        syncTextFromVisual()
                    }
                }
            }

            if !isVisualMode {
                TextField("Command DSL", text: $commandText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { runCommand() }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Piped Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Actions")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()

                Menu {
                    Button("Backup") { editableActions.append(.backup) }
                    Button("Create Collection...") { editableActions.append(.createCollection("New Collection")) }
                    Button("Export...") { editableActions.append(.export(format: "json")) }
                } label: {
                    Label("Add Action", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if editableActions.isEmpty {
                Text("No actions. Results will be displayed without modification.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ForEach(Array(editableActions.enumerated()), id: \.offset) { index, action in
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundColor(.blue)

                        Image(systemName: action.icon)
                            .foregroundColor(.blue)
                            .frame(width: 20)

                        Text(action.label)
                            .font(.body)

                        Spacer()

                        Button {
                            editableActions.remove(at: index)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Results Preview

    private func resultsSection(_ result: CommandResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(.blue)
                Text("Results")
                    .font(.headline)
            }

            Divider()

            // Stats summary
            HStack(spacing: 16) {
                if !result.matchedPlugins.isEmpty {
                    StatRow(label: "Plugins", value: "\(result.matchedPlugins.count)")
                }
                if !result.matchedProjects.isEmpty {
                    StatRow(label: "Projects", value: "\(result.matchedProjects.count)")
                }
                if !result.matchedBounces.isEmpty {
                    StatRow(label: "Bounces", value: "\(result.matchedBounces.count)")
                }
                if !result.matchedCollections.isEmpty {
                    StatRow(label: "Collections", value: "\(result.matchedCollections.count)")
                }
            }

            if result.isEmpty {
                Text("No matches found")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                // Entity list
                resultEntityList(result)
            }

            // Action results
            if !result.actionResults.isEmpty {
                Divider()
                ForEach(Array(result.actionResults.enumerated()), id: \.offset) { _, actionResult in
                    HStack(spacing: 6) {
                        Image(systemName: actionResult.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(actionResult.success ? .green : .red)
                            .font(.caption)
                        Text(actionResult.message)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    @ViewBuilder
    private func resultEntityList(_ result: CommandResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.matchedPlugins.prefix(20)) { plugin in
                HStack(spacing: 8) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text(plugin.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(plugin.format.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            ForEach(result.matchedProjects.prefix(20)) { project in
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text(project.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(project.format.rawValue)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            ForEach(result.matchedBounces.prefix(20)) { bounce in
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(width: 16)
                    Text(bounce.fileName)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer()
                    Text(bounce.format.uppercased())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            }

            if result.totalMatchCount > 20 {
                Text("... and \(result.totalMatchCount - 20) more")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Footer

    private var footerActions: some View {
        HStack(spacing: 12) {
            Spacer()

            Button {
                runCommand()
            } label: {
                HStack {
                    if commandService.isExecuting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Run Command")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(commandService.isExecuting)

            Button("Save as Recipe") {
                recipeName = command.name ?? ""
                recipeDescription = command.description ?? ""
                showSaveRecipe = true
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Save Recipe Sheet

    private var saveRecipeSheet: some View {
        VStack(spacing: 20) {
            Text("Save as Recipe")
                .font(.title2)
                .bold()

            Form {
                TextField("Name", text: $recipeName)
                TextField("Description", text: $recipeDescription)
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") { showSaveRecipe = false }
                    .buttonStyle(.bordered)
                Button("Save") {
                    let recipe = Command(
                        query: editableQuery,
                        actions: editableActions,
                        name: recipeName.isEmpty ? nil : recipeName,
                        description: recipeDescription.isEmpty ? nil : recipeDescription
                    )
                    Task {
                        if let token = auth.authToken {
                            await commandService.saveRecipe(recipe, token: token)
                        }
                    }
                    showSaveRecipe = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(recipeName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 400, height: 280)
    }

    // MARK: - Create Collection Sheet

    private static let colorOptions = [
        "3B82F6", "EF4444", "10B981", "F59E0B",
        "8B5CF6", "EC4899", "06B6D4", "F97316",
    ]

    private var createCollectionSheet: some View {
        VStack(spacing: 20) {
            Text("Create Collection")
                .font(.title2)
                .bold()

            Form {
                TextField("Name", text: $newCollectionName)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Color")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack(spacing: 10) {
                        ForEach(Self.colorOptions, id: \.self) { hex in
                            Circle()
                                .fill(Color(hex: hex) ?? .blue)
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .stroke(Color.primary, lineWidth: newCollectionColor == hex ? 2 : 0)
                                )
                                .onTapGesture { newCollectionColor = hex }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            if let result, !result.isEmpty {
                Text("\(result.totalMatchCount) items will be added")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack {
                Button("Cancel") {
                    showCreateCollection = false
                    pendingCommand = nil
                }
                .buttonStyle(.bordered)

                Button("Create") {
                    showCreateCollection = false
                    if let cmd = pendingCommand {
                        executeWithCollection(cmd)
                    }
                    pendingCommand = nil
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCollectionName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
        .frame(width: 440, height: 360)
    }

    // MARK: - Helpers

    /// Sync all local state from the current command and pick up pre-computed results.
    private func syncFromCommand() {
        commandText = commandService.serialize(command)
        editableQuery = command.query
        editableActions = command.actions
        // Use pre-computed result from the browser's parse+execute
        if let precomputed = commandService.lastResult {
            result = precomputed
        }
    }

    private func runCommand() {
        // If in visual mode, build command from visual state
        let command: Command
        if isVisualMode {
            command = Command(query: editableQuery, actions: editableActions)
        } else {
            guard let parsed = try? commandService.parse(commandText) else {
                commandService.lastError = "Failed to parse command"
                return
            }
            command = parsed
        }

        result = commandService.executeQueryLocally(
            command.query,
            scanner: scanner,
            bounceService: bounceService,
            collectionService: collectionService
        )

        // If any action is createCollection, prompt the user first
        if let collectAction = command.actions.first(where: {
            if case .createCollection = $0 { return true }
            return false
        }), case .createCollection(let name) = collectAction {
            newCollectionName = name
            newCollectionColor = "3B82F6"
            pendingCommand = command
            showCreateCollection = true
            return
        }

        // Execute non-collection actions immediately
        guard let token = auth.authToken else { return }
        if !command.actions.isEmpty {
            Task {
                let actionResults = await commandService.executeActions(
                    command.actions,
                    on: result!,
                    collectionService: collectionService,
                    token: token
                )
                result?.actionResults = actionResults
            }
        }
    }

    /// Execute a command after the user has confirmed collection name/color via the sheet.
    private func executeWithCollection(_ command: Command) {
        guard let token = auth.authToken else { return }
        guard let currentResult = result else { return }

        Task {
            // Create the collection with the user's chosen name and color
            let created = await collectionService.createCollection(
                name: newCollectionName,
                description: nil,
                color: newCollectionColor,
                contentTypes: commandService.determineContentTypes(from: currentResult),
                token: token
            )

            var actionResults: [ActionResult] = []

            if let collection = created {
                actionResults.append(ActionResult(
                    action: .createCollection(newCollectionName),
                    success: true,
                    message: "Created collection \"\(newCollectionName)\""
                ))

                // Add matched items to the new collection
                if !currentResult.matchedProjects.isEmpty {
                    let sessionIds = await collectionService.resolveSessionIds(for: currentResult.matchedProjects, token: token)
                    if !sessionIds.isEmpty {
                        await collectionService.addProjects(collectionId: collection.id, sessionIds: sessionIds, token: token)
                    }
                }
                if !currentResult.matchedBounces.isEmpty {
                    let bounceIds = currentResult.matchedBounces.map(\.id)
                    await collectionService.addBounces(collectionId: collection.id, bounceIds: bounceIds, token: token)
                }

                actionResults.append(ActionResult(
                    action: .addToCollection(collection.id),
                    success: true,
                    message: "Added \(currentResult.totalMatchCount) items to \"\(newCollectionName)\""
                ))
            } else {
                actionResults.append(ActionResult(
                    action: .createCollection(newCollectionName),
                    success: false,
                    message: "Failed to create collection"
                ))
            }

            // Execute remaining non-collection actions
            let otherActions = command.actions.filter {
                if case .createCollection = $0 { return false }
                return true
            }
            if !otherActions.isEmpty {
                let otherResults = await commandService.executeActions(
                    otherActions,
                    on: currentResult,
                    collectionService: collectionService,
                    token: token
                )
                actionResults.append(contentsOf: otherResults)
            }

            result?.actionResults = actionResults
        }
    }

    private func syncTextFromVisual() {
        let cmd = Command(query: editableQuery, actions: editableActions)
        commandText = commandService.serialize(cmd)
    }

    private func syncVisualFromText() {
        if let parsed = try? commandService.parse(commandText) {
            editableQuery = parsed.query
            editableActions = parsed.actions
        }
    }
}
