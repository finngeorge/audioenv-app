import SwiftUI

/// Dashboard shown when the "Summary" sidebar item is selected.
/// Displays aggregate stats, a progress indicator while scanning,
/// and per-format breakdowns for both plugins and sessions.
struct SummaryView: View {
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var backup:  BackupService
    @EnvironmentObject var auth:    AuthenticationService
    @EnvironmentObject var sync:    SyncService

    // Navigation callbacks
    let onNavigateToPlugins: () -> Void
    let onNavigateToProjects: (SessionFormat?) -> Void

    // Cache computed stats for performance
    @State private var cachedProjects: [SessionProject] = []
    @State private var cachedPrimarySessions: [AudioSession] = []
    @State private var cachedTotalPlugins: Int = 0
    @State private var cachedTotalSessions: Int = 0
    @State private var cachedFormatCounts: [SessionFormat: Int] = [:]
    @State private var cachedPluginFormatCounts: [PluginFormat: Int] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if scanner.plugins.isEmpty && scanner.sessions.isEmpty {
                    if scanner.isScanning {
                        scanningPlaceholder()
                    } else {
                        emptyPlaceholder()
                    }
                } else {
                    if scanner.isScanning {
                        scanningInline()
                    }

                    // Main stats grid
                    statsGrid()

                    Divider()

                    // Format breakdowns
                    pluginBreakdown()
                    Divider()
                    sessionBreakdown()

                    Divider()

                    // Backup, sync, and last scanned
                    backupStatus()
                    syncStatusRow()
                    lastScannedRow()
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .navigationTitle("")
        .onAppear(perform: updateCachedStats)
        .onChange(of: scanner.plugins.count) { _, _ in updateCachedStats() }
        .onChange(of: scanner.sessions.count) { _, _ in updateCachedStats() }
    }

    private func updateCachedStats() {
        cachedProjects = SessionProject.groupSessions(scanner.sessions)
        cachedPrimarySessions = cachedProjects.flatMap { $0.sessions }
        cachedTotalPlugins = scanner.plugins.count
        cachedTotalSessions = cachedPrimarySessions.count

        // Pre-calculate format counts
        var sessionCounts: [SessionFormat: Int] = [:]
        for format in SessionFormat.allCases {
            sessionCounts[format] = cachedPrimarySessions.filter { $0.format == format }.count
        }
        cachedFormatCounts = sessionCounts

        var pluginCounts: [PluginFormat: Int] = [:]
        for format in PluginFormat.allCases {
            pluginCounts[format] = scanner.plugins.filter { $0.format == format }.count
        }
        cachedPluginFormatCounts = pluginCounts
    }

    // MARK: – Placeholders

