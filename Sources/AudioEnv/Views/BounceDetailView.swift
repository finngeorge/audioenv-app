import SwiftUI

/// Detail view for a selected bounce — shows audio metadata, linked projects, suggestions.
struct BounceDetailPanel: View {
    let bounce: Bounce
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var backup: BackupService

    @State private var showMetadataEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: bounce.isLocallyAvailable ? "waveform" : "cloud")
                            .font(.system(size: 40))
                            .foregroundColor(bounce.isLocallyAvailable ? formatColor : .blue)
                        Spacer()
                    }
                    Text(bounce.fileName)
                        .font(.title)
                        .fontWeight(.bold)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(bounce.format.uppercased())
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(formatColor.opacity(0.15))
                            .foregroundColor(formatColor)
                            .cornerRadius(4)
                        if !bounce.isLocallyAvailable {
                            Text("Cloud")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.blue.opacity(0.15))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                    }
                }
                .padding(.bottom, 8)

                // Action buttons
                HStack(spacing: 8) {
                    if bounce.isLocallyAvailable {
                        Button {
                            if audioPlayer.currentBounce?.id == bounce.id {
                                audioPlayer.togglePlayPause()
                            } else {
                                audioPlayer.play(bounce: bounce)
                            }
                        } label: {
                            HStack {
                                Image(systemName: audioPlayer.currentBounce?.id == bounce.id && audioPlayer.isPlaying
                                      ? "pause.circle.fill" : "play.circle.fill")
                                Text(audioPlayer.currentBounce?.id == bounce.id && audioPlayer.isPlaying ? "Pause" : "Play")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }

                    Button {
                        let url = "https://audioenv.com/share/bounce/\(bounce.id.uuidString)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    if bounce.isLocallyAvailable {
                        Button {
                            Task {
                                await backup.backupBounce(bounce)
                            }
                        } label: {
                            Label("Backup to Cloud", systemImage: "icloud.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(backup.isUploading)
                    }
                }

                // Cloud bounce banner
                if !bounce.isLocallyAvailable {
                    HStack(spacing: 12) {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.title3)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Uploaded from another device")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text("This bounce was uploaded via the web and isn't available locally. Download it to play or open in your DAW.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(Color.blue.opacity(0.08))
                    .cornerRadius(12)

                    Button {
                        Task {
                            if let token = auth.authToken {
                                await bounceService.downloadBounce(bounce, token: token)
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.down.circle.fill")
                            Text(bounceService.isDownloading ? "Downloading..." : "Download to Downloads Folder")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(bounceService.isDownloading)
                }

                Divider()

                // Audio metadata
                VStack(alignment: .leading, spacing: 12) {
                    Text("Audio Details")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    if let dur = bounce.formattedDuration {
                        InfoRow(label: "Duration", value: dur)
                    }
                    if let sr = bounce.formattedSampleRate {
                        InfoRow(label: "Sample Rate", value: sr)
                    }
                    if let bd = bounce.bitDepth {
                        InfoRow(label: "Bit Depth", value: "\(bd)-bit")
                    }
                    if let br = bounce.formattedBitrate {
                        InfoRow(label: "Bitrate", value: br)
                    }
                    InfoRow(label: "File Size", value: bounce.formattedSize)
                    InfoRow(label: "Format", value: bounce.format.uppercased())
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Extracted metadata
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Metadata")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {
                            showMetadataEditor = true
                        } label: {
                            Label("Edit", systemImage: "pencil")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if bounce.bpm != nil || bounce.musicalKey != nil || bounce.stage != nil || bounce.version != nil {
                        if let bpm = bounce.bpm {
                            InfoRow(label: "BPM", value: "\(bpm)")
                        }
                        if let key = bounce.musicalKey {
                            InfoRow(label: "Key", value: key)
                        }
                        if let stage = bounce.stage {
                            InfoRow(label: "Stage", value: stage.capitalized)
                        }
                        if let version = bounce.version {
                            InfoRow(label: "Version", value: "v\(version)")
                        }
                    } else {
                        Text("No metadata extracted. Click Edit to add manually.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // File info
                VStack(alignment: .leading, spacing: 12) {
                    Text("File Info")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    InfoRow(label: "File Name", value: bounce.fileName)
                    InfoRow(label: "Path", value: bounce.isLocallyAvailable ? bounce.filePath : "Not available locally")

                    let formatter = DateFormatter()
                    let _ = formatter.dateStyle = .medium
                    let _ = formatter.timeStyle = .short

                    InfoRow(label: "Modified", value: formatter.string(from: bounce.fileModifiedAt))

                    HStack(spacing: 8) {
                        if bounce.isLocallyAvailable {
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting(
                                    [URL(fileURLWithPath: bounce.filePath)]
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bounce.filePath, forType: .string)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Suggestions
                let bounceSuggestions = bounceService.suggestions.filter { $0.bounceId == bounce.id.uuidString }
                if !bounceSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Suggested Links")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        ForEach(bounceSuggestions) { suggestion in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.projectName)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Confidence: \(Int(suggestion.confidence * 100))%")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("Link") {
                                    Task {
                                        if let token = auth.authToken {
                                            await bounceService.confirmSuggestion(
                                                bounceId: suggestion.bounceId,
                                                sessionId: suggestion.scannedSessionId,
                                                token: token
                                            )
                                        }
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(8)
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)
                }

                Spacer()
            }
            .padding(20)
        }
        .sheet(isPresented: $showMetadataEditor) {
            BounceMetadataEditorSheet(bounce: bounce)
        }
    }

    private var formatColor: Color {
        ColorTokens.shared.bounceFormatColor(bounce.format)
    }
}


// MARK: - Metadata Editor Sheet

struct BounceMetadataEditorSheet: View {
    let bounce: Bounce
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var bpmText: String = ""
    @State private var musicalKey: String = ""
    @State private var stage: String = ""
    @State private var versionText: String = ""
    @State private var isSaving = false

    private static let stageOptions = ["", "rough", "demo", "mix", "master", "stem", "final"]

    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Metadata")
                .font(.title2)
                .fontWeight(.bold)

            Text(bounce.fileName)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BPM")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("e.g. 120", text: $bpmText)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Key")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("e.g. Cm, F#m, Bbmaj", text: $musicalKey)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Stage")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Picker("Stage", selection: $stage) {
                        Text("None").tag("")
                        ForEach(Self.stageOptions.filter { !$0.isEmpty }, id: \.self) { s in
                            Text(s.capitalized).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Version")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    TextField("e.g. 1, 2, 3", text: $versionText)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)

                Spacer()

                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving)
            }
        }
        .padding()
        .frame(width: 360, height: 380)
        .onAppear {
            bpmText = bounce.bpm.map { "\($0)" } ?? ""
            musicalKey = bounce.musicalKey ?? ""
            stage = bounce.stage ?? ""
            versionText = bounce.version.map { "\($0)" } ?? ""
        }
    }

    private func save() {
        isSaving = true
        let bpm = Int(bpmText)
        let version = Int(versionText)
        let key = musicalKey.isEmpty ? nil : musicalKey
        let stageVal = stage.isEmpty ? nil : stage

        Task {
            if let token = auth.authToken {
                let success = await bounceService.updateBounceMetadata(
                    bounceId: bounce.id,
                    bpm: bpm,
                    musicalKey: key,
                    stage: stageVal,
                    version: version,
                    token: token
                )
                if success {
                    dismiss()
                }
            }
            isSaving = false
        }
    }
}
