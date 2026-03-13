import SwiftUI

/// Detail column view showing snapshot diff timeline for a selected activity session.
@MainActor
struct ActivityDetailView: View {
    let activity: ActivityRecord

    @State private var expandedIndex: Int?

    init(activity: ActivityRecord) {
        self.activity = activity
        // Auto-expand the most recent snapshot
        let lastIndex = activity.snapshots.count - 1
        _expandedIndex = State(initialValue: lastIndex >= 0 ? lastIndex : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // ── Header ─────────────────────────────────
                header

                Divider().padding(.vertical, 12)

                // ── Metadata grid ──────────────────────────
                metadataGrid

                Divider().padding(.vertical, 12)

                // ── Save Timeline ──────────────────────────
                if activity.snapshots.isEmpty {
                    Text("No snapshots captured for this session.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                } else {
                    Text("SAVE TIMELINE")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .tracking(1)
                        .padding(.bottom, 8)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(activity.snapshots.enumerated()), id: \.offset) { index, snap in
                            let diff = index > 0 ? computeDiff(from: activity.snapshots[index - 1], to: snap) : nil

                            if index == 0 {
                                initialSnapshotRow(snap: snap, index: index)
                            } else {
                                diffSnapshotRow(snap: snap, diff: diff, index: index)
                            }
                        }
                    }
                }

                // ── Related session (Save As) ──────────────
                if let related = activity.relatedProjectPath {
                    Divider().padding(.vertical, 12)
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.branch")
                            .foregroundColor(.blue)
                            .font(.caption)
                        Text("Save As from:")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text((related as NSString).lastPathComponent)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 24)
            }
            .padding(24)
        }
        .frame(minWidth: 380)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(activity.projectName)
                .font(.title2)
                .fontWeight(.bold)

            HStack(spacing: 8) {
                formatBadge(activity.sessionFormat)
                Text(activity.openedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let closed = activity.closedAt {
                    Text("–")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(closed.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Metadata Grid

    private var metadataGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
            GridRow {
                metaLabel("Duration")
                metaValue(formatDurationDetail(activity.durationSeconds))
            }
            GridRow {
                metaLabel("Saves")
                metaValue("\(activity.saveCount)")
            }
            GridRow {
                metaLabel("Size")
                metaValue("\(formatBytesDetail(activity.initialSizeBytes)) → \(formatBytesDetail(activity.finalSizeBytes))")
            }
            if activity.newAudioFiles > 0 {
                GridRow {
                    metaLabel("New Audio")
                    metaValue("\(activity.newAudioFiles) file\(activity.newAudioFiles != 1 ? "s" : "")")
                }
            }
            if activity.newBounces > 0 {
                GridRow {
                    metaLabel("Bounces")
                    metaValue("\(activity.newBounces)")
                }
            }
        }
    }

    // MARK: - Initial Snapshot Row

    private func initialSnapshotRow(snap: ActivitySnapshot, index: Int) -> some View {
        let isExpanded = expandedIndex == index
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedIndex = isExpanded ? nil : index
                }
            } label: {
                HStack(spacing: 8) {
                    Text(snap.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 55, alignment: .leading)

                    Text("Session opened")
                        .font(.system(size: 11, weight: .medium))

                    Spacer()

                    compactStats(snap: snap)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                initialDetail(snap: snap)
                    .padding(.leading, 63)
                    .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isExpanded ? Color.accentColor.opacity(0.04) : .clear)
        )
    }

    // MARK: - Diff Snapshot Row

    private func diffSnapshotRow(snap: ActivitySnapshot, diff: ActivitySnapshotDiff?, index: Int) -> some View {
        let isExpanded = expandedIndex == index
        let sizeDelta = snap.fileSize - activity.snapshots[index - 1].fileSize
        let summary = diff.map { summarizeDiff($0) } ?? ""

        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expandedIndex = isExpanded ? nil : index
                }
            } label: {
                HStack(spacing: 8) {
                    Text(snap.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 55, alignment: .leading)

                    Text("Save #\(index)")
                        .font(.system(size: 11, weight: .medium))

                    if sizeDelta != 0 {
                        Text("\(sizeDelta > 0 ? "+" : "")\(formatBytesDetail(abs(sizeDelta)))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, let diff = diff {
                diffDetail(diff: diff)
                    .padding(.leading, 63)
                    .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isExpanded ? Color.accentColor.opacity(0.04) : .clear)
        )
    }

    // MARK: - Compact Stats

    private func compactStats(snap: ActivitySnapshot) -> some View {
        HStack(spacing: 6) {
            if let tc = snap.trackCount { statPill("\(tc) tracks") }
            if let pc = snap.pluginCount { statPill("\(pc) plugins") }
            if let bpm = snap.tempo { statPill("\(Int(bpm)) BPM") }
        }
    }

    private func statPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundColor(.secondary)
    }

    // MARK: - Initial Snapshot Detail

    private func initialDetail(snap: ActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Track breakdown
            if snap.audioTrackCount != nil {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("Tracks")
                    HStack(spacing: 12) {
                        if let c = snap.audioTrackCount, c > 0 { trackStat("Audio", count: c) }
                        if let c = snap.midiTrackCount, c > 0 { trackStat("MIDI", count: c) }
                        if let c = snap.returnTrackCount, c > 0 { trackStat("Return", count: c) }
                    }
                }
            }

            // Plugin list
            if let names = snap.pluginNames, !names.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    sectionLabel("Plugins")
                    FlowLayout(spacing: 4) {
                        ForEach(names, id: \.self) { name in
                            Text(name)
                                .font(.system(size: 10))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.primary.opacity(0.06))
                                )
                        }
                    }
                }
            }

            // Properties
            HStack(spacing: 12) {
                if let bpm = snap.tempo {
                    Text("\(Int(bpm)) BPM").font(.system(size: 10)).foregroundColor(.secondary)
                }
                if let key = snap.keySignature {
                    Text(key).font(.system(size: 10)).foregroundColor(.secondary)
                }
                if let ts = snap.timeSignature {
                    Text(ts).font(.system(size: 10)).foregroundColor(.secondary)
                }
                if let clips = snap.clipCount, clips > 0 {
                    Text("\(clips) clips").font(.system(size: 10)).foregroundColor(.secondary)
                }
                if let v = snap.abletonVersion {
                    Text("Ableton \(v)").font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Diff Detail

    private func diffDetail(diff: ActivitySnapshotDiff) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if diff.isEmpty {
                Text("No structural changes detected")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            } else {
                // Track changes
                if !diff.addedTrackPlugins.isEmpty || !diff.removedTrackPlugins.isEmpty || diff.totalTrackDelta != 0 {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionLabel("Tracks")
                        // Deduplicate by track name for track-level display
                        let addedTracks = uniqueTracks(diff.addedTrackPlugins)
                        let removedTracks = uniqueTracks(diff.removedTrackPlugins)
                        ForEach(addedTracks, id: \.trackName) { tp in
                            diffLine("+", "\(tp.trackType): \"\(tp.trackName)\"", color: .green)
                        }
                        ForEach(removedTracks, id: \.trackName) { tp in
                            diffLine("-", "\(tp.trackType): \"\(tp.trackName)\"", color: .red)
                        }
                        if diff.totalTrackDelta != 0 && addedTracks.isEmpty && removedTracks.isEmpty {
                            diffLine(
                                diff.totalTrackDelta > 0 ? "+" : "-",
                                "\(abs(diff.totalTrackDelta)) track\(abs(diff.totalTrackDelta) != 1 ? "s" : "")",
                                color: diff.totalTrackDelta > 0 ? .green : .red
                            )
                        }
                    }
                }

                // Plugin changes
                if !diff.addedPlugins.isEmpty || !diff.removedPlugins.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionLabel("Plugins")
                        if !diff.addedTrackPlugins.isEmpty {
                            ForEach(diff.addedTrackPlugins, id: \.self) { tp in
                                diffLine("+", "\(tp.pluginName) (on \(tp.trackName))", color: .green)
                            }
                        } else {
                            ForEach(diff.addedPlugins, id: \.self) { name in
                                diffLine("+", name, color: .green)
                            }
                        }
                        if !diff.removedTrackPlugins.isEmpty {
                            ForEach(diff.removedTrackPlugins, id: \.self) { tp in
                                diffLine("-", "\(tp.pluginName) (was on \(tp.trackName))", color: .red)
                            }
                        } else {
                            ForEach(diff.removedPlugins, id: \.self) { name in
                                diffLine("-", name, color: .red)
                            }
                        }
                    }
                }

                // Property changes
                if diff.tempoChange != nil || diff.keyChange != nil || diff.timeSignatureChange != nil {
                    VStack(alignment: .leading, spacing: 2) {
                        sectionLabel("Properties")
                        if let tc = diff.tempoChange {
                            propChange("Tempo", "\(Int(tc.from)) → \(Int(tc.to)) BPM")
                        }
                        if let kc = diff.keyChange {
                            propChange("Key", "\(kc.from) → \(kc.to)")
                        }
                        if let tsc = diff.timeSignatureChange {
                            propChange("Time", "\(tsc.from) → \(tsc.to)")
                        }
                    }
                }
            }
        }
    }

    // MARK: - UI Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
    }

    private func trackStat(_ label: String, count: Int) -> some View {
        Text("\(label): \(count)")
            .font(.system(size: 10))
            .foregroundColor(.secondary)
    }

    private func diffLine(_ prefix: String, _ text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(prefix)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(color)
            Text(text)
                .font(.system(size: 10))
                .foregroundColor(color.opacity(0.85))
        }
    }

    private func propChange(_ label: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .font(.system(size: 10))
                .foregroundColor(.blue)
            Text(value)
                .font(.system(size: 10))
                .foregroundColor(.blue.opacity(0.85))
        }
    }

    private func formatBadge(_ format: String) -> some View {
        Text(format)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(ColorTokens.shared.sessionFormatColorByName(format).opacity(0.15))
            )
            .foregroundColor(ColorTokens.shared.sessionFormatColorByName(format))
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundColor(.secondary)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .fontWeight(.medium)
    }

    private func uniqueTracks(_ trackPlugins: [ActivityTrackPlugin]) -> [ActivityTrackPlugin] {
        var seen = Set<String>()
        return trackPlugins.filter { seen.insert($0.trackName).inserted }
    }
}

