import SwiftUI
import AppKit

/// Full detail view for a single session.
/// Renders file metadata and then delegates to format-specific sub-views
/// (AbletonDetailView / LogicDetailView) for the parsed project content.
struct SessionDetailView: View {
    let session: AudioSession
    @EnvironmentObject var scanner: ScannerService
    @EnvironmentObject var sampleCollector: SampleCollectionService
    @State private var showSampleCollection = false
    @State private var isParsing = false

    /// Always read the latest version of this session from the scanner's array,
    /// so parsed data appears immediately after `parseIndividualSession` completes.
    private var liveSession: AudioSession {
        scanner.sessions.first(where: { $0.path == session.path }) ?? session
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection()
                Divider()
                metadataSection()

                // Logic session window thumbnail
                if session.format == .logic,
                   let thumb = DAWIconLoader.logicThumbnail(forBundle: session.path) {
                    Divider()
                    DisclosureGroup("Project Window Image") {
                        Image(nsImage: thumb)
                            .resizable()
                            .scaledToFit()
                            .cornerRadius(6)
                    }
                    .font(.headline)
                    .fontWeight(.semibold)
                }

                Divider()

                switch liveSession.project {
                case .ableton(let p):
                    AbletonDetailView(project: p)
                case .logic(let p):
                    LogicDetailView(
                        project: p,
                        knownPluginMatches: liveSession.knownPluginMatches ?? [],
                        installedPluginFormats: Self.buildPluginFormatLookup(from: scanner.plugins)
                    )
                case .proTools(let p):
                    ProToolsDetailView(project: p)
                case .none:
                    VStack(spacing: 12) {
                        Text("This session file has not been parsed yet.")
                            .foregroundColor(.secondary)
                            .italic()
                        if isParsing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Parse Session") {
                                isParsing = true
                                scanner.parseIndividualSession(path: session.path) {
                                    isParsing = false
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 340)
        .sheet(isPresented: $showSampleCollection) {
            SampleCollectionView(session: session)
                .environmentObject(sampleCollector)
        }
    }

    // MARK: – Header

    private func headerSection() -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.name)
                    .font(.title)
                    .fontWeight(.bold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.format.rawValue)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                if session.isBackup {
                    Text("Backup session")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // Use session-specific DAW icon
            if let sessionIcon = DAWIconLoader.sessionIcon(for: session.format) {
                Image(nsImage: sessionIcon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
                    .cornerRadius(6)
            } else {
                Image(systemName: formatSymbol(for: session.format))
                    .font(.system(size: 40))
                    .foregroundColor(formatColor(for: session.format))
            }
        }
    }

    private func formatSymbol(for format: SessionFormat) -> String {
        switch format {
        case .ableton:  return "music.note.list"
        case .logic:    return "waveform"
        case .proTools: return "gearshape.2"
        }
    }

    private func formatColor(for format: SessionFormat) -> Color {
        switch format {
        case .ableton:  return .gray
        case .logic:    return .blue
        case .proTools: return Color(red: 0.427, green: 0.141, blue: 0.890) // #6d24e3
        }
    }

    // MARK: – File metadata

    private func metadataSection() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Path")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .gridColumnAlignment(.leading)
                    Text(session.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(session.path)
                }
                GridRow {
                    Text("Modified")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(session.modifiedDate, style: .date)
                        .font(.subheadline)
                }
                GridRow {
                    Text("Size")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(ByteCountFormatter.string(fromByteCount: Int64(session.fileSize), countStyle: .file))
                        .font(.subheadline)
                }
            }
            HStack(spacing: 10) {
                Button("Show in Finder") { showInFinder() }
                    .buttonStyle(.bordered)
                Button("Copy Path") { copyPath() }
                    .buttonStyle(.bordered)
                Button("Collect Samples") {
                    showSampleCollection = true
                }
                .buttonStyle(.borderedProminent)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// Build a format lookup keyed by both the plugin's filename and its AU description,
    /// so plugins displayed by their AU description (e.g. "UADx SSL G Bus") can still
    /// resolve to a format badge.
    private static func buildPluginFormatLookup(from plugins: [AudioPlugin]) -> [String: PluginFormat] {
        var lookup: [String: PluginFormat] = [:]
        for plugin in plugins {
            lookup[plugin.name] = plugin.format
            if let desc = plugin.auDescription {
                // First plugin to claim a description wins
                if lookup[desc] == nil {
                    lookup[desc] = plugin.format
                }
            }
        }
        return lookup
    }

    private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.path)])
    }

    private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.path, forType: .string)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Ableton detail
