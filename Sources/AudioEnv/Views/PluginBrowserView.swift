import SwiftUI

/// Lists every audio plugin discovered on the system.
/// Supports free-text search and format filtering (AU / VST / VST3 / AAX).
struct PluginBrowserView: View {
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var backup: BackupService

    @Binding var selectedPlugin: AudioPlugin?
    @State private var search       = ""
    @State private var formatFilter: PluginFormat? = nil
    @State private var showExportMenu = false
    @FocusState private var isSearchFocused: Bool

    private var filtered: [AudioPlugin] {
        scanner.plugins
            .filter { formatFilter == nil || $0.format == formatFilter }
            .filter { search.isEmpty || $0.name.lowercased().contains(search.lowercased()) }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

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
            if filtered.isEmpty {
                pluginEmptyState()
            } else {
                List(filtered, selection: $selectedPlugin) { plugin in
                    PluginRow(
                        plugin: plugin,
                        icon: scanner.catalogImage(for: plugin),
                        backupCount: backup.backupCount(for: plugin)
                    )
                    .tag(plugin)
                }
                .listStyle(.inset)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            isSearchFocused = true
        }
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
                content = generateCSV(plugins: filtered)
            case .json:
                content = generateJSON(plugins: filtered)
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

// MARK: – Single plugin row

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

    private var fmtColor: Color {
        switch plugin.format {
        case .audioUnit: return Color(red: 0.98, green: 0.85, blue: 0.93)  // #f9d9ee
        case .vst:       return Color(red: 0.60, green: 0.80, blue: 0.95)  // #9accf3
        case .vst3:      return Color(red: 0.62, green: 0.86, blue: 0.74)  // #9edbbd
        case .aax:       return Color(red: 0.99, green: 0.95, blue: 0.85)  // #fdf3d8
        }
    }
}
