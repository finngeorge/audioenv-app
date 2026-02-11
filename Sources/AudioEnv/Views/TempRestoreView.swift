import SwiftUI

/// View for managing temporary plugin restore sessions.
/// Shows DRM warnings before restore, active session status, and cleanup controls.
struct TempRestoreView: View {
    @EnvironmentObject var tempRestore: TempRestoreService
    let manifest: BackupManifest
    let destination: BackupDestination
    let backupName: String
    @Environment(\.dismiss) private var dismiss

    @State private var showDRMWarning = true
    @State private var acceptedWarning = false
    @State private var timeoutHours: Int = 24

    var body: some View {
        VStack(spacing: 0) {
            if showDRMWarning && !acceptedWarning {
                drmWarningView
            } else if tempRestore.isRestoring {
                progressView
            } else if tempRestore.hasActiveSession {
                activeSessionView
            } else {
                configView
            }
        }
        .frame(width: 550, minHeight: 400)
    }

    // MARK: - DRM Warning

    private var drmWarningView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
                .padding(.top, 24)

            Text("Important: DRM & Licensing Notice")
                .font(.title2)
                .fontWeight(.bold)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    warningItem(
                        "Plugin Licensing",
                        "Temporarily installing plugins does not grant you a license to use them. Plugins with DRM (iLok, native licensing, etc.) will likely require separate authorization."
                    )

                    warningItem(
                        "No Guarantee of Functionality",
                        "Some plugins may not function correctly when installed via symlinks. Features requiring specific installation paths or registry entries may not work."
                    )

                    warningItem(
                        "Temporary Only",
                        "All symlinks will be removed when you end the session. This is intended for temporary compatibility testing, not permanent installation."
                    )

                    warningItem(
                        "User Library Only",
                        "Plugins are installed in your user Library directory. System-level plugin directories (/Library/) are not modified."
                    )
                }
                .padding()
            }

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("I Understand") {
                    acceptedWarning = true
                    showDRMWarning = false
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    private func warningItem(_ title: String, _ description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(.secondary)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Config View

    private var configView: some View {
        VStack(spacing: 16) {
            Text("Temporary Plugin Install")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 24)

            Text("Install \(manifest.plugins.count) plugins temporarily via symlinks")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(manifest.plugins, id: \.s3Key) { plugin in
                        HStack {
                            Text(plugin.name)
                                .font(.subheadline)
                            Spacer()
                            Text(plugin.format)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxHeight: 200)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
            .padding(.horizontal)

            HStack {
                Text("Auto-cleanup after:")
                    .font(.subheadline)
                Picker("", selection: $timeoutHours) {
                    Text("12 hours").tag(12)
                    Text("24 hours").tag(24)
                    Text("48 hours").tag(48)
                    Text("No timeout").tag(0)
                }
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            .padding(.horizontal)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Start Temporary Install") {
                    Task {
                        await tempRestore.startTempRestore(
                            manifest: manifest,
                            destination: destination,
                            backupName: backupName,
                            timeoutHours: timeoutHours
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
    }

    // MARK: - Progress View

    private var progressView: some View {
        VStack(spacing: 16) {
            Spacer()

            ProgressView(value: tempRestore.progress)
                .padding(.horizontal, 40)

            Text(tempRestore.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("\(Int(tempRestore.progress * 100))%")
                .font(.title)
                .fontWeight(.bold)
                .monospacedDigit()

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Active Session View

    private var activeSessionView: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: "clock.badge.checkmark.fill")
                    .font(.title)
                    .foregroundStyle(.green)

                VStack(alignment: .leading) {
                    Text("Temporary Session Active")
                        .font(.headline)
                    if let session = tempRestore.activeSession {
                        Text("Started \(session.startedAt, style: .relative) ago")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
            .padding()
            .background(Color.green.opacity(0.1))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.top)

            ScrollView {
                VStack(spacing: 4) {
                    ForEach(tempRestore.restoredPlugins) { plugin in
                        HStack {
                            statusIcon(for: plugin.status)

                            Text(plugin.name)
                                .font(.subheadline)

                            Spacer()

                            Text(plugin.format)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            statusBadge(for: plugin.status)
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(.horizontal)

            Divider()

            HStack {
                Button("Close") { dismiss() }

                Spacer()

                Button("End Session") {
                    Task {
                        await tempRestore.endSession()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
            .padding()
        }
    }

    @ViewBuilder
    private func statusIcon(for status: TempRestoreService.RestoreStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .installed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .removed:
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusBadge(for status: TempRestoreService.RestoreStatus) -> some View {
        switch status {
        case .pending:
            Text("Pending")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        case .installed:
            Text("Installed")
                .font(.caption2)
                .foregroundStyle(.green)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.1))
                .cornerRadius(4)
        case .failed(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.1))
                .cornerRadius(4)
                .lineLimit(1)
        case .removed:
            Text("Removed")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(4)
        }
    }
}
