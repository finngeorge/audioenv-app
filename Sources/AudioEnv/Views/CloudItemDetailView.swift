import SwiftUI

struct CloudItemDetailView: View {
    let item: CloudItem
    @EnvironmentObject var cloud: CloudService
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var audioPlayer: AudioPlayerService

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: item.itemType.systemImage)
                        .font(.system(size: 32))
                        .foregroundColor(iconColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.name)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .lineLimit(2)

                        HStack(spacing: 8) {
                            Text(item.itemType.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(iconColor.opacity(0.12))
                                .foregroundColor(iconColor)
                                .cornerRadius(4)

                            Text(item.fileType.capitalized)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.1))
                                .cornerRadius(4)

                            if let format = item.format {
                                Text(format)
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.secondary.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }

                Divider()

                // Metadata
                VStack(alignment: .leading, spacing: 8) {
                    if item.sizeBytes > 0 {
                        infoRow("Size", value: item.formattedSize)
                    }

                    if let date = item.uploadedAt {
                        infoRow("Uploaded", value: Self.dateFormatter.string(from: date))
                    }

                    if let sender = item.senderUsername {
                        infoRow("Shared by", value: sender)
                    }

                    if let backupId = item.backupId {
                        infoRow("Backup ID", value: String(backupId.prefix(30)))
                    }

                    if item.isPending {
                        HStack(spacing: 6) {
                            Image(systemName: "clock")
                                .foregroundStyle(.orange)
                            Text("Pending sync — not yet uploaded to cloud")
                                .font(.subheadline)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)

                // Actions
                actions()
            }
            .padding()
        }
    }

    // MARK: - Actions

    private func actions() -> some View {
        VStack(spacing: 12) {
            // Download
            Button {
                Task {
                    if let token = auth.authToken {
                        await cloud.downloadItem(item, token: token)
                    }
                }
            } label: {
                HStack {
                    if cloud.isDownloading {
                        ProgressView().controlSize(.small)
                        Text("Downloading...")
                    } else {
                        Image(systemName: "arrow.down.circle")
                        Text("Download to Mac")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(cloud.isDownloading || item.isPending)

            if cloud.isDownloading {
                ProgressView(value: cloud.downloadProgress)
            }

            // Play button for bounce files
            if item.fileType == "bounce", let format = item.format,
               ["wav", "mp3", "aiff", "flac", "m4a", "aac"].contains(format.lowercased()) {
                Button {
                    // Play would require downloading first — show hint
                } label: {
                    HStack {
                        Image(systemName: "play.circle")
                        Text("Download to play")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(true)
            }

            if let error = cloud.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.subheadline)
                .textSelection(.enabled)
            Spacer()
        }
    }

    private var iconColor: Color {
        switch item.itemType {
        case .backup: return .blue
        case .upload: return .green
        case .shared: return .purple
        }
    }
}