// ─────────────────────────────────────────────────────────────────────────────

struct AbletonDetailView: View {
    let project: AbletonProject

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Quick-stat cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    QuickStat(label: "Tempo",   value: "\(Int(project.tempo)) BPM",                          icon: "metronome")
                    QuickStat(label: "Tracks",  value: "\(project.tracks.count)",                           icon: "waveform")
                    QuickStat(label: "Clips",   value: "\(project.tracks.reduce(0) { $0 + $1.clips.count })", icon: "rectangle.stack")
                    QuickStat(label: "Samples", value: "\(project.samplePaths.count)",                      icon: "music.note")
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            Text("Live \(project.version) · \(project.usedPlugins.count) plugin(s)")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            // ── Plugins used ──────────────────────────────────
            if !project.usedPlugins.isEmpty {
                Text("Plugins Used in Project")
                    .font(.headline)
                    .fontWeight(.semibold)

                LazyVGrid(columns: [GridItem(.flexible(minimum: 140)), GridItem(.flexible(minimum: 140))], spacing: 6) {
                    ForEach(project.usedPlugins, id: \.self) { name in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                            Text(name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }

            // ── Track list ────────────────────────────────────
            Text("Tracks")
                .font(.headline)
                .fontWeight(.semibold)

            VStack(spacing: 0) {
                ForEach(0..<project.tracks.count, id: \.self) { i in
                    TrackRow(track: project.tracks[i])
                    Divider()
                }
            }
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)

            // ── Clips by track ────────────────────────────────
            if project.tracks.contains(where: { !$0.clips.isEmpty }) {
                Text("Clips")
                    .font(.headline)
                    .fontWeight(.semibold)

                VStack(spacing: 0) {
                    ForEach(0..<project.tracks.count, id: \.self) { i in
                        if !project.tracks[i].clips.isEmpty {
                            DisclosureGroup("\(project.tracks[i].name) (\(project.tracks[i].clips.count))") {
                                ForEach(0..<project.tracks[i].clips.count, id: \.self) { j in
                                    ClipRow(clip: project.tracks[i].clips[j])
                                    Divider()
                                }
                            }
                            .padding(.horizontal, 10)
                        }
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            }

            // ── Sample files ──────────────────────────────────
            if !project.samplePaths.isEmpty {
                Text("Sample Files")
                    .font(.headline)
                    .fontWeight(.semibold)

                VStack(spacing: 0) {
                    ForEach(0..<project.samplePaths.count, id: \.self) { i in
                        HStack(spacing: 8) {
                            Image(systemName: "music.note")
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            Text((project.samplePaths[i] as NSString).lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        Divider()
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            }

            if !project.projectSampleFiles.isEmpty {
                Text("Project Samples Folder")
                    .font(.headline)
                    .fontWeight(.semibold)
                VStack(spacing: 6) {
                    ForEach(project.projectSampleFiles, id: \.self) { path in
                        Text((path as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("Show Samples in Finder") { showFolder(at: project.projectRootPath, subfolder: "Samples") }
                    .buttonStyle(.bordered)
            }

            if !project.bouncedFiles.isEmpty {
                Text("Bounced Files")
                    .font(.headline)
                    .fontWeight(.semibold)
                VStack(spacing: 6) {
                    ForEach(project.bouncedFiles, id: \.self) { path in
                        Text((path as NSString).lastPathComponent)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Button("Show Bounces in Finder") { showBounceFolder(for: project.projectRootPath) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Pro Tools detail
// ─────────────────────────────────────────────────────────────────────────────

struct ProToolsDetailView: View {
    let project: ProToolsProject

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Quick-stat cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    QuickStat(label: "Sample Rate", value: project.sampleRate.map { "\($0) Hz" } ?? "\u{2014}", icon: "waveform")
                    QuickStat(label: "Audio Files", value: "\(project.audioFiles.count)", icon: "speaker.wave.2")
                    QuickStat(label: "Plugins", value: project.pluginNames.isEmpty ? "\u{2014}" : "\(project.pluginNames.count)", icon: "puzzlepiece")
                    QuickStat(label: "Size", value: ByteCountFormatter.string(fromByteCount: Int64(project.byteLength), countStyle: .file), icon: "doc")
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Signature")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text(project.signatureHex.isEmpty ? "Unknown" : project.signatureHex)
                        .font(.caption)
                }
            }

            // Plugin names
            if !project.pluginNames.isEmpty {
                Divider()
                Text("Plugin Hints")
                    .font(.headline)
                    .fontWeight(.semibold)
                LazyVGrid(columns: [GridItem(.flexible(minimum: 140)), GridItem(.flexible(minimum: 140))], spacing: 6) {
                    ForEach(project.pluginNames, id: \.self) { name in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.purple)
                                .frame(width: 6, height: 6)
                            Text(name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            }

            if !project.audioFiles.isEmpty {
                Divider()
                Text("Audio Files")
                    .font(.headline)
                    .fontWeight(.semibold)
                VStack(spacing: 0) {
                    ForEach(project.audioFiles, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "speaker.wave.2")
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            Text((path as NSString).lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        Divider()
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                Button("Show Audio Files in Finder") {
                    showFolder(at: project.projectRootPath, subfolder: "Audio Files")
                }
                .buttonStyle(.bordered)
            }

            if !project.bouncedFiles.isEmpty {
                Divider()
                Text("Bounced Files")
                    .font(.headline)
                    .fontWeight(.semibold)
                VStack(spacing: 0) {
                    ForEach(project.bouncedFiles, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            Text((path as NSString).lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        Divider()
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                Button("Show Bounced Files in Finder") {
                    showFolder(at: project.projectRootPath, subfolder: "Bounced Files")
                }
                .buttonStyle(.bordered)
            }

            if !project.videoFiles.isEmpty {
                Divider()
                Text("Video Files")
                    .font(.headline)
                    .fontWeight(.semibold)
                VStack(spacing: 0) {
                    ForEach(project.videoFiles, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "film")
                                .foregroundColor(.orange)
                                .frame(width: 16)
                            Text((path as NSString).lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        Divider()
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                Button("Show Video Files in Finder") {
                    showFolder(at: project.projectRootPath, subfolder: "Video Files")
                }
                .buttonStyle(.bordered)
            }

            if !project.renderedFiles.isEmpty {
                Divider()
                Text("Rendered Files")
                    .font(.headline)
                    .fontWeight(.semibold)
                VStack(spacing: 0) {
                    ForEach(project.renderedFiles, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.circle")
                                .foregroundColor(.green)
                                .frame(width: 16)
                            Text((path as NSString).lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        Divider()
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
                Button("Show Rendered Files in Finder") {
                    showFolder(at: project.projectRootPath, subfolder: "Rendered Files")
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Logic detail
// ─────────────────────────────────────────────────────────────────────────────

struct LogicDetailView: View {
    let project: LogicProject
    let knownPluginMatches: [PluginMatch]
    let installedPluginFormats: [String: PluginFormat]

    // MARK: – Computed display values

    private var sampleRateDisplay: String {
        guard let sr = project.sampleRate else { return "\u{2014}" }
        switch sr {
        case 44100: return "44.1 kHz"
        case 48000: return "48 kHz"
        case 88200: return "88.2 kHz"
        case 96000: return "96 kHz"
        case 176400: return "176.4 kHz"
        case 192000: return "192 kHz"
        default: return sr >= 1000 ? "\(Double(sr) / 1000.0) kHz" : "\(sr) Hz"
        }
    }

    private var keyDisplay: String {
        guard let key = project.songKey else { return "\u{2014}" }
        if let scale = project.songScale {
            let abbr = scale == "major" ? "maj" : scale == "minor" ? "min" : scale
            return "\(key) \(abbr)"
        }
        return key
    }

    private var timeSigDisplay: String {
        guard let num = project.timeSignatureNumerator,
              let den = project.timeSignatureDenominator else { return "\u{2014}" }
        return "\(num)/\(den)"
    }

    /// Ordered track list: each entry has (channelStrip, userTrackName, plugins)
    /// Sorted by channel type then number for logical ordering.
    private var trackList: [(channel: String, name: String, plugins: [String])] {
        // Gather all channel strips mentioned in either trackNames or trackPlugins
        var allChannels = Set(project.trackNames.keys)
        allChannels.formUnion(project.trackPlugins.keys)

        return allChannels.sorted { a, b in
            channelSortKey(a) < channelSortKey(b)
        }.map { channel in
            let name = project.trackNames[channel] ?? channel
            let plugins = project.trackPlugins[channel] ?? []
            return (channel, name, plugins)
        }
    }

    /// All unique plugin names across all tracks + known matches, deduplicated.
    /// Both sources now resolve names from the same AU identity index, so
    /// exact case-insensitive dedup produces clean results without heuristics.
    private var allIdentifiedPlugins: [(name: String, confidence: PluginMatchConfidence?)] {
        var seen: Set<String> = []
        var result: [(String, PluginMatchConfidence?)] = []

        // Known plugin matches (highest confidence first)
        for match in knownPluginMatches.sorted(by: { $0.confidence < $1.confidence }) {
            let key = match.name.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                result.append((match.name, match.confidence))
            }
        }

        // Plugins identified from embedded plists (per-track)
        for (_, plugins) in project.trackPlugins {
            for plugin in plugins {
                let key = plugin.lowercased()
                if !seen.contains(key) {
                    seen.insert(key)
                    result.append((plugin, .auCodeMatch))
                }
            }
        }

        return result
    }

    /// All instrument resource files flattened with type prefixes
    private var instrumentResources: [(type: String, name: String)] {
        var items: [(String, String)] = []
        for name in project.samplerInstrumentFiles ?? [] { items.append(("Sampler", name)) }
        for name in project.alchemyFiles ?? [] { items.append(("Alchemy", name)) }
        for name in project.impulseResponseFiles ?? [] { items.append(("IR", name)) }
        for name in project.quicksamplerFiles ?? [] { items.append(("Quick Sampler", name)) }
        for name in project.ultrabeatFiles ?? [] { items.append(("Ultrabeat", name)) }
        return items
    }

    /// Summary line
    private var summaryParts: [String] {
        var parts: [String] = []
        if let tc = project.trackCount, tc > 0 { parts.append("\(tc) tracks") }
        if !allIdentifiedPlugins.isEmpty {
            parts.append("\(allIdentifiedPlugins.count) plugin(s)")
        } else if !project.pluginHints.isEmpty {
            parts.append("\(project.pluginHints.count) plugin hint(s)")
        }
        if !project.mediaFiles.isEmpty { parts.append("\(project.mediaFiles.count) audio files") }
        return parts
    }

    private var hasARADisplay: String? {
        guard let has = project.hasARAPlugins else { return nil }
        return has ? "Yes" : "No"
    }

    // MARK: – Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── 1. Quick-stat cards ─────────────────────────
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    QuickStat(label: "Tempo", value: project.tempo.map { "\(Int($0)) BPM" } ?? "\u{2014}", icon: "metronome")
                    QuickStat(label: "Tracks", value: project.trackCount.map { "\($0)" } ?? "\u{2014}", icon: "slider.horizontal.3")
                    QuickStat(label: "Sample Rate", value: sampleRateDisplay, icon: "waveform")
                    if project.songKey != nil {
                        QuickStat(label: "Key", value: keyDisplay, icon: "music.note")
                    }
                    if project.timeSignatureNumerator != nil {
                        QuickStat(label: "Time Sig", value: timeSigDisplay, icon: "clock")
                    }
                    if project.hasARAPlugins == true {
                        QuickStat(label: "ARA", value: "Yes", icon: "link")
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            // ── Summary line ────────────────────────────────
            if !summaryParts.isEmpty || project.logicVersion != nil {
                HStack(spacing: 4) {
                    if !summaryParts.isEmpty {
                        Text(summaryParts.joined(separator: " \u{00B7} "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if let version = project.logicVersion {
                        if !summaryParts.isEmpty {
                            Text("\u{00B7}")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Text(version)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }

            // ── 2. Identified plugins (all sources) ─────────
            if !allIdentifiedPlugins.isEmpty {
                Divider()
                Text("Plugins Used in Project")
                    .font(.headline)
                    .fontWeight(.semibold)

                LazyVGrid(columns: [GridItem(.flexible(minimum: 140)), GridItem(.flexible(minimum: 140))], spacing: 6) {
                    ForEach(0..<allIdentifiedPlugins.count, id: \.self) { i in
                        let plugin = allIdentifiedPlugins[i]
                        let matchedFormat = lookupPluginFormat(plugin.name)
                        HStack(spacing: 6) {
                            Circle()
                                .fill(matchedFormat != nil ? pluginFormatColor(matchedFormat!) : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(plugin.name)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let fmt = matchedFormat {
                                Text(fmt.rawValue)
                                    .font(.caption2)
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(pluginFormatColor(fmt).opacity(0.2))
                                    .foregroundColor(pluginFormatColor(fmt))
                                    .cornerRadius(3)
                            }
                        }
                    }
                }
            }

            // ── 3. Tracks with plugins ──────────────────────
            if !trackList.isEmpty {
                Divider()
                Text("Tracks")
                    .font(.headline)
                    .fontWeight(.semibold)

                VStack(spacing: 0) {
                    ForEach(0..<trackList.count, id: \.self) { i in
                        LogicTrackRow(
                            channel: trackList[i].channel,
                            name: trackList[i].name,
                            plugins: trackList[i].plugins
                        )
                        if i < trackList.count - 1 { Divider() }
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)
            }

            // ── 4. Alternatives ─────────────────────────────
            if project.alternatives.count > 1 {
                Divider()
                Text("Alternatives (\(project.alternatives.count))")
                    .font(.headline)
                    .fontWeight(.semibold)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(project.alternatives, id: \.self) { alt in
                        HStack(spacing: 6) {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.secondary)
                                .frame(width: 16)
                            Text(alt)
                                .font(.subheadline)
                        }
                    }
                }
            }

            // ── 5. Instrument Resources ─────────────────────
            if !instrumentResources.isEmpty {
                Divider()
                DisclosureGroup("Instrument Resources (\(instrumentResources.count))") {
                    VStack(spacing: 0) {
                        ForEach(0..<instrumentResources.count, id: \.self) { i in
                            HStack(spacing: 8) {
                                Text(instrumentResources[i].type)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .frame(width: 70, alignment: .leading)
                                Text(instrumentResources[i].name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 10)
                            if i < instrumentResources.count - 1 { Divider() }
                        }
                    }
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
                .font(.headline)
                .fontWeight(.semibold)
            }

            // ── 6. Bounced files ────────────────────────────
            if !project.bouncedFiles.isEmpty {
                Divider()
                Text("Bounced Files (\(project.bouncedFiles.count))")
                    .font(.headline)
                    .fontWeight(.semibold)

                VStack(spacing: 0) {
                    ForEach(0..<project.bouncedFiles.count, id: \.self) { i in
                        HStack(spacing: 8) {
                            Image(systemName: "waveform")
                                .foregroundColor(.accentColor)
                                .frame(width: 16)
                            Text((project.bouncedFiles[i] as NSString).lastPathComponent)
                                .font(.subheadline)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                        .padding(.vertical, 5)
                        .padding(.horizontal, 10)
                        Divider()
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .cornerRadius(8)

                Button("Show Bounces in Finder") { showLogicBounces(at: project.path) }
                    .buttonStyle(.bordered)
            }

            // ── 7. Media files (collapsed if many) ──────────
            if !project.mediaFiles.isEmpty {
                Divider()
                DisclosureGroup("Media Files (\(project.mediaFiles.count))") {
                    VStack(spacing: 0) {
                        ForEach(0..<project.mediaFiles.count, id: \.self) { i in
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.2")
                                    .foregroundColor(.accentColor)
                                    .frame(width: 16)
                                Text((project.mediaFiles[i] as NSString).lastPathComponent)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            if i < project.mediaFiles.count - 1 { Divider() }
                        }
                    }
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
                .font(.headline)
                .fontWeight(.semibold)
            }

            // ── 8. MIDI files ───────────────────────────────
            if !project.midiFiles.isEmpty {
                Divider()
                DisclosureGroup("MIDI Files (\(project.midiFiles.count))") {
                    VStack(spacing: 0) {
                        ForEach(0..<project.midiFiles.count, id: \.self) { i in
                            HStack(spacing: 8) {
                                Image(systemName: "pianokeys")
                                    .foregroundColor(.purple)
                                    .frame(width: 16)
                                Text((project.midiFiles[i] as NSString).lastPathComponent)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            if i < project.midiFiles.count - 1 { Divider() }
                        }
                    }
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(8)
                }
                .font(.headline)
                .fontWeight(.semibold)
            }

            // ── 9. AU Plugin Hints (raw codes, collapsed) ───
            if !project.pluginHints.isEmpty {
                Divider()
                DisclosureGroup("AU Plugin Hints (\(project.pluginHints.count))") {
                    LazyVGrid(columns: [GridItem(.flexible(minimum: 140)), GridItem(.flexible(minimum: 140))], spacing: 6) {
                        ForEach(project.pluginHints, id: \.self) { hint in
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color.secondary)
                                    .frame(width: 6, height: 6)
                                Text(hint)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                    }
                }
                .font(.headline)
                .fontWeight(.semibold)
            }

            // ── 10. Unused audio files ──────────────────────
            if let unused = project.unusedAudioFiles, !unused.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(0..<unused.count, id: \.self) { i in
                            HStack(spacing: 8) {
                                Image(systemName: "speaker.wave.2")
                                    .foregroundColor(.orange)
                                    .frame(width: 16)
                                Text(unused[i])
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                            }
                            .padding(.vertical, 5)
                            .padding(.horizontal, 10)
                            if i < unused.count - 1 { Divider() }
                        }
                    }
                    .background(Color.orange.opacity(0.05))
                    .cornerRadius(8)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundColor(.orange)
                        Text("Unused Audio Files (\(unused.count))")
                    }
                }
                .font(.headline)
                .fontWeight(.semibold)
            }

            // ── 11. Raw metadata (collapsed) ────────────────
            if !filteredMetadata.isEmpty {
                Divider()
                DisclosureGroup("All Metadata (\(filteredMetadata.count))") {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ForEach(filteredMetadata, id: \.key) { key, value in
                            GridRow {
                                Text(key)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text(value)
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .font(.headline)
                .fontWeight(.semibold)
            }

            // ── Empty state ─────────────────────────────────
            if project.trackCount == nil && trackList.isEmpty && project.metadata.isEmpty
                && project.mediaFiles.isEmpty && project.midiFiles.isEmpty
                && project.pluginHints.isEmpty && allIdentifiedPlugins.isEmpty {
                Text("Logic Pro uses a proprietary binary format. Full track and plugin analysis requires opening the session in Logic Pro.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: – Helpers

    private func pluginConfidenceColor(_ confidence: PluginMatchConfidence?) -> Color {
        switch confidence {
        case .auCodeMatch, .bundleIdMatch: return .green
        case .nameMatch: return .blue
        case .none: return .secondary
        }
    }

    /// Look up the format of a plugin by its display name.
    private func lookupPluginFormat(_ name: String) -> PluginFormat? {
        installedPluginFormats[name]
    }

    private func pluginFormatColor(_ format: PluginFormat) -> Color {
        switch format {
        case .audioUnit: return Color(red: 0.98, green: 0.85, blue: 0.93)
        case .vst:       return Color(red: 0.60, green: 0.80, blue: 0.95)
        case .vst3:      return Color(red: 0.62, green: 0.86, blue: 0.74)
        case .aax:       return Color(red: 0.99, green: 0.95, blue: 0.85)
        }
    }

    /// Sort key for channel strip ordering: Audio < Inst < Aux < Bus < Output
    private func channelSortKey(_ channel: String) -> (Int, Int) {
        let parts = channel.split(separator: " ", maxSplits: 1)
        let prefix = String(parts.first ?? "")
        let num = parts.count > 1 ? (Int(parts[1].split(separator: "-").first ?? "") ?? 999) : 999

        let order: Int
        switch prefix {
        case "Audio": order = 0
        case "Inst":  order = 1
        case "Aux":   order = 2
        case "Bus":   order = 3
        case "Output": order = 4
        default: order = 5
        }
        return (order, num)
    }

    /// Metadata keys already displayed elsewhere
    private static let displayedKeys: Set<String> = [
        "BeatsPerMinute", "SampleRate", "NumberOfTracks",
        "SongKey", "SongGenderKey", "SongSignatureNumerator", "SongSignatureDenominator",
        "AudioFiles", "SamplerInstrumentsFiles", "AlchemyFiles",
        "ImpulsResponsesFiles", "QuicksamplerFiles", "UltrabeatFiles",
        "PlaybackFiles", "UnusedAudioFiles", "SignatureKey", "Version",
    ]

    private var filteredMetadata: [(key: String, value: String)] {
        project.metadata
            .filter { !Self.displayedKeys.contains($0.key) }
            .sorted { $0.key < $1.key }
    }
}

// MARK: – Logic track row

/// A single track row for the Logic track list, showing channel strip, user name, and plugins.
private struct LogicTrackRow: View {
    let channel: String
    let name: String
    let plugins: [String]

    private var isRenamed: Bool { name != channel }

    private var trackIcon: String {
        if channel.hasPrefix("Audio") { return "speaker.wave.2" }
        if channel.hasPrefix("Inst")  { return "pianokeys" }
        if channel.hasPrefix("Aux")   { return "arrow.turn.left.up" }
        if channel.hasPrefix("Bus")   { return "arrow.triangle.branch" }
        if channel.hasPrefix("Output") { return "dial.high" }
        return "waveform"
    }

    private var trackColor: Color {
        if channel.hasPrefix("Audio") { return .blue }
        if channel.hasPrefix("Inst")  { return .purple }
        if channel.hasPrefix("Aux")   { return .green }
        if channel.hasPrefix("Bus")   { return .orange }
        if channel.hasPrefix("Output") { return .red }
        return .secondary
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: trackIcon)
                .foregroundColor(trackColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isRenamed {
                        Text(channel)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                if !plugins.isEmpty {
                    Text(plugins.joined(separator: ", "))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }
}

// MARK: – Finder helpers

private func showFolder(at root: String, subfolder: String) {
    let url = URL(fileURLWithPath: root).appendingPathComponent(subfolder)
    if FileManager.default.fileExists(atPath: url.path) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private func showBounceFolder(for root: String) {
    let candidates = ["Bounces", "Bounced Files"]
    for name in candidates {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
    }
}

private func showLogicBounces(at projectPath: String) {
    let candidates = ["Bounces", "Bounced Files", "Contents/Bounces", "Contents/Bounced Files"]
    for name in candidates {
        let url = URL(fileURLWithPath: projectPath).appendingPathComponent(name)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: – Shared sub-components
// ─────────────────────────────────────────────────────────────────────────────

/// A small stat tile used in the Ableton quick-stats row.
struct QuickStat: View {
    let label: String
    let value: String
    let icon:  String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(.accentColor)
            Text(value)
                .font(.body)
                .fontWeight(.semibold)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }
}

/// A single track row inside the Ableton track list.
struct TrackRow: View {
    let track: AbletonTrack

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: trackIcon)
                .foregroundColor(trackColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !captionText.isEmpty {
                    Text(captionText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer()

            if track.isMuted {
                Text("muted")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    // MARK: – Caption

    private var captionText: String {
        var parts: [String] = []
        if !track.plugins.isEmpty { parts.append(track.plugins.joined(separator: ", ")) }
        if !track.clips.isEmpty   { parts.append("\(track.clips.count) clip\(track.clips.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: – Icon / colour helpers

    private var trackIcon: String {
        switch track.type {
        case .audio:        return "speaker.wave.2"
        case .midi:         return "pianokeys"
        case .beatBassline: return "drum"
        case .returnTrack:  return "arrow.turn.left.up"
        case .master:       return "dial.high"
        }
    }

    private var trackColor: Color {
        switch track.type {
        case .audio:        return .blue
        case .midi:         return .purple
        case .beatBassline: return .orange
        case .returnTrack:  return .green
        case .master:       return .red
        }
    }
}

/// A single clip entry inside a track's disclosure group.
struct ClipRow: View {
    let clip: AbletonClip

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(clipColor).frame(width: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(clip.name)
                    .font(.subheadline)
                if let path = clip.samplePath {
                    Text((path as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text(clip.type.rawValue)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 5)
    }

    private var clipColor: Color {
        switch clip.type {
        case .audio:        return .blue
        case .midi:         return .purple
        case .automation:   return .green
        }
    }
}
