import SwiftUI

/// Settings view for configuring where web-uploaded projects land on disk.
struct WebTransfersSettingsView: View {
    @State private var abletonPath = WebDownloadPaths.path(for: .ableton) ?? ""
    @State private var logicPath = WebDownloadPaths.path(for: .logic) ?? ""
    @State private var proToolsPath = WebDownloadPaths.path(for: .proTools) ?? ""
    @State private var alwaysAsk = !UserDefaults.standard.bool(forKey: WebDownloadPaths.skipPromptKey)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Web Transfers")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Configure where projects sent from the web app are saved")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Behavior
                VStack(alignment: .leading, spacing: 12) {
                    Text("Behavior")
                        .font(.headline)

                    Toggle("Always ask where to save", isOn: $alwaysAsk)
                        .onChange(of: alwaysAsk) { _, newValue in
                            UserDefaults.standard.set(!newValue, forKey: WebDownloadPaths.skipPromptKey)
                        }

                    Text("When disabled, projects are saved directly to the configured paths below without prompting.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Per-DAW paths
                VStack(alignment: .leading, spacing: 16) {
                    Text("Default Save Locations")
                        .font(.headline)

                    dawPathRow(label: "Ableton Live", path: $abletonPath, format: .ableton)
                    dawPathRow(label: "Logic Pro", path: $logicPath, format: .logic)
                    dawPathRow(label: "Pro Tools", path: $proToolsPath, format: .proTools)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Clear all
                Button(role: .destructive) {
                    WebDownloadPaths.clearAll()
                    abletonPath = ""
                    logicPath = ""
                    proToolsPath = ""
                    alwaysAsk = true
                } label: {
                    HStack {
                        Image(systemName: "trash")
                        Text("Reset All Paths")
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)

                Spacer()
            }
            .padding(20)
        }
        .navigationTitle("Web Transfers")
    }

    private func dawPathRow(label: String, path: Binding<String>, format: SessionFormat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.subheadline)
                .fontWeight(.medium)

            HStack(spacing: 8) {
                Text(path.wrappedValue.isEmpty ? "Not set" : abbreviatePath(path.wrappedValue))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(path.wrappedValue.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.message = "Choose where to save \(label) projects from the web"
                    if !path.wrappedValue.isEmpty {
                        panel.directoryURL = URL(fileURLWithPath: path.wrappedValue)
                    }
                    if panel.runModal() == .OK, let url = panel.url {
                        path.wrappedValue = url.path
                        WebDownloadPaths.setPath(url.path, for: format)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if !path.wrappedValue.isEmpty {
                    Button {
                        path.wrappedValue = ""
                        WebDownloadPaths.setPath(nil, for: format)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Persistent storage for per-DAW download paths

enum WebDownloadPaths {
    static let skipPromptKey = "webTransfers.skipPrompt"

    private static func key(for format: SessionFormat) -> String {
        "webTransfers.path.\(format.rawValue)"
    }

    static func path(for format: SessionFormat) -> String? {
        let val = UserDefaults.standard.string(forKey: key(for: format))
        return (val?.isEmpty == true) ? nil : val
    }

    static func setPath(_ path: String?, for format: SessionFormat) {
        UserDefaults.standard.set(path, forKey: key(for: format))
    }

    static var skipPrompt: Bool {
        UserDefaults.standard.bool(forKey: skipPromptKey)
    }

    static func clearAll() {
        for format in SessionFormat.allCases {
            UserDefaults.standard.removeObject(forKey: key(for: format))
        }
        UserDefaults.standard.removeObject(forKey: skipPromptKey)
    }

    /// Infer the best directory for a DAW type based on existing scanned sessions.
    /// Returns the most common parent directory for sessions of this format.
    static func inferPath(for format: SessionFormat, from sessions: [AudioSession]) -> String? {
        let matching = sessions.filter { $0.format == format && !$0.isBackup }
        guard !matching.isEmpty else { return nil }

        // Count parent directories
        var dirCounts: [String: Int] = [:]
        for session in matching {
            let dir = (session.path as NSString).deletingLastPathComponent
            // Walk up to find a reasonable project root (skip deep nesting)
            var candidate = dir
            // For Ableton/Pro Tools, the session is inside a project folder — go one level up
            if format == .ableton || format == .proTools {
                candidate = (candidate as NSString).deletingLastPathComponent
            }
            dirCounts[candidate, default: 0] += 1
        }

        // Find the most common directory
        guard let (bestDir, _) = dirCounts.max(by: { $0.value < $1.value }) else { return nil }
        return bestDir
    }
}
