import SwiftUI

/// Lists every DAW project discovered on the system.
/// Selecting a row drives the detail column via the *selectedProject* binding.
struct SessionBrowserView: View {
    @EnvironmentObject var scanner: ScannerService

    @Binding var selectedProject:    SessionProject?
    @Binding var formatFilter: SessionFormat?
    @State   private var search       = ""
    @FocusState private var isSearchFocused: Bool

    private var projects: [SessionProject] {
        let filtered = scanner.sessions
            .filter { formatFilter == nil || $0.format == formatFilter }
            .filter { search.isEmpty || $0.projectDisplayName.lowercased().contains(search.lowercased()) || $0.name.lowercased().contains(search.lowercased()) }

        return SessionProject.groupSessions(filtered)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Search bar ────────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)
            }
            .padding([.leading, .trailing])

            // ── Format picker ─────────────────────────────────
            HStack(spacing: 10) {
                Picker("Format", selection: $formatFilter) {
                    Text("All").tag(nil as SessionFormat?)
                    ForEach(SessionFormat.allCases) { f in
                        Text(shortName(for: f)).tag(f as SessionFormat?)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)

                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 2)

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
}

// MARK: – Project row

private struct ProjectRow: View {
    let project: SessionProject

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle  = .medium
        f.timeStyle  = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                // DAW icon only (no folder icon)
                if let dawIcon = DAWIconLoader.icon(for: project.format) {
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
                    Text("\(project.backups.count) backup\(project.backups.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let summary = usedPluginsSummary() {
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
        switch project.format {
        case .ableton:  return .gray
        case .logic:    return .blue
        case .proTools: return .purple
        }
    }

    private var formatSymbol: String {
        switch project.format {
        case .ableton:  return "music.note.list"
        case .logic:    return "waveform"
        case .proTools: return "gearshape.2"
        }
    }

    private func parsedBadge() -> some View {
        let parsedCount = project.sessions.filter { $0.project != nil }.count
        let text = parsedCount > 0 ? "Parsed" : "Unparsed"
        let color = parsedCount > 0 ? Color.green : Color.yellow
        return Text(text)
            .font(.caption2)
            .foregroundColor(color)
            .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
            .background(color.opacity(0.15))
            .cornerRadius(4)
    }

    private func usedPluginsSummary() -> String? {
        guard project.format == .ableton else { return nil }
        var pluginSet: [String] = []
        for session in project.sessions {
            if case .ableton(let p) = session.project {
                pluginSet.append(contentsOf: p.usedPlugins)
            }
        }
        let unique = Array(Set(pluginSet)).sorted()
        guard !unique.isEmpty else { return "Plugins: none detected" }
        let top = unique.prefix(3)
        let extra = unique.count - top.count
        if extra > 0 {
            return "Plugins: \(top.joined(separator: ", ")) +\(extra) more"
        }
        return "Plugins: \(top.joined(separator: ", "))"
    }
}
