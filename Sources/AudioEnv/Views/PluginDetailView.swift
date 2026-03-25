import SwiftUI
import AppKit

struct PluginDetailView: View {
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var backup: BackupService
    let plugin: AudioPlugin

    /// All format variants sharing the same name as the selected plugin.
    private var siblings: [AudioPlugin] {
        let target = plugin.name.lowercased()
        return scanner.plugins
            .filter { $0.name.lowercased() == target }
            .sorted { $0.format.rawValue < $1.format.rawValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header()
                Divider()
                formatVariants()
                Divider()
                metadata()
                Divider()
                usageInProjects()
                Divider()
                backupSection()
                Divider()
                licensingHints()
                Divider()
                actions()
            }
            .padding(EdgeInsets(top: 0, leading: 24, bottom: 24, trailing: 24))
        }
        .frame(minWidth: 340)
    }

    private func header() -> some View {
        let entry = scanner.catalogEntry(for: plugin)
        let iconImage = scanner.catalogImage(for: plugin)
        let formats = siblings.map(\.format)
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(plugin.name)
                    .font(.title2)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    ForEach(formats) { fmt in
                        Text(fmt.rawValue)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(ColorTokens.shared.pluginFormatColor(fmt).opacity(0.15))
                            .foregroundColor(ColorTokens.shared.pluginFormatColor(fmt))
                            .cornerRadius(4)
                    }
                }
                let resolvedMfr = ManufacturerResolver.displayManufacturer(
                    plugin: plugin, catalogManufacturer: entry?.manufacturer)
                if resolvedMfr != "Unknown" {
                    Text(resolvedMfr)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            if let iconImage {
                Image(nsImage: iconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .cornerRadius(10)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 36))
                    .foregroundColor(ColorTokens.shared.pluginFormatColor(plugin.format))
            }
        }
    }

    private func formatVariants() -> some View {
        let variants = siblings
        return Group {
            if variants.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Installed Formats")
                        .font(.headline)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(variants) { variant in
                            HStack(spacing: 8) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.caption)
                                    .foregroundColor(ColorTokens.shared.pluginFormatColor(variant.format))

                                Text(variant.format.rawValue)
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                if let v = variant.version {
                                    Text("v\(v)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Text(variant.path)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(6)
                            .background(Color.secondary.opacity(0.05))
                            .cornerRadius(6)
                        }
                    }
                }
            }
        }
    }

    private func metadata() -> some View {
        let entry = scanner.catalogEntry(for: plugin)
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Catalog")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(entry == nil ? "Not in catalog" : "Matched")
                    .font(.subheadline)
                    .foregroundColor(entry == nil ? .secondary : .primary)
            }
            GridRow {
                Text("Path")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(plugin.path)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(plugin.path)
            }
            GridRow {
                Text("Bundle ID")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(plugin.bundleID ?? "Unknown")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            GridRow {
                Text("Version")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(plugin.version ?? "Unknown")
                    .font(.subheadline)
            }
            GridRow {
                Text("Manufacturer")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text(ManufacturerResolver.displayManufacturer(
                    plugin: plugin, catalogManufacturer: entry?.manufacturer))
                    .font(.subheadline)
            }
        }
    }

    private func licensingHints() -> some View {
        let hints = licenseMetadataHints()
        return VStack(alignment: .leading, spacing: 6) {
            Text("Licensing Metadata")
                .font(.headline)
                .fontWeight(.semibold)
            if hints.isEmpty {
                Text("No licensing-related keys found in Info.plist.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(hints, id: \.key) { item in
                    HStack {
                        Text(item.key)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text(item.value)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private func usageInProjects() -> some View {
        let sessions = sessionsUsingPlugin()
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Used In")
                    .font(.headline)
                    .fontWeight(.semibold)
                if !sessions.isEmpty {
                    Text("\(sessions.count)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(ColorTokens.shared.pluginFormatColor(plugin.format))
                        .cornerRadius(8)
                }
            }

            if sessions.isEmpty {
                Text("No usage detected in parsed sessions.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(sessions) { session in
                        HStack(spacing: 8) {
                            // Format indicator
                            Circle()
                                .fill(ColorTokens.shared.sessionFormatColor(session.format))
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.name)
                                    .font(.subheadline)
                                    .lineLimit(1)

                                HStack(spacing: 6) {
                                    Text(session.format.rawValue)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("•")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(session.modifiedDate.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // Note: This would need navigation support to work fully
                            // For now, just show in Finder
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
                        }

                        if session.id != sessions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func sessionsUsingPlugin() -> [AudioSession] {
        let target = plugin.name.lowercased()

        return scanner.sessions.filter { session in
            guard let project = session.project else { return false }

            switch project {
            case .ableton(let p):
                // Fuzzy match: check if any used plugin contains or is contained in target
                return p.usedPlugins.contains { pluginName in
                    let name = pluginName.lowercased()
                    return name.contains(target) || target.contains(name)
                }
            case .logic(_), .proTools(_):
                // Logic and Pro Tools parsing is limited - no plugin info yet
                return false
            }
        }.sorted { $0.modifiedDate > $1.modifiedDate } // Most recent first
    }


    private func backupSection() -> some View {
        let backups = backup.backupsContaining(plugin: plugin)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Backups")
                    .font(.headline)
                    .fontWeight(.semibold)

                if !backups.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "icloud.fill")
                        Text("\(backups.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue)
                    .cornerRadius(8)
                }
            }

            if backups.isEmpty {
                Text("Not backed up yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(backups) { backup in
                        HStack(spacing: 8) {
                            Image(systemName: "archivebox.fill")
                                .font(.caption)
                                .foregroundStyle(.blue)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text(backup.formattedDate)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(backup.formattedSize)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(6)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(6)
                    }
                }
            }
        }
    }

    private func actions() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button("Show in Finder") { showInFinder() }
                    .buttonStyle(.bordered)

                Button("Copy Path") { copyPath() }
                    .buttonStyle(.bordered)

                Button("Copy Bundle ID") { copyBundleID() }
                    .buttonStyle(.bordered)
            }
            .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: 10) {
                Button {
                    let url = "https://audioenv.com/share/plugin/\(plugin.id.uuidString)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .disabled(backup.backupsContaining(plugin: plugin).isEmpty)

                Button {
                    Task {
                        await backup.backupPlugins([plugin],
                            backupName: "\(plugin.name) Plugin",
                            scopeDescription: "Single plugin: \(plugin.name) (\(plugin.format.rawValue))")
                    }
                } label: {
                    Label("Backup to Cloud", systemImage: "icloud.and.arrow.up")
                }
                .buttonStyle(.bordered)
                .disabled(backup.isUploading)
            }
        }
    }

    private func licenseMetadataHints() -> [(key: String, value: String)] {
        let plistPath = (plugin.path as NSString).appendingPathComponent("Contents/Info.plist")
        guard let data = FileManager.default.contents(atPath: plistPath),
              let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else { return [] }

        let keywords = ["license", "licence", "serial", "ilok", "pace", "activation", "auth", "protection"]
        var results: [(String, String)] = []
        for (key, value) in dict {
            let lower = key.lowercased()
            guard keywords.contains(where: { lower.contains($0) }) else { continue }
            results.append((key, "\(value)"))
        }
        return results.sorted { $0.0 < $1.0 }
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: plugin.path)])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(plugin.path, forType: .string)
    }

    private func copyBundleID() {
        let id = plugin.bundleID ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(id, forType: .string)
    }

}
