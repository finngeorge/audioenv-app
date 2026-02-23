import SwiftUI
import AppKit

/// Sort options for the bounce list.
enum BounceSortOption: String, CaseIterable {
    case name = "Name"
    case dateModified = "Date Modified"
    case bpm = "BPM"
    case duration = "Duration"
}

/// Content column view for the Bounces sidebar entry.
/// Shows linked folders, bounce list with filters, and scan controls.
struct BounceBrowserView: View {
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var audioPlayer: AudioPlayerService

    @Binding var selectedBounce: Bounce?

    @State private var search = ""
    @State private var formatFilter: String? = nil
    @State private var linkedFilter: Bool? = nil
    @State private var folderFilter: UUID? = nil
    @State private var showLinkFolderPrompt = false
    @State private var filteredBounces: [Bounce] = []
    @State private var availableFormats: [String] = []

    // Sort state
    @State private var sortOption: BounceSortOption = .dateModified
    @State private var sortAscending = false

    // Metadata filter state
    @State private var stageFilter: String? = nil
    @State private var keyFilter: String? = nil
    @State private var bpmMin: String = ""
    @State private var bpmMax: String = ""
    @State private var versionFilter: Int? = nil
    @State private var showMetadataFilters = false

    // Dynamic filter options derived from current bounces
    @State private var availableKeys: [String] = []
    @State private var availableVersions: [Int] = []
    @State private var availableStages: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Search bar + actions
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search bounces...", text: $search)
                    .textFieldStyle(.roundedBorder)

