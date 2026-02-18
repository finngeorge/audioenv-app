import SwiftUI
import AppKit

/// Content column view for the Bounces sidebar entry.
/// Shows linked folders, bounce list with filters, and scan controls.
struct BounceBrowserView: View {
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService

    @Binding var selectedBounce: Bounce?

    @State private var search = ""
    @State private var formatFilter: String? = nil
    @State private var linkedFilter: Bool? = nil
    @State private var folderFilter: UUID? = nil
    @State private var showLinkFolderPrompt = false

    private var filteredBounces: [Bounce] {
        bounceService.bounces.filter { bounce in
            if let ff = formatFilter, bounce.format != ff { return false }
            if let folderId = folderFilter, bounce.bounceFolderId != folderId { return false }
            if !search.isEmpty {
                let q = search.lowercased()
                if !bounce.fileName.lowercased().contains(q) { return false }
            }
            return true
        }
    }

    private static let formatOptions = ["wav", "mp3", "aiff", "flac"]

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search bounces...", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding([.leading, .trailing])

            // Filters
            HStack(spacing: 10) {
                // Format filter
                Picker("Format", selection: $formatFilter) {
                    Text("All").tag(nil as String?)
                    ForEach(Self.formatOptions, id: \.self) { fmt in
                        Text(fmt.uppercased()).tag(fmt as String?)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)

                Spacer()

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
            .padding(.top, 4)

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
                List(selection: $selectedBounce) {
                    ForEach(filteredBounces) { bounce in
                        BounceRow(bounce: bounce)
                            .tag(bounce)
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
            if let token = auth.authToken {
                await bounceService.fetchFolders(token: token)
                await bounceService.fetchBounces(token: token)
                await bounceService.scanAllAutoFolders(token: token)
                await bounceService.fetchSuggestions(token: token)
            }
        }
        .onChange(of: formatFilter) { _, newFormat in
            Task {
                if let token = auth.authToken {
                    await bounceService.fetchBounces(token: token, folderId: folderFilter, format: newFormat, linked: linkedFilter)
                }
            }
        }
        .sheet(isPresented: $showLinkFolderPrompt) {
            LinkBounceFolderSheet()
        }
    }

    private func emptyFoldersState() -> some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No Bounce Folders Linked")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Link a folder containing your audio bounces\n(WAV, MP3, AIFF, FLAC)")
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
                    .background(formatColor(bounce.format).opacity(0.15))
                    .foregroundColor(formatColor(bounce.format))
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
            }
        }
        .padding(.vertical, 2)
    }

    private func formatColor(_ format: String) -> Color {
        switch format.lowercased() {
        case "wav":  return Color(red: 0.66, green: 0.85, blue: 0.92) // #a8d8ea
        case "mp3":  return Color(red: 0.94, green: 0.79, blue: 0.53) // #f0c987
        case "aiff": return Color(red: 0.79, green: 0.70, blue: 0.90) // #c9b3e6
        case "flac": return Color(red: 0.66, green: 0.90, blue: 0.81) // #a8e6cf
        default:     return .secondary
        }
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
