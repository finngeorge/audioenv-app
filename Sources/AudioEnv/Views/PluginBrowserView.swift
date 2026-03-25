import SwiftUI

/// Lists every audio plugin discovered on the system,
/// stacking plugins with the same name but different formats into a single row.
struct PluginBrowserView: View {
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var backup: BackupService

    @Binding var selectedPlugin: AudioPlugin?
    @State private var search       = ""
    @State private var formatFilter: PluginFormat? = nil
    @State private var groups: [PluginGroup] = []
    @State private var expandedGroups: Set<String> = []
    @FocusState private var isSearchFocused: Bool
    @State private var showExportMenu = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Search bar + export ──────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search…", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFocused)

                Menu {
                    Button(action: { self.exportPlugins(format: .csv) }) {
                        Label("Export as CSV", systemImage: "doc.text")
                    }
                    Button(action: { self.exportPlugins(format: .json) }) {
                        Label("Export as JSON", systemImage: "doc.badge.gearshape")
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24)
                .help("Export plugin list")
            }
            .padding([.leading, .trailing])

            // ── Format picker ────────────────────────────────────────
            Picker("Format", selection: $formatFilter) {
                Text("All").tag(nil as PluginFormat?)
                ForEach(PluginFormat.allCases) { f in
                    Text(f.rawValue).tag(f as PluginFormat?)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.top, 4)

            Divider().padding(.top, 2)

            // ── Plugin list ───────────────────────────────────
            if groups.isEmpty {
                pluginEmptyState()
            } else {
                List(selection: $selectedPlugin) {
                    ForEach(groups) { group in
                        if group.isMultiFormat {
                            PluginGroupRow(
                                group: group,
                                icon: scanner.catalogImage(for: group.primaryPlugin),
                                backupCount: groupBackupCount(group),
                                isExpanded: expandedGroups.contains(group.id),
                                onToggle: { toggleGroup(group) }
                            )
                            .tag(group.primaryPlugin)

                            if expandedGroups.contains(group.id) {
                                ForEach(group.plugins) { plugin in
                                    PluginFormatRow(
                                        plugin: plugin,
                                        backupCount: backup.backupCount(for: plugin)
                                    )
                                    .tag(plugin)
                                    .padding(.leading, 20)
                                }
                            }
                        } else {
                            PluginRow(
                                plugin: group.primaryPlugin,
                                icon: scanner.catalogImage(for: group.primaryPlugin),
                                backupCount: backup.backupCount(for: group.primaryPlugin)
                            )
                            .tag(group.primaryPlugin)
                        }
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
        .onChange(of: scanner.plugins) { _, _ in refilter() }
        .onAppear { refilter() }
    }

    private func refilter() {
        let q = search.lowercased()
        let filtered = scanner.plugins
            .filter { formatFilter == nil || $0.format == formatFilter }
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
        groups = PluginGroup.grouped(from: filtered)
    }

    private func toggleGroup(_ group: PluginGroup) {
        if expandedGroups.contains(group.id) {
            expandedGroups.remove(group.id)
        } else {
            expandedGroups.insert(group.id)
        }
    }

    private func groupBackupCount(_ group: PluginGroup) -> Int {
        group.plugins.reduce(0) { $0 + backup.backupCount(for: $1) }
    }

    private func pluginEmptyState() -> some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Plugins")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(scanner.isScanning
                 ? "Scanning…"
                 : "None found in standard locations.\nTry adding custom paths via the toolbar.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Export

    enum ExportFormat {
        case csv, json
    }

    private func exportPlugins(format: ExportFormat) {
        let allPlugins = groups.flatMap(\.plugins)
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        savePanel.nameFieldStringValue = "plugins.\(format == .csv ? "csv" : "json")"
        savePanel.title = "Export Plugin List"
        savePanel.message = "Choose where to save your plugin list"

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else { return }

            let content: String
            switch format {
            case .csv:
                content = generateCSV(plugins: allPlugins)
            case .json:
                content = generateJSON(plugins: allPlugins)
            }

            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func generateCSV(plugins: [AudioPlugin]) -> String {
        var csv = "Name,Format,Version,Manufacturer,Bundle ID,Path\n"
        for plugin in plugins {
            let name = escapeCSV(plugin.name)
            let format = plugin.format.rawValue
            let version = escapeCSV(plugin.version ?? "")
            let manufacturer = escapeCSV(plugin.manufacturer ?? "")
            let bundleID = escapeCSV(plugin.bundleID ?? "")
            let path = escapeCSV(plugin.path)

            csv += "\(name),\(format),\(version),\(manufacturer),\(bundleID),\(path)\n"
        }
        return csv
    }

    private func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func generateJSON(plugins: [AudioPlugin]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let exportData = plugins.map { plugin in
            [
                "name": plugin.name,
                "format": plugin.format.rawValue,
                "version": plugin.version ?? "",
                "manufacturer": plugin.manufacturer ?? "",
                "bundleID": plugin.bundleID ?? "",
                "path": plugin.path
            ]
        }

        guard let jsonData = try? encoder.encode(exportData),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return "[]"
        }

        return jsonString
    }
}

// MARK: – Grouped plugin row (multi-format, stacked icon)

private struct PluginGroupRow: View {
    let group: PluginGroup
    let icon: NSImage?
    let backupCount: Int
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Stacked puzzle piece icon
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .cornerRadius(6)
            } else {
                ZStack {
                    Image(systemName: "puzzlepiece.extension")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 18, height: 18)
                        .foregroundColor(.secondary.opacity(0.4))
                        .offset(x: 3, y: -3)
                    Image(systemName: "puzzlepiece.extension")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                        .foregroundColor(.primary.opacity(0.7))
                }
                .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(group.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 4) {
                    ForEach(group.formats) { fmt in
                        Text(fmt.rawValue)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(ColorTokens.shared.pluginFormatColor(fmt).opacity(0.15))
                            .foregroundColor(ColorTokens.shared.pluginFormatColor(fmt))
                            .cornerRadius(3)
                    }
                }
            }

            Spacer()

            // Cloud badge
            if backupCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.fill")
                        .font(.caption)
                    Text("\(backupCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }

            // Expand/collapse chevron
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.15), value: isExpanded)
        }
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

// MARK: – Expanded format variant row

private struct PluginFormatRow: View {
    let plugin: AudioPlugin
    let backupCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .resizable()
                .scaledToFit()
                .frame(width: 18, height: 18)
                .foregroundColor(fmtColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.format.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if let v = plugin.version {
                    Text("v\(v)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if backupCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.fill")
                        .font(.caption)
                    Text("\(backupCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    @MainActor private var fmtColor: Color {
        ColorTokens.shared.pluginFormatColor(plugin.format)
    }
}

// MARK: – Single plugin row (non-grouped)

private struct PluginRow: View {
    let plugin: AudioPlugin
    let icon: NSImage?
    let backupCount: Int

    var body: some View {
        HStack(spacing: 10) {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .cornerRadius(6)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 28, height: 28)
                    .foregroundColor(fmtColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 8) {
                    Text(plugin.format.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if let v = plugin.version {
                        Text("v\(v)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            // Cloud badge
            if backupCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "icloud.fill")
                        .font(.caption)
                    Text("\(backupCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.blue)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    @MainActor private var fmtColor: Color {
        ColorTokens.shared.pluginFormatColor(plugin.format)
    }
}
