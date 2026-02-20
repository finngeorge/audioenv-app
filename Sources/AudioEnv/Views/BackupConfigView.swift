import SwiftUI

/// New view for configuring and managing plugin backups
struct BackupConfigView: View {
    @ObservedObject var scanner: ScannerService
    @ObservedObject var backup: BackupService
    @Binding var selectedBackup: BackupListItem?
    @EnvironmentObject var auth: AuthenticationService
    @EnvironmentObject var sync: SyncService

    @State private var showS3Config = false
    @State private var bucketName = ""
    @State private var accessKeyId = ""
    @State private var secretKey = ""
    @State private var region = "us-west-2"

    @State private var preferredFormat: PluginDeduplicator.PreferredFormat = .vst3
    @State private var backupStats: BackupStats?
    @State private var showingDeduplicationPreview = false

    @State private var selectedScope: BackupScope? = nil
    @State private var backupName = ""
    @State private var showScopeSelector = false
    @State private var scopeStats: BackupScopeStats? = nil
    @State private var useCustomS3 = false
    @State private var customS3Expanded = false

    private var isPro: Bool {
        auth.currentUser?.subscriptionTier == "pro"
    }

    private var storageQuotaBytes: Int { 250_000_000_000 } // 250 GB

    private var storageUsedBytes: Int {
        auth.currentUser?.storageUsedBytes ?? 0
    }

    private var formattedStorageUsed: String {
        ByteCountFormatter.string(fromByteCount: Int64(storageUsedBytes), countStyle: .file)
    }

    private var formattedStorageQuota: String {
        ByteCountFormatter.string(fromByteCount: Int64(storageQuotaBytes), countStyle: .file)
    }

    private var storageProgress: Double {
        guard storageQuotaBytes > 0 else { return 0 }
        return min(Double(storageUsedBytes) / Double(storageQuotaBytes), 1.0)
    }