// MARK: - Diff Computation

private struct ActivitySnapshotDiff {
    let addedPlugins: [String]
    let removedPlugins: [String]
    let addedTrackPlugins: [ActivityTrackPlugin]
    let removedTrackPlugins: [ActivityTrackPlugin]
    let totalTrackDelta: Int
    let tempoChange: (from: Double, to: Double)?
    let keyChange: (from: String, to: String)?
    let timeSignatureChange: (from: String, to: String)?
    let sizeDelta: Int64
    let isEmpty: Bool
}

private func computeDiff(from prev: ActivitySnapshot, to curr: ActivitySnapshot) -> ActivitySnapshotDiff {
    let prevPlugins = Set(prev.pluginNames ?? [])
    let currPlugins = Set(curr.pluginNames ?? [])
    var addedPlugins: [String] = []
    var removedPlugins: [String] = []

    if prev.pluginNames != nil && curr.pluginNames != nil {
        addedPlugins = currPlugins.subtracting(prevPlugins).sorted()
        removedPlugins = prevPlugins.subtracting(currPlugins).sorted()
    }

    // Track plugins diff
    let prevTP = Set(prev.trackPlugins ?? [])
    let currTP = Set(curr.trackPlugins ?? [])
    var addedTrackPlugins: [ActivityTrackPlugin] = []
    var removedTrackPlugins: [ActivityTrackPlugin] = []

    if prev.trackPlugins != nil && curr.trackPlugins != nil {
        addedTrackPlugins = Array(currTP.subtracting(prevTP))
        removedTrackPlugins = Array(prevTP.subtracting(currTP))
    }

    // Track count delta
    let hasDetailed = curr.audioTrackCount != nil || prev.audioTrackCount != nil
    let totalTrackDelta: Int
    if hasDetailed {
        let audioDelta = (curr.audioTrackCount ?? 0) - (prev.audioTrackCount ?? 0)
        let midiDelta = (curr.midiTrackCount ?? 0) - (prev.midiTrackCount ?? 0)
        let returnDelta = (curr.returnTrackCount ?? 0) - (prev.returnTrackCount ?? 0)
        totalTrackDelta = audioDelta + midiDelta + returnDelta
    } else {
        totalTrackDelta = (curr.trackCount ?? 0) - (prev.trackCount ?? 0)
    }

    let tempoChange: (from: Double, to: Double)? =
        (prev.tempo != nil && curr.tempo != nil && prev.tempo != curr.tempo)
        ? (from: prev.tempo!, to: curr.tempo!) : nil

    let keyChange: (from: String, to: String)? =
        (prev.keySignature != nil && curr.keySignature != nil && prev.keySignature != curr.keySignature)
        ? (from: prev.keySignature!, to: curr.keySignature!) : nil

    let tsChange: (from: String, to: String)? =
        (prev.timeSignature != nil && curr.timeSignature != nil && prev.timeSignature != curr.timeSignature)
        ? (from: prev.timeSignature!, to: curr.timeSignature!) : nil

    let sizeDelta = curr.fileSize - prev.fileSize

    let isEmpty = addedPlugins.isEmpty && removedPlugins.isEmpty
        && addedTrackPlugins.isEmpty && removedTrackPlugins.isEmpty
        && totalTrackDelta == 0
        && tempoChange == nil && keyChange == nil && tsChange == nil
        && sizeDelta == 0

    return ActivitySnapshotDiff(
        addedPlugins: addedPlugins,
        removedPlugins: removedPlugins,
        addedTrackPlugins: addedTrackPlugins,
        removedTrackPlugins: removedTrackPlugins,
        totalTrackDelta: totalTrackDelta,
        tempoChange: tempoChange,
        keyChange: keyChange,
        timeSignatureChange: tsChange,
        sizeDelta: sizeDelta,
        isEmpty: isEmpty
    )
}

