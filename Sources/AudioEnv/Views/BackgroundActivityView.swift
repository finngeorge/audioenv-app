import SwiftUI

/// Toolbar button that shows a spinner while background work runs and opens
/// a popover listing running and recent jobs with what triggered each one.
struct BackgroundActivityToolbarButton: View {
    @ObservedObject private var activity = BackgroundActivityCenter.shared
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            if activity.isBusy {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(activity.running.count == 1 ? activity.running[0].title : "\(activity.running.count) tasks")
                        .lineLimit(1)
                }
            } else {
                Label("Activity", systemImage: "checkmark.circle")
            }
        }
        .help(activity.isBusy ? "Background tasks running" : "Background activity")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            BackgroundActivityView(activity: activity)
        }
    }
}

struct BackgroundActivityView: View {
    @ObservedObject var activity: BackgroundActivityCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Background Activity")
                .font(.headline)
                .padding([.horizontal, .top])
                .padding(.bottom, 8)
            Divider()

            if activity.running.isEmpty && activity.recent.isEmpty {
                Text("Nothing has run yet this session.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !activity.running.isEmpty {
                            sectionHeader("Running")
                            ForEach(activity.running) { JobRow(job: $0) }
                        }
                        if !activity.recent.isEmpty {
                            sectionHeader("Recent")
                            ForEach(activity.recent) { JobRow(job: $0) }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 460)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

private struct JobRow: View {
    let job: BackgroundActivityCenter.Job

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let detail = job.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if job.finishedAt == nil {
                    if let progress = job.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch job.outcome {
        case .none:
            Image(systemName: job.kind.symbolName).foregroundStyle(.blue)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    /// "Auto-backup: smart collection 'x' · 2 min ago" or "· failed: reason".
    private var footer: String {
        var parts = [job.trigger]
        if let finished = job.finishedAt {
            parts.append(finished.formatted(.relative(presentation: .named)))
        } else {
            parts.append("started \(job.startedAt.formatted(date: .omitted, time: .shortened))")
        }
        if case .failed(let reason) = job.outcome {
            parts.append("failed: \(reason)")
        }
        return parts.joined(separator: " · ")
    }
}
