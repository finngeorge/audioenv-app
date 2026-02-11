import SwiftUI

/// View for sharing a project's plugin requirements with others
struct ProjectShareView: View {
    let session: AudioSession

    @State private var shareURL: String?
    @State private var isSharing = false
    @State private var showCopiedConfirmation = false
    @State private var errorMessage: String?

    @Environment(\.dismiss) private var dismiss

    var requiredPlugins: [RequiredPlugin] {
        extractRequiredPlugins(from: session)
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading) {
                    Text("Share Project Requirements")
                        .font(.title2)
                        .bold()
                    Text(session.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            Divider()

            // Required Plugins List
            GroupBox(label: Label("Required Plugins (\(requiredPlugins.count))", systemImage: "waveform")) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(requiredPlugins) { plugin in
                            HStack {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundStyle(formatColor(plugin.format))
                                VStack(alignment: .leading) {
                                    Text(plugin.name)
                                        .font(.body)
                                    Text(plugin.format.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 300)
            }

            // Share Actions
            if shareURL == nil {
                Button {
                    Task {
                        await shareProject()
                    }
                } label: {
                    HStack {
                        Image(systemName: "link.circle.fill")
                        Text("Generate Share Link")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isSharing || requiredPlugins.isEmpty)

                if isSharing {
                    ProgressView()
                        .padding()
                }
            } else {
                VStack(spacing: 12) {
                    HStack {
                        Text(shareURL!)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding()
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)

                        Button {
                            copyToClipboard()
                        } label: {
                            Image(systemName: showCopiedConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                                .foregroundStyle(showCopiedConfirmation ? .green : .blue)
                        }
                        .buttonStyle(.borderless)
                    }

                    Text("Anyone with this link can check if they have the required plugins")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)

                    HStack(spacing: 12) {
                        Button("Copy Link") {
                            copyToClipboard()
                        }
                        .buttonStyle(.bordered)

                        ShareLink(
                            item: URL(string: shareURL!)!,
                            subject: Text("Check Plugin Compatibility"),
                            message: Text("Check if you have the plugins needed for '\(session.name)'")
                        )
                        .buttonStyle(.bordered)
                    }
                }
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            Spacer()
        }
        .padding()
        .frame(width: 500, height: 600)
    }

    // MARK: - Helper Methods

    private func extractRequiredPlugins(from session: AudioSession) -> [RequiredPlugin] {
        guard let project = session.project else { return [] }

        switch project {
        case .ableton(let abletonProject):
            return abletonProject.usedPlugins.map { pluginName in
                RequiredPlugin(
                    name: pluginName,
                    format: .vst3, // Would need to detect actual format
                    bundleID: nil
                )
            }
        case .logic(let logicProject):
            // Logic parsing is limited, so we don't have plugin info yet
            return []
        case .proTools(let proToolsProject):
            // Pro Tools parsing is limited
            return []
        }
    }

    private func shareProject() async {
        isSharing = true
        errorMessage = nil

        do {
            // Call backend API to create share link
            let response = try await createShareLink(
                projectName: session.name,
                format: session.format.rawValue,
                requiredPlugins: requiredPlugins
            )

            shareURL = response.shareURL
        } catch {
            errorMessage = "Failed to create share link: \(error.localizedDescription)"
        }

        isSharing = false
    }

    private func copyToClipboard() {
        guard let url = shareURL else { return }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url, forType: .string)

        showCopiedConfirmation = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            showCopiedConfirmation = false
        }
    }

    private func formatColor(_ format: PluginFormat) -> Color {
        switch format {
        case .au: return .blue
        case .vst: return .green
        case .vst3: return .orange
        case .aax: return .purple
        }
    }

    // MARK: - API Call (Mock)

    private func createShareLink(projectName: String, format: String, requiredPlugins: [RequiredPlugin]) async throws -> ShareResponse {
        // This would call your actual backend API
        // For now, returning mock data

        // Simulate network delay
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let token = UUID().uuidString.prefix(12)
        return ShareResponse(
            shareToken: String(token),
            shareURL: "https://audioenv.app/check/\(token)",
            expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 7) // 7 days
        )
    }
}

// MARK: - Plugin Compatibility Check View

struct PluginCompatibilityView: View {
    let shareToken: String

    @State private var projectInfo: SharedProjectInfo?
    @State private var userPlugins: [AudioPlugin] = []
    @State private var isLoading = true

    var compatibilityScore: Double {
        guard let info = projectInfo else { return 0 }
        let total = info.requiredPlugins.count
        guard total > 0 else { return 0 }

        let matches = info.requiredPlugins.filter { required in
            userPlugins.contains { userPlugin in
                userPlugin.name.lowercased().contains(required.name.lowercased())
            }
        }.count

        return Double(matches) / Double(total)
    }

    var body: some View {
        VStack(spacing: 20) {
            if isLoading {
                ProgressView("Loading project info...")
                    .padding()
            } else if let info = projectInfo {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: compatibilityScore == 1.0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(compatibilityScore == 1.0 ? .green : .orange)

                    Text(info.projectName)
                        .font(.title)
                        .bold()

                    Text("\(info.format) Project")
                        .font(.headline)
                        .foregroundStyle(.secondary)

                    // Compatibility Score
                    VStack(spacing: 4) {
                        Text("\(Int(compatibilityScore * 100))% Compatible")
                            .font(.title2)
                            .bold()
                            .foregroundStyle(compatibilityScore == 1.0 ? .green : .orange)

                        ProgressView(value: compatibilityScore)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                    }
                    .padding(.top)
                }

                Divider()

                // Plugin List
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(info.requiredPlugins) { plugin in
                            let hasPlugin = userPlugins.contains { $0.name.lowercased().contains(plugin.name.lowercased()) }

                            HStack {
                                Image(systemName: hasPlugin ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundStyle(hasPlugin ? .green : .red)

                                VStack(alignment: .leading) {
                                    Text(plugin.name)
                                        .font(.body)
                                    Text(plugin.format.rawValue)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                if !hasPlugin {
                                    Text("Missing")
                                        .font(.caption)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.red.opacity(0.2))
                                        .cornerRadius(4)
                                }
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                    .padding()
                }
            }
        }
        .padding()
        .task {
            await loadProjectInfo()
        }
    }

    private func loadProjectInfo() async {
        // Would fetch from API and compare against local plugins
        isLoading = false
    }
}

// MARK: - Models

struct RequiredPlugin: Identifiable, Codable {
    var id: String { name + format.rawValue }
    let name: String
    let format: PluginFormat
    let bundleID: String?
}

struct ShareResponse: Codable {
    let shareToken: String
    let shareURL: String
    let expiresAt: Date
}

struct SharedProjectInfo: Codable {
    let projectName: String
    let format: String
    let requiredPlugins: [RequiredPlugin]
}

#Preview("Share View") {
    ProjectShareView(
        session: AudioSession(
            name: "My Big Mix.als",
            path: "/path/to/project.als",
            format: .ableton,
            modifiedDate: Date(),
            fileSize: 1024000,
            project: nil
        )
    )
}

#Preview("Compatibility View") {
    PluginCompatibilityView(shareToken: "abc123")
        .frame(width: 600, height: 700)
}
