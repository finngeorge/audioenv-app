import SwiftUI

/// Detail view for a selected bounce — shows audio metadata, linked projects, suggestions.
struct BounceDetailPanel: View {
    let bounce: Bounce
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var backup: BackupService

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

                // Play button for local files
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

                // Copy Link
                Button {
                    let url = "https://audioenv.app/share/bounce/\(bounce.id.uuidString)"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: {
                    Label("Copy Link", systemImage: "link")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)

                // Backup to Cloud
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
                    InfoRow(label: "File Size", value: bounce.formattedSize)
                    InfoRow(label: "Format", value: bounce.format.uppercased())
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
    }

    private var formatColor: Color {
        switch bounce.format.lowercased() {
        case "wav":  return Color(red: 0.66, green: 0.85, blue: 0.92)
        case "mp3":  return Color(red: 0.94, green: 0.79, blue: 0.53)
        case "aiff": return Color(red: 0.79, green: 0.70, blue: 0.90)
        case "flac": return Color(red: 0.66, green: 0.90, blue: 0.81)
        default:     return .secondary
        }
    }
}
