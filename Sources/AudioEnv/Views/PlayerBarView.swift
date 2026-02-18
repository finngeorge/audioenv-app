import SwiftUI

/// Compact bottom bar for audio playback controls.
/// Only visible when a bounce is currently loaded.
struct PlayerBarView: View {
    @EnvironmentObject var audioPlayer: AudioPlayerService

    var body: some View {
        if let bounce = audioPlayer.currentBounce {
            VStack(spacing: 0) {
                Divider()

                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.15))
                        Rectangle()
                            .fill(formatColor(bounce.format))
                            .frame(width: progressWidth(totalWidth: geometry.size.width))
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let fraction = max(0, min(1, value.location.x / geometry.size.width))
                                audioPlayer.seek(to: fraction * audioPlayer.duration)
                            }
                    )
                }
                .frame(height: 3)

                HStack(spacing: 12) {
                    // Track info
                    VStack(alignment: .leading, spacing: 1) {
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

                            Text(formatTime(audioPlayer.currentTime))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                            Text("/")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                            Text(formatTime(audioPlayer.duration))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Controls
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

                    // Volume
                    HStack(spacing: 4) {
                        Image(systemName: audioPlayer.volume > 0 ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Slider(value: $audioPlayer.volume, in: 0...1)
                            .frame(width: 70)
                            .controlSize(.mini)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .frame(height: 55)
            .background(.bar)
        }
    }

    private func progressWidth(totalWidth: CGFloat) -> CGFloat {
        guard audioPlayer.duration > 0 else { return 0 }
        return totalWidth * CGFloat(audioPlayer.currentTime / audioPlayer.duration)
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
