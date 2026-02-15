import SwiftUI

/// View for managing scan settings and viewing scan status.
struct ScanView: View {
    @EnvironmentObject var scanner: ScannerService

    private var cacheStatusLabel: String {
        if scanner.plugins.isEmpty && scanner.sessions.isEmpty && scanner.lastScanDate == nil {
            return "Cache: Empty"
        } else if scanner.isCacheStale {
            return "Cache: Stale"
        } else {
            let count = scanner.plugins.count + scanner.sessions.count
            return "Cache: \(count) items loaded"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Scan progress (if currently scanning)
                if scanner.isScanning {
                    scanningProgress()
                    Divider()
                }

                // Scan settings and configuration
                scanScopeRow()
                parseModeRow()
                autoRescanRow()

                Divider()

                cacheStatusRow()

                Divider()

                debugCatalogRow()
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Scan Settings")
    }

    // MARK: - Scan Progress

    private func scanningProgress() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scanning in Progress")
                .font(.headline)
                .fontWeight(.semibold)

            ProgressView(value: scanner.scanProgress)
                .frame(maxWidth: 360)

            Text(scanner.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Scan Settings

    private func scanScopeRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "viewfinder")
                    .foregroundColor(.accentColor)
                Text("Scan Scope")
                    .font(.headline)
                    .fontWeight(.semibold)
            }
            Text(scanScopeText())
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.leading, 28)
        }
    }

    private func parseModeRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .foregroundColor(.secondary)
                Text("Parse Mode")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Toggle("Parse all sessions (may be slow)", isOn: $scanner.parseAllSessions)
                .toggleStyle(.switch)
                .padding(.leading, 28)

            if !scanner.parseAllSessions {
                Text("Limited to newest session per project, up to 200")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)
            }

            Toggle("Parse auto backup sessions", isOn: $scanner.parseBackups)
                .toggleStyle(.switch)
                .padding(.leading, 28)

            if !scanner.parseBackups {
                Text("Auto backups (e.g. Ableton's automatic saves) are listed but not parsed to save time")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)
            }
        }
    }

    private func autoRescanRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundColor(.secondary)
                Text("Auto-Rescan")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            Toggle("Auto-rescan when changes are detected", isOn: $scanner.autoRescanOnLaunch)
                .toggleStyle(.switch)
                .padding(.leading, 28)
        }
    }

    private func cacheStatusRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: scanner.isCacheStale ? "exclamationmark.triangle.fill" : "tray.full")
                    .foregroundColor(scanner.isCacheStale ? .orange : .secondary)
                Text("Cache Status")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            HStack(spacing: 10) {
                Text(cacheStatusLabel)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)

                Spacer()

                Button("Clear Cache") {
                    scanner.clearCache()
                }
                .buttonStyle(.bordered)
                .disabled(scanner.plugins.isEmpty && scanner.sessions.isEmpty && scanner.lastScanDate == nil)
            }

            if scanner.isCacheStale, let reason = scanner.cacheStaleReason {
                Text(reason)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, 28)
            }
        }
    }

    private func debugCatalogRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "hammer")
                    .foregroundColor(.secondary)
                Text("Plugin Catalog")
                    .font(.headline)
                    .fontWeight(.semibold)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Catalog entries: \(scanner.catalogEntryCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Matches: \(scanner.catalogMatchCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Text("Images: \(scanner.catalogImageFileCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.leading, 28)
        }
    }

    // MARK: - Helpers

    private func scanScopeText() -> String {
        let defaults = ["Documents", "Desktop", "Music", "Downloads"]
        if scanner.customPaths.isEmpty {
            return "Scanning: \(defaults.joined(separator: ", "))"
        }
        let count = scanner.customPaths.count
        return "Scanning: \(defaults.joined(separator: ", ")) + \(count) custom path\(count == 1 ? "" : "s")"
    }
}