private func summarizeDiff(_ diff: ActivitySnapshotDiff) -> String {
    var parts: [String] = []
    if diff.totalTrackDelta > 0 { parts.append("\(diff.totalTrackDelta) track\(diff.totalTrackDelta != 1 ? "s" : "") added") }
    else if diff.totalTrackDelta < 0 { parts.append("\(abs(diff.totalTrackDelta)) track\(abs(diff.totalTrackDelta) != 1 ? "s" : "") removed") }
    if diff.addedPlugins.count > 0 { parts.append("\(diff.addedPlugins.count) plugin\(diff.addedPlugins.count != 1 ? "s" : "") added") }
    if diff.removedPlugins.count > 0 { parts.append("\(diff.removedPlugins.count) plugin\(diff.removedPlugins.count != 1 ? "s" : "") removed") }
    if diff.tempoChange != nil { parts.append("tempo changed") }
    if diff.keyChange != nil { parts.append("key changed") }
    if parts.isEmpty {
        return diff.sizeDelta != 0 ? "file size changed" : ""
    }
    return parts.joined(separator: ", ")
}

// MARK: - Formatters

private func formatDurationDetail(_ seconds: Int) -> String {
    let h = seconds / 3600
    let m = (seconds % 3600) / 60
    if h == 0 { return "\(m) min" }
    return m > 0 ? "\(h)h \(m)m" : "\(h)h" }

private func formatBytesDetail(_ bytes: Int64) -> String {
    let absBytes = abs(bytes)
    if absBytes < 1024 { return "\(absBytes) B" }
    if absBytes < 1024 * 1024 { return String(format: "%.1f KB", Double(absBytes) / 1024) }
    if absBytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(absBytes) / (1024 * 1024)) }
    return String(format: "%.2f GB", Double(absBytes) / (1024 * 1024 * 1024))
}
