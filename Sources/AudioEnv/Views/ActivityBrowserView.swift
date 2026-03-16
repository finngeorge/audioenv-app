import SwiftUI

/// Day range filter options for activity list.
enum ActivityDayRange: Int, CaseIterable, Identifiable {
    case week = 7
    case twoWeeks = 14
    case month = 30
    case quarter = 90

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .week: return "7d"
        case .twoWeeks: return "14d"
        case .month: return "30d"
        case .quarter: return "90d"
        }
    }
}

/// Content column view for the Activity sidebar entry.
/// Shows session activity fetched from the API with format filter and day range picker.
struct ActivityBrowserView: View {
    @EnvironmentObject var activityService: ActivityService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var sessionMonitor: SessionMonitorService

    @Binding var selectedActivity: ActivityRecord?

    @State private var search = ""
    @State private var formatFilter: String? = nil
    @State private var dayRange: ActivityDayRange = .month
    @State private var filtered: [ActivityRecord] = []
    @State private var hasFetched = false

    var body: some View {
        VStack(spacing: 0) {
            // ── Search bar ─────────────────────────────────
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search sessions...", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)

            // ── Day range picker ───────────────────────────
            HStack(spacing: 4) {
                ForEach(ActivityDayRange.allCases) { range in
                    Button(range.label) {
                        dayRange = range
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(dayRange == range ? .accentColor : .secondary)
                }
                Spacer()

                // Format filter
                if availableFormats.count > 1 {
                    Picker("Format", selection: $formatFilter) {
                        Text("All").tag(nil as String?)
                        ForEach(availableFormats, id: \.self) { fmt in
                            Text(fmt).tag(fmt as String?)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 130)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)

            // ── Summary bar ────────────────────────────────
            if let summary = activityService.summary {
                HStack(spacing: 12) {
                    summaryChip(label: "Week", value: "\(summary.totalSessionsWeek) sessions")
                    summaryChip(label: "Hours", value: String(format: "%.1fh", summary.totalHoursWeek))
                    if let top = summary.mostActiveProjects.first {
                        summaryChip(label: "Top", value: top.projectName)
                    }
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, 6)
            }

            Divider().padding(.top, 4)

            // ── Activity list ──────────────────────────────
            if activityService.isLoading && filtered.isEmpty {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Loading activity...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                activityEmptyState()
            } else {
                List(filtered, selection: $selectedActivity) { activity in
                    ActivityRow(activity: activity)
                        .tag(activity)
                }
                .listStyle(.inset)
            }
        }
        .onChange(of: search) { _, _ in refilter() }
        .onChange(of: formatFilter) { _, _ in refilter() }
        .onChange(of: activityService.activities) { _, _ in refilter() }
        .onChange(of: dayRange) { _, newRange in
            Task {
                guard let token = auth.authToken else { return }
                await activityService.fetchActivities(token: token, days: newRange.rawValue)
            }
        }
        .onAppear {
            if !hasFetched {
                hasFetched = true
                Task {
                    guard let token = auth.authToken else { return }
                    await activityService.fetchAll(token: token, days: dayRange.rawValue)
                }
            }
            refilter()
        }
        // Auto-refresh when active sessions change (session opened/closed/synced)
        .onChange(of: sessionMonitor.activeSessions.count) { _, _ in
            Task {
                // Small delay to let the sync complete before fetching
                try? await Task.sleep(for: .seconds(2))
                guard let token = auth.authToken else { return }
                await activityService.fetchAll(token: token, days: dayRange.rawValue)
            }
        }
        .onChange(of: sessionMonitor.recentSessions.count) { _, _ in
            Task {
                try? await Task.sleep(for: .seconds(2))
                guard let token = auth.authToken else { return }
                await activityService.fetchAll(token: token, days: dayRange.rawValue)
            }
        }
    }

    // MARK: - Helpers

    private var availableFormats: [String] {
        Array(Set(activityService.activities.map(\.sessionFormat))).sorted()
    }

    private func refilter() {
        let q = search.lowercased()
        filtered = activityService.activities
            .filter { formatFilter == nil || $0.sessionFormat == formatFilter }
            .filter { q.isEmpty || $0.projectName.lowercased().contains(q) }
    }

    private func summaryChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
    }

    private func activityEmptyState() -> some View {
        VStack(spacing: 14) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Activity")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Session activity will appear here\nwhen the app detects DAW usage.")
                .multilineTextAlignment(.center)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Activity Row

struct ActivityRow: View {
    let activity: ActivityRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(activity.projectName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Text(formatRelativeDate(activity.openedAt))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                formatBadge(activity.sessionFormat)
                Text(formatDuration(activity.durationSeconds))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                Text("\(activity.saveCount) save\(activity.saveCount != 1 ? "s" : "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if activity.sizeDelta != 0 {
                    Text("\(activity.sizeDelta > 0 ? "+" : "")\(formatBytes(activity.sizeDelta))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if !activity.snapshots.isEmpty {
                    Text("\(activity.snapshots.count) snap\(activity.snapshots.count != 1 ? "s" : "")")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.6))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary.opacity(0.4))
            }
        }
        .padding(.vertical, 2)
    }

    @MainActor private func formatBadge(_ format: String) -> some View {
        Text(format)
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(ColorTokens.shared.sessionFormatColorByName(format).opacity(0.15))
            )
            .foregroundColor(ColorTokens.shared.sessionFormatColorByName(format))
    }
}

// MARK: - Shared Formatters

private func formatDuration(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h == 0 { return "\(m)m" }
    return m > 0 ? "\(h)h \(m)m" : "\(h)h"
}

private func formatRelativeDate(_ date: Date) -> String {
    let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    if days == 0 { return "Today" }
    if days == 1 { return "Yesterday" }
    if days < 7 { return "\(days) days ago" }
    return date.formatted(date: .abbreviated, time: .omitted)
}

private func formatBytes(_ bytes: Int64) -> String {
    let absBytes = abs(bytes)
    if absBytes < 1024 { return "\(absBytes) B" }
    if absBytes < 1024 * 1024 { return String(format: "%.1f KB", Double(absBytes) / 1024) }
    return String(format: "%.1f MB", Double(absBytes) / (1024 * 1024))
}