                // Play all button
                if !filteredBounces.isEmpty {
                    Button {
                        audioPlayer.playAll(bounces: filteredBounces)
                    } label: {
                        Label("Play All", systemImage: "play.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Sort picker
                Picker("Sort", selection: $sortOption) {
                    ForEach(BounceSortOption.allCases, id: \.self) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 120)

                // Sort direction toggle
                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(sortAscending ? "Ascending" : "Descending")

                // Link folder button
                Button {
                    showLinkFolderPrompt = true
                } label: {
                    Label("Link Folder", systemImage: "folder.badge.plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)

            // Format filter (only when multiple formats exist)
            if availableFormats.count > 1 {
                Picker("Format", selection: $formatFilter) {
                    Text("All").tag(nil as String?)
                    ForEach(availableFormats, id: \.self) { fmt in
                        Text(fmt.uppercased()).tag(fmt as String?)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal)
                .padding(.top, 4)
            }

            // Folder filter chips
            if !bounceService.bounceFolders.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        folderChip(label: "All Folders", folderId: nil)
                        ForEach(bounceService.bounceFolders) { folder in
                            folderChip(label: folder.displayName, folderId: folder.id)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 30)
                .padding(.top, 4)
            }

            // Metadata filters toggle
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showMetadataFilters.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                    Text("Filters")
                        .font(.caption)
                    Image(systemName: showMetadataFilters ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                    if hasActiveMetadataFilters {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 6, height: 6)
                    }
                }
                .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .padding(.horizontal)
            .padding(.top, 4)

            if showMetadataFilters {
                VStack(spacing: 6) {
                    // Stage filter chips
                    if !availableStages.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                stageChip(label: "All Stages", stage: nil)
                                ForEach(availableStages, id: \.self) { stage in
                                    stageChip(label: stage, stage: stage)
                                }
                            }
                            .padding(.horizontal)
                        }
                        .frame(height: 26)
                    }

                    HStack(spacing: 12) {
                        // Key filter
                        if !availableKeys.isEmpty {
                            Picker("Key", selection: $keyFilter) {
                                Text("All Keys").tag(nil as String?)
                                ForEach(availableKeys, id: \.self) { key in
                                    Text(key).tag(key as String?)
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(maxWidth: 100)
                        }

                        // BPM range
                        HStack(spacing: 4) {
                            Text("BPM")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Min", text: $bpmMin)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .controlSize(.small)
                            Text("–")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("Max", text: $bpmMax)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 50)
                                .controlSize(.small)
                        }

                        // Version filter
                        if !availableVersions.isEmpty {
                            Picker("Version", selection: $versionFilter) {
                                Text("All Versions").tag(nil as Int?)
                                ForEach(availableVersions, id: \.self) { ver in
                                    Text("v\(ver)").tag(ver as Int?)
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .frame(maxWidth: 120)
                        }

                        Spacer()
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.03))
            }

            Divider().padding(.top, 4)

            // Bounce list
            if bounceService.isLoading && bounceService.bounces.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading bounces...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if bounceService.bounceFolders.isEmpty {
                emptyFoldersState()
            } else if filteredBounces.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Bounces")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text(bounceService.isScanning
                         ? "Scanning..."
                         : "No audio files found in linked folders.\nTry scanning your folders.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredBounces, selection: $selectedBounce) { bounce in
                    HStack {
                        if bounce.isLocallyAvailable {
                            Button {
                                if audioPlayer.currentBounce?.id == bounce.id {
                                    audioPlayer.togglePlayPause()
                                } else {
                                    audioPlayer.play(bounce: bounce)
                                }
                            } label: {
                                Image(systemName: audioPlayer.currentBounce?.id == bounce.id && audioPlayer.isPlaying
                                      ? "pause.circle.fill" : "play.circle")
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                        BounceRow(bounce: bounce)
                    }
                    .contentShape(Rectangle())
                    .tag(bounce)
                    .onTapGesture(count: 2) {
                        guard bounce.isLocallyAvailable else { return }
                        if audioPlayer.currentBounce?.id == bounce.id {
                            audioPlayer.togglePlayPause()
                        } else {
                            audioPlayer.play(bounce: bounce)
                        }
                    }
                }
                .listStyle(.inset)
            }

            // Scanning indicator
            if bounceService.isScanning {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Scanning folders...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                .background(Color.blue.opacity(0.05))
            }
        }
        .task {
            if let token = try? await auth.validToken() {
                await bounceService.fetchFolders(token: token)
                await bounceService.fetchBounces(token: token)
                await bounceService.scanAllAutoFolders(token: token)
                await bounceService.fetchSuggestions(token: token)
            }
        }
        .sheet(isPresented: $showLinkFolderPrompt) {
            LinkBounceFolderSheet()
        }
        .onChange(of: search) { _, _ in refilter() }
        .onChange(of: formatFilter) { _, _ in refilter() }
        .onChange(of: folderFilter) { _, _ in refilter() }
        .onChange(of: sortOption) { _, _ in refilter() }
        .onChange(of: sortAscending) { _, _ in refilter() }
        .onChange(of: stageFilter) { _, _ in refilter() }
        .onChange(of: keyFilter) { _, _ in refilter() }
        .onChange(of: bpmMin) { _, _ in refilter() }
        .onChange(of: bpmMax) { _, _ in refilter() }
        .onChange(of: versionFilter) { _, _ in refilter() }
        .onChange(of: bounceService.bounces) { _, _ in refilter() }
        .onAppear { refilter() }
    }

    private var hasActiveMetadataFilters: Bool {
        stageFilter != nil || keyFilter != nil || versionFilter != nil || !bpmMin.isEmpty || !bpmMax.isEmpty
    }

    private func refilter() {
        let q = search.lowercased()
        let parsedBpmMin = Int(bpmMin)
        let parsedBpmMax = Int(bpmMax)

        var results = bounceService.bounces.filter { bounce in
            if let ff = formatFilter, bounce.format != ff { return false }
            if let folderId = folderFilter, bounce.bounceFolderId != folderId { return false }
            if !q.isEmpty, !bounce.fileName.lowercased().contains(q) { return false }
            if let sf = stageFilter, bounce.stage != sf { return false }
            if let kf = keyFilter, bounce.musicalKey != kf { return false }
            if let vf = versionFilter, bounce.version != vf { return false }
            if let minBpm = parsedBpmMin {
                guard let bounceBpm = bounce.bpm, bounceBpm >= minBpm else { return false }
            }
            if let maxBpm = parsedBpmMax {
                guard let bounceBpm = bounce.bpm, bounceBpm <= maxBpm else { return false }
            }
            return true
        }

        // Sort
        results.sort { a, b in
            let cmp: Bool
            switch sortOption {
            case .name:
                cmp = a.fileName.localizedCaseInsensitiveCompare(b.fileName) == .orderedAscending
            case .dateModified:
                cmp = a.fileModifiedAt < b.fileModifiedAt
            case .bpm:
                cmp = (a.bpm ?? 0) < (b.bpm ?? 0)
            case .duration:
                cmp = (a.durationSeconds ?? 0) < (b.durationSeconds ?? 0)
            }
            return sortAscending ? cmp : !cmp
        }

        filteredBounces = results

        // Derive dynamic filter options from all bounces
        let allBounces = bounceService.bounces
        let formats = Set(allBounces.map { $0.format })
        let order = ["wav", "mp3", "aiff", "flac", "m4a"]
        availableFormats = order.filter { formats.contains($0) }
        availableKeys = Set(allBounces.compactMap { $0.musicalKey }).sorted()
        availableVersions = Set(allBounces.compactMap { $0.version }).sorted()
        availableStages = Set(allBounces.compactMap { $0.stage }).sorted()
    }

    private func emptyFoldersState() -> some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Bounce Folders Linked")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Link a folder containing your audio bounces\n(WAV, MP3, AIFF, FLAC, M4A)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
            Button("Link Folder") {
                showLinkFolderPrompt = true
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func folderChip(label: String, folderId: UUID?) -> some View {
        Button {
            folderFilter = folderId
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(folderFilter == folderId ? Color.blue : Color.secondary.opacity(0.1))
                .foregroundColor(folderFilter == folderId ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func stageChip(label: String, stage: String?) -> some View {
        Button {
            stageFilter = stage
        } label: {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(stageFilter == stage ? ColorTokens.shared.badgeStage : Color.secondary.opacity(0.1))
                .foregroundColor(stageFilter == stage ? .white : .primary)
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Bounce Row

private struct BounceRow: View {
    let bounce: Bounce

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(bounce.fileName)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !bounce.isLocallyAvailable {
                    Image(systemName: "cloud")
                        .font(.caption)
                        .foregroundColor(.blue)
                        .help("Uploaded from another device")
                }

                Spacer()
                Text(bounce.format.uppercased())
                    .font(.caption)
                    .padding(.init(top: 2, leading: 6, bottom: 2, trailing: 6))
                    .background(ColorTokens.shared.bounceFormatColor(bounce.format).opacity(0.15))
                    .foregroundColor(ColorTokens.shared.bounceFormatColor(bounce.format))
                    .cornerRadius(4)
            }

            HStack(spacing: 12) {
                if !bounce.isLocallyAvailable {
                    Text("Cloud")
                        .font(.caption)
                        .foregroundColor(.blue)
                }

                Text(bounce.formattedSize)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let dur = bounce.formattedDuration {
                    Text(dur)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let sr = bounce.formattedSampleRate {
                    Text(sr)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let bd = bounce.bitDepth {
                    Text("\(bd)-bit")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                if let br = bounce.formattedBitrate {
                    Text(br)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let bpm = bounce.bpm {
                    metadataBadge("\(bpm) bpm", ColorTokens.shared.badgeBPM)
                }
                if let key = bounce.musicalKey {
                    metadataBadge(key, ColorTokens.shared.badgeKey)
                }
                if let stage = bounce.stage {
                    metadataBadge(stage, ColorTokens.shared.badgeStage)
                }
                if let version = bounce.version {
                    metadataBadge("v\(version)", ColorTokens.shared.badgeVersion)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func metadataBadge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(3)
    }

}

// MARK: - Link Bounce Folder Sheet

struct LinkBounceFolderSheet: View {
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var folderPath = ""
    @State private var autoScan = true

    var body: some View {
        VStack(spacing: 20) {
            Text("Link Bounce Folder")
                .font(.title2)
                .bold()

            Text("Select a folder that contains your audio bounces/exports.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(folderPath.isEmpty ? "No folder selected" : folderPath)
                        .font(.caption)
                        .foregroundStyle(folderPath.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Browse...") {
                        browseFolder()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)

                Toggle("Auto-scan for new files", isOn: $autoScan)
                    .font(.subheadline)

                Text("When enabled, this folder will be monitored for new audio files and scanned automatically.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Existing folders
            if !bounceService.bounceFolders.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Linked Folders")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(bounceService.bounceFolders) { folder in
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                                .font(.caption)
                            Text(folder.displayName)
                                .font(.caption)
                            Spacer()
                            if folder.autoScan {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Link Folder") {
                    Task {
                        if let token = auth.authToken {
                            await bounceService.linkFolder(path: folderPath, autoScan: autoScan, token: token)
                        }
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(folderPath.isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 450)
    }

    private func browseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing audio bounces"

        if panel.runModal() == .OK, let url = panel.urls.first {
            folderPath = url.path
        }
    }
}
