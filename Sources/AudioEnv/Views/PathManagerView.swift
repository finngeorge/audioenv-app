import SwiftUI

/// Modal sheet that lets the user add or remove custom directories
/// to search for session files.  The defaults (Documents, Desktop,
/// Music, Downloads) are always included and shown as informational text.
struct PathManagerView: View {
    @EnvironmentObject var scanner: ScannerService

    @State   private var newPath = ""
    @State   private var showScanPrompt = false
    @State   private var showGrantSuccess = false
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // ── Title + description ───────────────────────────
            Text("Session Search Paths")
                .font(.headline)
                .fontWeight(.semibold)
                .padding(.top, 16)

            Text("Additional directories searched for .als and .logicpro files.\nDefaults: Documents, Desktop, Music, Downloads.\nAfter adding paths, click Scan in the toolbar or Start Scan below.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .padding(.bottom, 8)

            // ── Grant Access to TCC-protected dirs ────────────
            let missingDirs = ScannerService.defaultSessionRoots.filter {
                !TCCAccessCache.shared.isGranted($0)
            }
            if !missingDirs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                        .foregroundColor(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grant Access to Documents, Desktop & Downloads")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Text("macOS requires permission to scan these folders.")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Grant Access") {
                        ScannerService.requestDefaultDirectoryAccess()
                        showGrantSuccess = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
            } else if showGrantSuccess {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Access granted — rescan to include all folders.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)
            }

            Divider()

            // ── Custom paths list ─────────────────────────────
            List {
                if scanner.customPaths.isEmpty {
                    Text("No custom paths added")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    ForEach(scanner.customPaths, id: \.self) { path in
                        HStack {
                            Image(systemName: "folder")
                                .foregroundColor(.accentColor)
                            Text(path)
                                .font(.subheadline)
                            Spacer()
                            Button(action: { scanner.removeCustomPath(path) }) {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()

            // ── Add-path row ──────────────────────────────────
            HStack(spacing: 8) {
                TextField("Folder path…", text: $newPath)
                    .textFieldStyle(.roundedBorder)

                Button("Browse", action: browsePath)
                    .buttonStyle(.bordered)

                Button(action: addPath) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(newPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()

            if showScanPrompt && !scanner.isScanning {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle.magnifyingglass")
                        .foregroundColor(.accentColor)
                    Text("Path added — start a scan to update results.")
                        .font(.subheadline)
                    Spacer()
                    Button("Start Scan") {
                        scanner.scanAll()
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.bottom, 6)
            }

            // ── Close ─────────────────────────────────────────
            HStack(spacing: 10) {
                Button("Start Scan") {
                    scanner.scanAll()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(scanner.isScanning)

                Button("Close") { dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.bottom, 12)
        }
        .frame(width: 460, height: 340)
    }

    // MARK: – Actions

    /// Open an NSOpenPanel so the user can pick a directory visually.
    private func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories       = true
        panel.canChooseFiles             = false
        panel.allowsMultipleSelection    = false

        if panel.runModal() == .OK, let url = panel.urls.first {
            newPath = url.path
        }
    }

    private func addPath() {
        let trimmed = newPath.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !scanner.customPaths.contains(trimmed) else {
            newPath = ""
            return
        }
        scanner.addCustomPath(trimmed)
        newPath = ""
        showScanPrompt = true
    }
}
