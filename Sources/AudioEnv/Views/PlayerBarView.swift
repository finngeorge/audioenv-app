import SwiftUI

/// Compact bottom bar for audio playback controls.
/// Only visible when a bounce is currently loaded.
struct PlayerBarView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService
    @EnvironmentObject var playbackTime: PlaybackTimeObserver

    var body: some View {
        if let bounce = audioPlayer.currentBounce {
            VStack(spacing: 0) {
                Divider()

                HStack(spacing: 0) {
                    // Left: Track metadata
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bounce.fileName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        HStack(spacing: 6) {
                            Text(bounce.format.uppercased())
                                .font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(formatColor(bounce.format).opacity(0.15))
                                .foregroundColor(formatColor(bounce.format))
                                .cornerRadius(3)

                            if let sr = bounce.formattedSampleRate {
                                Text(sr)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }

                            if let bd = bounce.bitDepth {
                                Text("\(bd)-bit")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            if let br = bounce.formattedBitrate {
                                Text(br)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }

                            Text(bounce.formattedSize)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 220, alignment: .leading)

                    // Center: Controls + progress bar
                    VStack(spacing: 4) {
                        HStack(spacing: 16) {
                            Button {
                                audioPlayer.previous()
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(audioPlayer.queue.isEmpty)

                            Button {
                                audioPlayer.togglePlayPause()
                            } label: {
                                Image(systemName: audioPlayer.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.plain)

                            Button {
                                audioPlayer.next()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 12))
                            }
                            .buttonStyle(.plain)
                            .disabled(audioPlayer.queue.isEmpty)
                        }

                        HStack(spacing: 6) {
                            Text(formatTime(playbackTime.currentTime))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .trailing)

                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Rectangle()
                                        .fill(Color.secondary.opacity(0.15))
                                        .cornerRadius(1.5)
                                    Rectangle()
                                        .fill(formatColor(bounce.format))
                                        .frame(width: progressWidth(totalWidth: geometry.size.width))
                                        .cornerRadius(1.5)
                                }
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { value in
                                            let fraction = max(0, min(1, value.location.x / geometry.size.width))
                                            audioPlayer.seek(to: fraction * playbackTime.duration)
                                        }
                                )
                            }
                            .frame(height: 3)

                            Text(formatTime(playbackTime.duration))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .frame(width: 32, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    // Right: Volume
                    HStack(spacing: 4) {
                        Image(systemName: audioPlayer.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Slider(value: $audioPlayer.volume, in: 0...1)
                            .frame(width: 80)
                            .controlSize(.mini)
                    }
                    .frame(width: 120, alignment: .trailing)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(height: 65)
            .background(.bar)
        }
    }

    private func progressWidth(totalWidth: CGFloat) -> CGFloat {
        guard playbackTime.duration > 0 else { return 0 }
        return totalWidth * CGFloat(playbackTime.currentTime / playbackTime.duration)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        guard time.isFinite && time >= 0 else { return "0:00" }
        let mins = Int(time) / 60
        let secs = Int(time) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func formatColor(_ format: String) -> Color {
        switch format.lowercased() {
        case "wav":  return Color(red: 0.66, green: 0.85, blue: 0.92)
        case "mp3":  return Color(red: 0.94, green: 0.79, blue: 0.53)
        case "aiff": return Color(red: 0.79, green: 0.70, blue: 0.90)
        case "flac": return Color(red: 0.66, green: 0.90, blue: 0.81)
        default:     return .secondary
        }
    }
}