    private func emptyPlaceholder() -> some View {
        VStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text("Nothing scanned yet")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Press Scan in the toolbar (or Start Scan in Manage Paths) to discover plugins and sessions on your system.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 80)
    }

    private func scanningPlaceholder() -> some View {
        VStack(spacing: 12) {
            ProgressView(value: scanner.scanProgress)
                .frame(maxWidth: 360)
            Text(scanner.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func scanningInline() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ProgressView(value: scanner.scanProgress)
                .frame(maxWidth: 360)
            Text(scanner.statusMessage)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: – Cloud sync status

    private func syncStatusRow() -> some View {
        HStack(spacing: 8) {
            if sync.isSyncing {
                ProgressView()
                    .controlSize(.small)
                Text("Syncing...")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                Image(systemName: sync.lastSyncDate != nil ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                    .foregroundColor(sync.lastSyncDate != nil ? .green : .secondary)
                Text(syncStatusText())
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer()

                if auth.isAuthenticated {
                    Button("Sync Now") {
                        guard let token = auth.authToken else { return }
                        Task {
                            await sync.syncToCloud(plugins: scanner.plugins, sessions: scanner.sessions, token: token)
                        }
                    }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func syncStatusText() -> String {
        if let error = sync.lastSyncError {
            return "Sync failed: \(error)"
        }
        guard let date = sync.lastSyncDate else {
            return auth.isAuthenticated ? "Not synced" : "Log in to sync"
        }
        return "Last synced: \(Self.scanDateFormatter.string(from: date))"
    }

    // MARK: – Last scanned timestamp

    private func lastScannedRow() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .foregroundColor(.secondary)
                Text(lastScannedText())
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if scanner.skippedLargeSessions > 0 {
                Text("\(scanner.skippedLargeSessions) large session(s) skipped during scan")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 28)
            }
        }
    }

    private func lastScannedText() -> String {
        guard let date = scanner.lastScanDate else { return "Last scanned: Never" }
        return "Last scanned: \(Self.scanDateFormatter.string(from: date))"
    }

    private static let scanDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    // MARK: – Stats grid

    private func statsGrid() -> some View {
        LazyVGrid(columns: [GridItem(.flexible(minimum: 120)), GridItem(.flexible(minimum: 120))], spacing: 12) {
            StatCard(title: "Total Plugins",  count: cachedTotalPlugins,
                     icon: "waveform",    color: .indigo, action: {
                onNavigateToPlugins()
            })
            StatCard(title: "Projects", count: cachedProjects.count,
                     icon: "folder.fill", color: .mint, action: {
                onNavigateToProjects(nil)
            })
            StatCard(title: "Sessions", count: cachedTotalSessions,
                     icon: "doc.on.doc", color: .orange, action: {})
            StatCard(title: "Ableton Live",   count: cachedFormatCounts[.ableton] ?? 0,
                     icon: "circle.fill", color: .teal, action: {
                onNavigateToProjects(.ableton)
            })
            StatCard(title: "Logic Pro",      count: cachedFormatCounts[.logic] ?? 0,
                     icon: "circle.fill", color: .blue, action: {
                onNavigateToProjects(.logic)
            })
            StatCard(title: "Pro Tools",      count: cachedFormatCounts[.proTools] ?? 0,
                     icon: "circle.fill", color: .purple, action: {
                onNavigateToProjects(.proTools)
            })
        }
    }

    // MARK: – Format breakdowns

    private func pluginBreakdown() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plugin Formats")
                .font(.headline)
                .fontWeight(.semibold)

            ForEach(PluginFormat.allCases) { f in
                let n = cachedPluginFormatCounts[f] ?? 0
                if n > 0 {
                    HStack {
                        Circle().fill(colorFor(f)).frame(width: 10, height: 10)
                        Text(f.rawValue)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Text("\(n) (\(percent(n, of: cachedTotalPlugins)))")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
        }
    }

    private func sessionBreakdown() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Formats")
                .font(.headline)
                .fontWeight(.semibold)

            ForEach(SessionFormat.allCases) { format in
                let n = cachedFormatCounts[format] ?? 0
                HStack {
                    Circle().fill(colorFor(format)).frame(width: 10, height: 10)
                    Text(format.rawValue)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text("\(n) (\(percent(n, of: cachedTotalSessions)))")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }

    // MARK: – Helpers

    private func percent(_ value: Int, of total: Int) -> String {
        guard total > 0 else { return "0%" }
        let pct = (Double(value) / Double(total)) * 100
        return String(format: "%.1f%%", pct)
    }

    // MARK: – Backup status

    private func backupStatus() -> some View {
        HStack(spacing: 8) {
            Image(systemName: backup.destination == nil ? "cloud" : "cloud.fill")
                .foregroundColor(backup.destination == nil ? .secondary : .green)
            Text("Backup: \(backup.destination?.displayName ?? "Not configured")")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    private func colorFor(_ f: PluginFormat) -> Color {
        switch f {
        case .audioUnit: return Color(red: 0.98, green: 0.85, blue: 0.93)  // #f9d9ee
        case .vst:       return Color(red: 0.60, green: 0.80, blue: 0.95)  // #9accf3
        case .vst3:      return Color(red: 0.62, green: 0.86, blue: 0.74)  // #9edbbd
        case .aax:       return Color(red: 0.99, green: 0.95, blue: 0.85)  // #fdf3d8
        }
    }

    private func colorFor(_ f: SessionFormat) -> Color {
        switch f {
        case .ableton:  return .gray
        case .logic:    return .blue
        case .proTools: return .purple
        }
    }
}

// MARK: – Stat card component

struct StatCard: View {
    let title: String
    let count: Int
    let icon:  String
    let color: Color
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundColor(color)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(12)
        .contentShape(Rectangle())
        .onTapGesture {
            action()
        }
    }
}
