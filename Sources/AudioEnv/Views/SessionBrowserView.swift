import SwiftUI

/// Lists every DAW project discovered on the system.
/// Selecting a row drives the detail column via the *selectedProject* binding.
struct SessionBrowserView: View {
    @EnvironmentObject var scanner: ScannerService

    @Binding var selectedProject:    SessionProject?
    @Binding var formatFilter: SessionFormat?
    @State   private var search       = ""
    @State   private var projects: [SessionProject] = []
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // ── Search bar + export ──────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)

                Menu {
                    Button(action: { self.exportProjects(format: .csv) }) {
                        Label("Export as CSV", systemImage: "doc.text")
                    }
                    Button(action: { self.exportProjects(format: .json) }) {
                        Label("Export as JSON", systemImage: "doc.badge.gearshape")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("Export project list")
            }
            .padding([.leading, .trailing])

            // ── Format picker ─────────────────────────────────
            Picker("Format", selection: $formatFilter) {
                Text("All").tag(nil as SessionFormat?)
                ForEach(SessionFormat.allCases) { f in
                    Text(shortName(for: f)).tag(f as SessionFormat?)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 4)

            Divider().padding(.top, 2)

            // ── Session list ──────────────────────────────────
            if projects.isEmpty {
                sessionEmptyState()
            } else {
                List(selection: $selectedProject) {
                    ForEach(projects) { project in
                        ProjectRow(project: project)
                            .tag(project)
                    }
                }
                .listStyle(.inset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            isSearchFocused = true
        }
        .onChange(of: search) { _, _ in refilter() }
        .onChange(of: formatFilter) { _, _ in refilter() }
        .onChange(of: scanner.sessions) { _, _ in refilter() }
        .onAppear { refilter() }
    }

    private func refilter() {
        let q = search.lowercased()
        let filtered = scanner.sessions
            .filter { formatFilter == nil || $0.format == formatFilter }
            .filter { q.isEmpty || $0.projectDisplayName.lowercased().contains(q) || $0.name.lowercased().contains(q) }
        projects = SessionProject.groupSessions(filtered)
    }

    private func sessionEmptyState() -> some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Projects")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(scanner.isScanning
                 ? "Scanning…"
                 : "No .als, .logicpro, or .ptx files found.\nTry adding custom search paths.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortName(for format: SessionFormat) -> String {
        switch format {
        case .ableton:  return "Ableton"
        case .logic:    return "Logic"
        case .proTools: return "Pro Tools"
        }
    }

    // MARK: - Export

    enum ExportFormat {
        case csv, json
    }

    private func exportProjects(format: ExportFormat) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        savePanel.nameFieldStringValue = "projects.\(format == .csv ? "csv" : "json")"
        savePanel.title = "Export Project List"
        savePanel.message = "Choose where to save your project list"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            let content: String
            switch format {
            case .csv:
                content = generateCSV(projects: projects)
            case .json:
                content = generateJSON(projects: projects)
            }

            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func generateCSV(projects: [SessionProject]) -> String {
        var csv = "Name,Format,Sessions,Latest Date,Path\n"
        for project in projects {
            let name = escapeCSV(project.name)
            let format = project.format.rawValue
            let sessions = "\(project.sessions.count)"
            let date = ISO8601DateFormatter().string(from: project.latestDate)
            let path = escapeCSV(project.sessions.first?.path ?? "")
            csv += "\(name),\(format),\(sessions),\(date),\(path)\n"
        }
        return csv
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func generateJSON(projects: [SessionProject]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let exportData = projects.map { project in
            [
                "name": project.name,
                "format": project.format.rawValue,
                "sessions": "\(project.sessions.count)",
                "latestDate": ISO8601DateFormatter().string(from: project.latestDate),
                "path": project.sessions.first?.path ?? ""
            ]
        }

        guard let jsonData = try? encoder.encode(exportData),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "[]"
        }

        return jsonString
    }
}

// MARK: – Project row

private struct ProjectRow: View {
    let project: SessionProject
    @EnvironmentObject var scanner: ScannerService

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle  = .medium
        f.timeStyle  = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // Standalone Logic bundles use session-level icon instead of folder
                if project.isStandaloneBundle,
                   let sessionIcon = DAWIconLoader.sessionIcon(for: project.format) {
                    Image(nsImage: sessionIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .cornerRadius(4)
                } else if let dawIcon = DAWIconLoader.icon(for: project.format) {
                    Image(nsImage: dawIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .cornerRadius(4)
                } else {
                    Image(systemName: formatSymbol)
                        .font(.system(size: 28))
                        .foregroundColor(fmtColor)
                        .frame(width: 32, height: 32)
                }

                Text(project.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                parsedBadge()
                Text(project.format.rawValue)
                    .font(.caption)
                    .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .background(fmtColor.opacity(0.15))
                    .foregroundColor(fmtColor)
                    .cornerRadius(4)
            }

            HStack(spacing: 12) {
                Text(Self.dateFormatter.string(from: project.latestDate))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(project.sessions.count) session\(project.sessions.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if project.backups.count > 0 {
                    Text("\(project.backups.count) auto backup\(project.backups.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let summary = pluginSummary {
                Text(summary)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.vertical, 2)
    }

    private var fmtColor: Color {
        ColorTokens.shared.sessionFormatColor(project.format)
    }

    private var formatSymbol: String {
        switch project.format {
        case .ableton:  return "music.note.list"
        case .logic:    return "waveform"
        case .proTools: return "gearshape.2"
        }
    }

    private func parsedBadge() -> some View {
        // Check if the newest session (by date) is parsed, using live scanner data
        let liveSessionsByPath = Dictionary(
            scanner.sessions.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let newest = project.sessions
            .sorted { $0.modifiedDate > $1.modifiedDate }
            .first
        let isParsed: Bool
        if let newest, let live = liveSessionsByPath[newest.path] {
            isParsed = live.project != nil
        } else {
            isParsed = newest?.project != nil
        }
        let text = isParsed ? "Parsed" : "Unparsed"
        let color = isParsed ? Color.green : Color.yellow
        return Text(text)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private var pluginSummary: String? {
        let liveSessionsByPath = Dictionary(
            scanner.sessions.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var pluginSet: [String] = []
        for session in project.sessions {
            let live = liveSessionsByPath[session.path] ?? session
            switch live.project {
            case .ableton(let p):
                pluginSet.append(contentsOf: p.usedPlugins)
            case .logic(let p):
                pluginSet.append(contentsOf: p.trackPlugins.values.flatMap { $0 })
            default:
                break
            }
        }
        guard !pluginSet.isEmpty else {
            // Only show "none detected" for formats we can parse plugins from
            if project.format == .ableton || project.format == .logic {
                return "Plugins: none detected"
            }
            return nil
        }
        let unique = Array(Set(pluginSet)).sorted()
        let top = unique.prefix(3)
        let extra = unique.count - top.count
        if extra > 0 {
            return "Plugins: \(top.joined(separator: ", ")) +\(extra) more"
        }
        return "Plugins: \(top.joined(separator: ", "))"
    }
}
