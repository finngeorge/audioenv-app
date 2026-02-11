import SwiftUI

/// New view for configuring and managing plugin backups
struct BackupConfigView: View {
    @ObservedObject var scanner: ScannerService
    @ObservedObject var backup: BackupService

    @State private var showS3Config = false
    @State private var bucketName = ""
    @State private var accessKeyId = ""
    @State private var secretKey = ""
    @State private var region = "us-west-2"

    @State private var preferredFormat: PluginDeduplicator.PreferredFormat = .vst3
    @State private var backupStats: BackupStats?
    @State private var showingDeduplicationPreview = false

    var body: some View {
        VStack(spacing: 20) {
            // S3 Configuration Section
            GroupBox(label: Label("S3 Configuration", systemImage: "externaldrive.badge.icloud")) {
                VStack(alignment: .leading, spacing: 12) {
                    if backup.destination == nil {
                        Button("Configure S3 Backup") {
                            showS3Config = true
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text("Connected to: \(backup.destination?.displayName ?? "")")
                            Spacer()
                            Button("Disconnect") {
                                backup.configure(destination: nil)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding()
            }

            // Deduplication Preview
            GroupBox(label: Label("Backup Strategy", systemImage: "arrow.down.circle")) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Prefer Plugin Format:")
                        .font(.headline)

                    Picker("Format", selection: $preferredFormat) {
                        Text("VST3 (Recommended)").tag(PluginDeduplicator.PreferredFormat.vst3)
                        Text("Audio Unit (AU)").tag(PluginDeduplicator.PreferredFormat.au)
                        Text("VST").tag(PluginDeduplicator.PreferredFormat.vst)
                        Text("AAX").tag(PluginDeduplicator.PreferredFormat.aax)
                    }
                    .pickerStyle(.segmented)

                    Button("Calculate Backup Size") {
                        calculateBackupSize()
                    }
                    .buttonStyle(.bordered)

                    if let stats = backupStats {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            StatRow(label: "Original Plugins", value: "\(stats.originalCount)")
                            StatRow(label: "After Deduplication", value: "\(stats.deduplicatedCount)")
                            StatRow(label: "Original Size", value: stats.formattedOriginalSize)
                            StatRow(label: "Backup Size", value: stats.formattedDeduplicatedSize)
                            StatRow(
                                label: "Savings",
                                value: "\(stats.formattedSavings) (\(Int(stats.savedPercentage))%)",
                                highlight: true
                            )
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding()
            }

            // Backup Actions
            if backup.destination != nil {
                GroupBox(label: Label("Backup Actions", systemImage: "arrow.up.circle")) {
                    VStack(spacing: 12) {
                        Button {
                            Task {
                                await performBackup()
                            }
                        } label: {
                            HStack {
                                Image(systemName: "icloud.and.arrow.up")
                                Text("Start Plugin Backup")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(backup.isUploading || scanner.plugins.isEmpty)

                        if backup.isUploading {
                            VStack(spacing: 8) {
                                ProgressView(value: backup.uploadProgress)
                                    .progressViewStyle(.linear)

                                Text("Uploading... \(Int(backup.uploadProgress * 100))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                if let lastEntry = backup.uploadLog.last {
                                    Text(lastEntry.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }

            Spacer()
        }
        .padding()
        .sheet(isPresented: $showS3Config) {
            S3ConfigSheet(
                bucketName: $bucketName,
                accessKeyId: $accessKeyId,
                secretKey: $secretKey,
                region: $region,
                onSave: configureS3
            )
        }
    }

    private func calculateBackupSize() {
        let (deduplicated, stats) = scanner.preparePluginsForBackup(preferFormat: preferredFormat)
        backupStats = stats
    }

    private func configureS3() {
        let destination = S3BackupDestination(
            bucketName: bucketName,
            region: region,
            credentials: (accessKeyId, secretKey)
        )
        backup.configure(destination: destination)
        showS3Config = false
    }

    private func performBackup() async {
        let (plugins, stats) = scanner.preparePluginsForBackup(preferFormat: preferredFormat)
        do {
            try await backup.backupPlugins(plugins)
        } catch {
            print("Backup failed: \(error)")
        }
    }
}

// MARK: - S3 Config Sheet

struct S3ConfigSheet: View {
    @Binding var bucketName: String
    @Binding var accessKeyId: String
    @Binding var secretKey: String
    @Binding var region: String

    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Text("Configure S3 Backup")
                .font(.title2)
                .bold()

            Form {
                TextField("Bucket Name", text: $bucketName)
                TextField("Access Key ID", text: $accessKeyId)
                SecureField("Secret Access Key", text: $secretKey)
                Picker("Region", selection: $region) {
                    Text("US West (Oregon)").tag("us-west-2")
                    Text("US East (N. Virginia)").tag("us-east-1")
                    Text("EU (Ireland)").tag("eu-west-1")
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Save & Connect") {
                    onSave()
                }
                .buttonStyle(.borderedProminent)
                .disabled(bucketName.isEmpty || accessKeyId.isEmpty || secretKey.isEmpty)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
    }
}

// MARK: - Stat Row

struct StatRow: View {
    let label: String
    let value: String
    var highlight: Bool = false

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .bold(highlight)
                .foregroundStyle(highlight ? .green : .primary)
        }
    }
}

#Preview {
    BackupConfigView(
        scanner: ScannerService(),
        backup: BackupService()
    )
    .frame(width: 600, height: 700)
}
