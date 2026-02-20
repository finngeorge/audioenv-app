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
            commandText = commandService.serialize(command)
        }
        .sheet(isPresented: $showSaveRecipe) {
            saveRecipeSheet
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

    // MARK: - Helpers

    private func runCommand() {
        guard let token = auth.authToken else { return }

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

        // Execute actions if any
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