    /// Whether backup should use the platform cloud (Pro without custom S3 override)
    private var usingPlatformCloud: Bool {
        isPro && !useCustomS3
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Storage Configuration Section — tier-aware
                if isPro {
                    proStorageSection()
                } else {
                    freeStorageSection()
                }

                // Create New Backup Section
                if usingPlatformCloud || backup.destination != nil {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Create New Backup", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .fontWeight(.semibold)

                        // Scope Selection
                        if let scope = selectedScope {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(scope.generateName())
                                            .font(.subheadline)
                                            .fontWeight(.medium)
                                        Text(scope.getDescription())
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer()

                                    Button("Change") {
                                        showScopeSelector = true
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }

                                if let stats = scopeStats {
                                    Divider()

                                    HStack(spacing: 20) {
                                        if stats.pluginCount > 0 {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("\(stats.pluginCount)")
                                                    .font(.title3)
                                                    .fontWeight(.bold)
                                                Text("Plugins")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text(stats.formattedPluginSize)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        if stats.projectCount > 0 {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text("\(stats.sessionCount)")
                                                    .font(.title3)
                                                    .fontWeight(.bold)
                                                Text("Project Files")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                                Text(stats.formattedProjectSize)
                                                    .font(.caption2)
                                                    .foregroundStyle(.secondary)
                                            }
                                        }

                                        Spacer()

                                        VStack(alignment: .trailing, spacing: 4) {
                                            Text("Total")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Text(stats.formattedTotalSize)
                                                .font(.title3)
                                                .fontWeight(.bold)
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                            }
                            .padding()
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)

                            // Start Backup Button
                            Button {
                                Task {
                                    await performBackup()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "icloud.and.arrow.up")
                                    Text("Start Backup")
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(backup.isUploading)

                        } else {
                            VStack(spacing: 12) {
                                Image(systemName: "square.stack.3d.up")
                                    .font(.system(size: 36))
                                    .foregroundStyle(.secondary)

                                Text("No Scope Selected")
                                    .font(.subheadline)
                                    .fontWeight(.medium)

                                Text("Choose what to include in your backup")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Button("Select Backup Scope") {
                                    showScopeSelector = true
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                        }

                        // Progress/Status
                        if backup.isUploading {
                            VStack(spacing: 8) {
                                ProgressView(value: backup.uploadProgress)
                                    .progressViewStyle(.linear)

                                HStack {
                                    Text("Uploading...")
                                    Spacer()
                                    Text("\(Int(backup.uploadProgress * 100))%")
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)

                                if let lastEntry = backup.uploadLog.last {
                                    Text(lastEntry.path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding()
                            .background(Color.blue.opacity(0.05))
                            .cornerRadius(8)
                        }

                        // Success message
                        if let successBackup = backup.lastSuccessfulBackup, !backup.isUploading {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Backup Complete!")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                    Text("\"\(successBackup)\" uploaded successfully")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                        }

                        // Error message
                        if let error = backup.lastError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.red)
                                Text(error)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)

                    // Available Backups List
                    VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Your Backups", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                            .fontWeight(.semibold)

                        Spacer()

                        Button {
                            Task { await backup.loadAvailableBackups() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.clockwise")
                                Text("Refresh")
                            }
                            .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(backup.isLoadingBackups)
                    }

                    if backup.isLoadingBackups {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("Loading backups...")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else if backup.availableBackups.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 40))
                                .foregroundStyle(.secondary)
                            Text("No backups found")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(backup.availableBackups) { item in
                                backupListRow(item)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(selectedBackup?.id == item.id ? Color.blue : Color.clear, lineWidth: 2)
                                    )
                                    .onTapGesture {
                                        selectedBackup = item
                                    }
                            }
                        }
                    }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)
                }
            }
            .padding()
        }
        .onAppear {
            loadS3Credentials()
        }
        .task {
            // Auto-refresh backups when view appears if S3 is connected
            if backup.destination != nil && backup.userId != nil {
                await backup.loadAvailableBackups()
            }
        }
        .sheet(isPresented: $showS3Config) {
            S3ConfigSheet(
                bucketName: $bucketName,
                accessKeyId: $accessKeyId,
                secretKey: $secretKey,
                region: $region,
                onSave: configureS3
            )
        }
        .sheet(isPresented: $showScopeSelector) {
            BackupScopeSelector(
                scanner: scanner,
                selectedScope: $selectedScope,
                backupName: $backupName
            )
        }
        .onChange(of: selectedScope) { _, newScope in
            if let scope = newScope {
                scopeStats = scope.calculateStats(scanner: scanner)
                backupName = scope.generateName()
            } else {
                scopeStats = nil
                backupName = ""
            }
        }
    }

    // MARK: - Pro Tier Storage Section

    private func proStorageSection() -> some View {
        VStack(spacing: 16) {
            // AudioEnv Cloud card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "cloud.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("AudioEnv Cloud")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("Included with Pro")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.blue.opacity(0.15))
                            .foregroundStyle(.blue)
                            .cornerRadius(4)
                    }

                    Spacer()

                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // Storage bar
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: storageProgress)
                        .tint(storageProgress > 0.9 ? .orange : .blue)

                    HStack {
                        Text("\(formattedStorageUsed) / \(formattedStorageQuota) used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(storageProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding()
            .background(Color.blue.opacity(0.05))
            .cornerRadius(12)

            // Collapsible custom S3 override
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup("Use Custom S3 Instead", isExpanded: $customS3Expanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Use custom S3 storage", isOn: $useCustomS3)
                            .font(.subheadline)

                        Text("Override AudioEnv Cloud with your own S3 bucket")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        if useCustomS3 {
                            s3ConnectionStatus()
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(12)
        }
    }

    // MARK: - Free Tier Storage Section

    private func freeStorageSection() -> some View {
        VStack(spacing: 16) {
            // S3 Configuration (prominent for free tier)
            VStack(alignment: .leading, spacing: 12) {
                Label("S3 Configuration", systemImage: "externaldrive.badge.icloud")
                    .font(.headline)
                    .fontWeight(.semibold)

                s3ConnectionStatus()
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(12)

            // Upgrade CTA
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "cloud.fill")
                        .font(.title2)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Upgrade to Pro")
                            .font(.headline)
                            .fontWeight(.semibold)
                        Text("Get 250 GB AudioEnv Cloud storage")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Text("Back up your plugins and projects without configuring S3. Included with AudioEnv Pro.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    if let url = URL(string: "https://audioenv.com/pricing") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack {
                        Image(systemName: "arrow.up.right")
                        Text("View Pricing")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(
                LinearGradient(
                    colors: [Color.blue.opacity(0.08), Color.purple.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(12)
        }
    }

    // MARK: - S3 Connection Status (shared)

    @ViewBuilder
    private func s3ConnectionStatus() -> some View {
        if backup.destination == nil {
            VStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)

                Text("No S3 Connection")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text("Connect to Amazon S3 to backup your plugins and projects")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("Configure S3 Backup") {
                    showS3Config = true
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(backup.destination?.displayName ?? "")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text("Storage: \(backup.formattedTotalStorage)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Disconnect") {
                    if let userId = auth.currentUser?.id {
                        KeychainHelper.shared.clearS3Config(forUser: userId)
                    }
                    backup.configure(destination: nil)
                    bucketName = ""
                    accessKeyId = ""
                    secretKey = ""
                    region = "us-west-2"
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func calculateBackupSize() {
        let (_, stats) = scanner.preparePluginsForBackup(preferFormat: preferredFormat)
        backupStats = stats
    }

    private func loadS3Credentials() {
        guard let userId = auth.currentUser?.id else {
            return
        }

        if let config = KeychainHelper.shared.loadS3Config(forUser: userId) {
            bucketName = config.bucket
            accessKeyId = config.accessKeyId
            secretKey = config.secretKey
            region = config.region

            // Auto-configure destination
            let destination = S3BackupDestination(
                bucketName: config.bucket,
                region: config.region,
                credentials: (config.accessKeyId, config.secretKey)
            )
            backup.configure(destination: destination)
        }
    }

    private func configureS3() {
        guard let userId = auth.currentUser?.id else {
            backup.lastError = "You must be logged in to configure S3"
            return
        }

        // Save to Keychain (user-scoped)
        KeychainHelper.shared.saveS3Config(
            bucket: bucketName,
            accessKeyId: accessKeyId,
            secretKey: secretKey,
            region: region,
            forUser: userId
        )

        // Configure destination
        let destination = S3BackupDestination(
            bucketName: bucketName,
            region: region,
            credentials: (accessKeyId, secretKey)
        )
        backup.configure(destination: destination)
        showS3Config = false

        // Sync S3 config to backend
        if let token = auth.authToken {
            Task {
                await sync.syncS3Config(
                    bucket: bucketName,
                    region: region,
                    accessKey: accessKeyId,
                    secretKey: secretKey,
                    token: token
                )
            }
        }

        // Auto-refresh backups after successful configuration
        if backup.userId != nil {
            Task {
                await backup.loadAvailableBackups()
            }
        }
    }

    private func performBackup() async {
        guard let scope = selectedScope else { return }

        // Resolve scope to actual plugins and projects
        let (scopePlugins, scopeProjects) = scope.resolve(scanner: scanner)

        // Apply deduplication to the plugins in scope
        let deduplicated = PluginDeduplicator.deduplicate(scopePlugins, preferFormat: preferredFormat)

        // Backup both plugins and projects using unified backup
        await backup.backupAll(
            plugins: deduplicated,
            projects: scopeProjects,
            backupName: backupName.isEmpty ? scope.generateName() : backupName,
            scopeDescription: scope.getDescription()
        )

        // Reload backup list to show the new backup
        await backup.loadAvailableBackups()
    }

    // MARK: - Backup List Row

    @ViewBuilder
    private func backupListRow(_ backupItem: BackupListItem) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(backupItem.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label("\(backupItem.pluginCount) plugins", systemImage: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if backupItem.projectCount > 0 {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Label("\(backupItem.projectCount) projects", systemImage: "folder")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(backupItem.formattedDate)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(backupItem.formattedSize)
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(8)
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

// MARK: - Backup List Row Compact

private struct BackupListRowCompact: View {
    let backup: BackupListItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(backup.name)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)

            Text(backup.formattedDate)
                .font(.caption2)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Label("\(backup.pluginCount)", systemImage: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if backup.projectCount > 0 {
                    Text("•")
                    Label("\(backup.projectCount)", systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    BackupConfigView(
        scanner: ScannerService(),
        backup: BackupService(),
        selectedBackup: .constant(nil as BackupListItem?)
    )
    .environmentObject(AuthenticationService())
    .environmentObject(SyncService())
    .frame(width: 600, height: 700)
}
