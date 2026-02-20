import SwiftUI

/// Content column for the Commands tab — command bar, quick suggestions, recipes, and recents.
struct CommandBrowserView: View {
    @Binding var selectedCommand: Command?

    @EnvironmentObject var commandService: CommandService
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService

    @State private var commandText = ""
    @State private var isVisualMode = false

    var body: some View {
        VStack(spacing: 0) {
            // Command bar
            commandBar

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Quick commands
                    quickCommandsSection

                    // Saved recipes
                    recipesSection

                    // Recent commands
                    recentsSection
                }
                .padding()
            }
        }
        .navigationTitle("Commands")
        .task {
            if let token = auth.authToken {
                await commandService.fetchRecipes(token: token)
            }
        }
    }

    // MARK: - Command Bar

    private var commandBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)

                TextField("Type a command... (e.g. select plugins where format:vst3)", text: $commandText)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit {
                        runCurrentCommand()
                    }

                if !commandText.isEmpty {
                    Button {
                        commandText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isVisualMode.toggle()
                } label: {
                    Image(systemName: isVisualMode ? "text.cursor" : "slider.horizontal.3")
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help(isVisualMode ? "Switch to Text Mode" : "Switch to Visual Builder")

                Button("Run") {
                    runCurrentCommand()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(commandText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(10)

            if let error = commandService.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
    }

    // MARK: - Quick Commands

    private var quickCommandsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Quick Commands")
                .font(.headline)
                .foregroundColor(.secondary)

            let suggestions = commandService.generateSuggestions(
                scanner: scanner,
                bounceService: bounceService
            )

            if suggestions.isEmpty {
                Text("Scan your system to see contextual suggestions")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(suggestions, id: \.self) { suggestion in
                        Button {
                            commandText = suggestion
                        } label: {
                            Text(suggestion)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Saved Recipes

    private var recipesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Saved Recipes")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(commandService.recipes.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if commandService.recipes.isEmpty {
                Text("No saved recipes yet. Run a command and save it as a recipe.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(commandService.recipes) { recipe in
                    recipeRow(recipe)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    private func recipeRow(_ recipe: Command) -> some View {
        Button {
            selectedCommand = recipe
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "doc.text")
                    .foregroundColor(.blue)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name ?? "Untitled Recipe")
                        .font(.body)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let desc = recipe.description, !desc.isEmpty {
                            Text(desc)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if let count = recipe.lastResultCount {
                            Text("\(count) matches")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        if let date = recipe.lastRunAt {
                            Text(date, style: .relative)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Recent Commands

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent")
                .font(.headline)
                .foregroundColor(.secondary)

            if commandService.recentCommands.isEmpty {
                Text("No recent commands")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(commandService.recentCommands) { command in
                    Button {
                        commandText = commandService.serialize(command)
                        selectedCommand = command
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            Text(commandService.serialize(command))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.primary)
                                .lineLimit(1)

                            Spacer()

                            if let count = command.lastResultCount {
                                Text("\(count)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Actions

    private func runCurrentCommand() {
        guard !commandText.trimmingCharacters(in: .whitespaces).isEmpty else { return }

        // Parse and select the command to show in detail
        do {
            let command = try commandService.parse(commandText)
            selectedCommand = command
        } catch {
            commandService.lastError = error.localizedDescription
        }
    }
}

// MARK: - Flow Layout Helper

/// Simple horizontal wrapping layout for suggestion pills.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)

        for (index, subview) in subviews.enumerated() {
            guard index < result.positions.count else { break }
            let position = result.positions[index]
            subview.place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
