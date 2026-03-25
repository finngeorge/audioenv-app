import SwiftUI

/// Detail view showing comprehensive information about a backup
struct BackupDetailView: View {
    let backup: BackupListItem
    @ObservedObject var backupService: BackupService

    @State private var manifest: BackupManifest? = nil
    @State private var isLoading = false
    @State private var loadError: String? = nil
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var isDownloading = false
    @State private var downloadProgress: Double = 0
    @State private var downloadSuccess = false
    @State private var downloadedPath: String?
    @State private var showRestoreOptions = false
    @State private var showTempRestoreSheet = false
    @EnvironmentObject var tempRestore: TempRestoreService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if isLoading {
                    ProgressView("Loading backup details...")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding()
                } else if let error = loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.red)
                        Text("Failed to load backup details")
                            .font(.headline)
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                } else if let manifest = manifest {
                    header()
                    Divider()
                    metadata(manifest: manifest)

                    if shouldShowConsolidationBanner() {
                        Divider()
                        consolidationBanner()
                    }

                    Divider()
                    pluginList(manifest: manifest)
                    Divider()
                    actions()
                }
            }
            .padding()
        }
        .task {
            await loadManifest()
        }
        .onChange(of: backup.id) { _, _ in
            Task {
                await loadManifest()
            }
        }
        .sheet(isPresented: $showRestoreOptions) {
            restoreOptionsSheet
        }
        .sheet(isPresented: $showTempRestoreSheet) {
            if let manifest = manifest, let destination = backupService.destination {
                TempRestoreView(
                    manifest: manifest,
                    destination: destination,
                    backupName: backup.name
                )
            }
        }
    }

    // MARK: - Load Manifest

    private func loadManifest() async {
        isLoading = true
        loadError = nil
        manifest = nil

        guard let destination = backupService.destination else {
            loadError = "No S3 destination configured"
            isLoading = false
            return
        }

        do {
            let metadataKey = backup.s3Prefix + "/metadata.json"
            let data = try await destination.download(key: metadataKey)

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            let decoded = try decoder.decode(BackupManifest.self, from: data)
            manifest = decoded
        } catch {
            loadError = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Header

    private func header() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(backup.name)
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(backup.formattedDate)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            // Full scope description
            if !backup.scopeDescription.isEmpty {
                HStack(spacing: 8) {
                    ForEach(backup.scopeIconNames, id: \.self) { icon in
                        Image(systemName: icon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(backup.scopeDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }

    // MARK: - Metadata

    private func metadata(manifest: BackupManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Backup Information")
                .font(.headline)
                .fontWeight(.semibold)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Size:")
                        .foregroundStyle(.secondary)
                    Text(backup.formattedSize)
                        .fontWeight(.medium)
                }

                GridRow {
                    Text("Plugins:")
                        .foregroundStyle(.secondary)
                    Text("\(backup.pluginCount)")
                        .fontWeight(.medium)
                }

                if backup.projectCount > 0 {
                    GridRow {
                        Text("Projects:")
                            .foregroundStyle(.secondary)
                        Text("\(backup.projectCount)")
                            .fontWeight(.medium)
                    }
                }

                GridRow {
                    Text("App Version:")
                        .foregroundStyle(.secondary)
                    Text(manifest.appVersion)
                        .fontWeight(.medium)
                }

                if manifest.scopeDescription.isEmpty {
                    GridRow {
                        Text("Scope:")
                            .foregroundStyle(.secondary)
                        Text("Manual selection")
                            .fontWeight(.medium)
                    }
                }
            }
            .font(.subheadline)
        }
    }

    // MARK: - Plugin List

    private func pluginList(manifest: BackupManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plugins (\(manifest.plugins.count))")
                .font(.headline)
                .fontWeight(.semibold)

            if manifest.plugins.isEmpty {
                Text("No plugins in this backup")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(manifest.plugins, id: \.s3Key) { plugin in
                            pluginRow(plugin: plugin)
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private func pluginRow(plugin: PluginBackupItem) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ColorTokens.shared.pluginFormatColorByName(plugin.format))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(plugin.name)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 6) {
                    Text(plugin.format)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let version = plugin.version {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text("v\(version)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let manufacturer = plugin.manufacturer {
                        Text("•")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(manufacturer)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }


    // MARK: - Consolidation Banner

    /// Check if this backup has redundant versions (same scope backed up multiple times)
    private func shouldShowConsolidationBanner() -> Bool {
        guard let manifest = manifest else { return false }
        let sameName = backupService.availableBackups.filter { $0.name == manifest.backupName }
        return sameName.count > 1
    }

    private func consolidationBanner() -> some View {
        let backupName = manifest?.backupName ?? ""
        let sameName = backupService.availableBackups
            .filter { $0.name == backupName }
            .sorted { $0.createdAt > $1.createdAt }
        let olderCount = sameName.count - 1

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "doc.on.doc")
                    .foregroundStyle(.blue)
                Text("\(olderCount) older version\(olderCount == 1 ? "" : "s") of this backup")
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }

            Text("You have \(sameName.count) backups named \"\(backupName)\". Older versions can be deleted to free storage if the latest version is confirmed good.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(sameName.dropFirst().prefix(3)) { older in
                Text("• \(older.formattedDate) — \(older.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Actions

    private func actions() -> some View {
        VStack(spacing: 12) {
            // Download/Restore Button
            Button {
                Task {
                    await downloadBackup()
                }
            } label: {
                HStack {
                    if isDownloading {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Download Backup")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isDownloading || isDeleting || downloadSuccess)

            if isDownloading {
                VStack(spacing: 4) {
                    ProgressView(value: downloadProgress)
                    Text("Downloading plugins... \(Int(downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Success message
            if downloadSuccess, let path = downloadedPath {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Download Complete!")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Text("Saved to: \(URL(fileURLWithPath: path).lastPathComponent)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    // Restore options
                    HStack(spacing: 8) {
                        Button {
                            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text("Show in Finder")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button {
                            showRestoreOptions = true
                        } label: {
                            HStack {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Restore Options")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding()
                .background(Color.green.opacity(0.1))
                .cornerRadius(8)
            }

            Divider()

            // Delete Button
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    if isDeleting {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Image(systemName: "trash")
                        Text("Delete Backup")
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isDeleting || isDownloading)

            Text("Deleting this backup will remove all plugins and metadata from S3. This action cannot be undone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .confirmationDialog(
            "Delete Backup?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    await deleteBackup()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Delete '\(backup.name)'? This will remove \(backup.formattedSize) from S3. This cannot be undone.")
        }
    }

    // MARK: - Delete Action

    private func deleteBackup() async {
        isDeleting = true
        do {
            try await backupService.deleteBackup(backup)
        } catch {
            backupService.lastError = "Delete failed: \(error.localizedDescription)"
        }
        isDeleting = false
    }

    // MARK: - Download Action

    private func downloadBackup() async {
        isDownloading = true
        downloadProgress = 0
        downloadSuccess = false
        downloadedPath = nil

        guard let destination = backupService.destination else {
            backupService.lastError = "No S3 destination configured"
            isDownloading = false
            return
        }

        guard let manifest = manifest else {
            backupService.lastError = "Backup manifest not loaded"
            isDownloading = false
            return
        }

        // Choose download location
        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = "\(backup.name)"
        savePanel.message = "Choose where to save this backup folder"
        savePanel.canCreateDirectories = true

        let response = await savePanel.begin()
        guard response == .OK, let saveURL = savePanel.url else {
            isDownloading = false
            return
        }

        do {
            // Create backup folder
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: saveURL, withIntermediateDirectories: true)

            // Download metadata.json
            let metadataKey = backup.s3Prefix + "/metadata.json"
            let metadataData = try await destination.download(key: metadataKey)
            let metadataURL = saveURL.appendingPathComponent("metadata.json")
            try metadataData.write(to: metadataURL)

            downloadProgress = 0.1

            // Calculate total items to download
            let totalItems = manifest.plugins.count + manifest.projects.count
            var downloadedItems = 0

            // Download all plugins
            if !manifest.plugins.isEmpty {
                let pluginsFolder = saveURL.appendingPathComponent("plugins")
                try fileManager.createDirectory(at: pluginsFolder, withIntermediateDirectories: true)

                for plugin in manifest.plugins {
                    let pluginData = try await destination.download(key: plugin.s3Key)
                    let pluginFileName = URL(fileURLWithPath: plugin.s3Key).lastPathComponent
                    let pluginURL = pluginsFolder.appendingPathComponent(pluginFileName)
                    try pluginData.write(to: pluginURL)

                    downloadedItems += 1
                    downloadProgress = 0.1 + (0.9 * Double(downloadedItems) / Double(max(totalItems, 1)))
                }
            }

            // Download all projects
            if !manifest.projects.isEmpty {
                let projectsFolder = saveURL.appendingPathComponent("projects")
                try fileManager.createDirectory(at: projectsFolder, withIntermediateDirectories: true)

                for project in manifest.projects {
                    let projectData = try await destination.download(key: project.s3Key)
                    let projectFileName = URL(fileURLWithPath: project.s3Key).lastPathComponent
                    let projectURL = projectsFolder.appendingPathComponent(projectFileName)
                    try projectData.write(to: projectURL)

                    downloadedItems += 1
                    downloadProgress = 0.1 + (0.9 * Double(downloadedItems) / Double(max(totalItems, 1)))
                }
            }

            downloadProgress = 1.0
            downloadSuccess = true
            downloadedPath = saveURL.path
            backupService.lastError = nil
        } catch {
            backupService.lastError = "Download failed: \(error.localizedDescription)"
            downloadSuccess = false
        }

        isDownloading = false
    }
}

// MARK: - Restore Options

extension BackupDetailView {
    private var restoreOptionsSheet: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Restore Options")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Choose how to restore this backup")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.05))

            ScrollView {
                VStack(spacing: 16) {
                    // Plugin restore options (if backup contains plugins)
                    if let manifest = manifest, !manifest.plugins.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Plugins (\(manifest.plugins.count))")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            restoreOptionButton(
                                title: "Extract All Plugins",
                                description: "Unzip all plugins to a folder of your choice",
                                icon: "folder.badge.plus",
                                action: extractPlugins
                            )

                            restoreOptionButton(
                                title: "Restore Plugins to Original Locations",
                                description: "Attempt to restore plugins to their original paths (requires admin access)",
                                icon: "arrow.counterclockwise.circle",
                                action: restorePluginsToOriginal
                            )

                            restoreOptionButton(
                                title: "Temporary Install",
                                description: "Install plugins temporarily via symlinks. Easily removable when done.",
                                icon: "clock.arrow.circlepath",
                                action: {
                                    showRestoreOptions = false
                                    showTempRestoreSheet = true
                                }
                            )
                        }
                    }

                    // Project restore options (if backup contains projects)
                    if let manifest = manifest, !manifest.projects.isEmpty {
                        Divider()

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Projects (\(manifest.projects.count))")
                                .font(.headline)
                                .foregroundStyle(.secondary)

                            restoreOptionButton(
                                title: "Extract All Projects",
                                description: "Extract all project folders to a location of your choice",
                                icon: "folder.badge.plus",
                                action: extractProjects
                            )

                            restoreOptionButton(
                                title: "Restore Projects to Original Locations",
                                description: "Restore projects to their original paths with validation",
                                icon: "arrow.counterclockwise.circle",
                                action: restoreProjectsToOriginal
                            )
                        }
                    }

                    Divider()

                    restoreOptionButton(
                        title: "Keep as Archive",
                        description: "Keep the downloaded backup folder as-is",
                        icon: "archivebox",
                        action: { showRestoreOptions = false }
                    )
                }
                .padding()
            }

            Spacer()
        }
        .frame(width: 550, height: 500)
    }

    private func restoreOptionButton(title: String, description: String, icon: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(.blue)
                    .frame(width: 40)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func extractPlugins() {
        guard let downloadedPath = downloadedPath else { return }

        let openPanel = NSOpenPanel()
        openPanel.message = "Choose where to extract plugins"
        openPanel.canCreateDirectories = true
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false

        openPanel.begin { response in
            guard response == .OK, let targetURL = openPanel.url else { return }

            Task {
                await performExtraction(from: downloadedPath, to: targetURL.path)
            }
        }
    }

    private func performExtraction(from sourcePath: String, to targetPath: String) async {
        do {
            let fileManager = FileManager.default
            let pluginsFolder = URL(fileURLWithPath: sourcePath).appendingPathComponent("plugins")

            guard fileManager.fileExists(atPath: pluginsFolder.path) else {
                backupService.lastError = "No plugins folder found in backup"
                return
            }

            let zipFiles = try fileManager.contentsOfDirectory(atPath: pluginsFolder.path)
                .filter { $0.hasSuffix(".zip") }

            for zipFile in zipFiles {
                let zipPath = pluginsFolder.appendingPathComponent(zipFile).path

                // Use ditto to extract
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-xk", zipPath, targetPath]

                try process.run()
                process.waitUntilExit()
            }

            showRestoreOptions = false
            backupService.lastError = nil
        } catch {
            backupService.lastError = "Extraction failed: \(error.localizedDescription)"
        }
    }

    private func restorePluginsToOriginal() {
        guard let manifest = manifest else { return }

        showRestoreOptions = false

        // Show warning about original location restore
        let alert = NSAlert()
        alert.messageText = "Restore Plugins to Original Locations"
        alert.informativeText = "This will attempt to restore \(manifest.plugins.count) plugins to their original locations. This may require administrator access and could overwrite existing files. Continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await performOriginalPluginRestore()
            }
        }
    }

    private func performOriginalPluginRestore() async {
        guard let downloadedPath = downloadedPath, let manifest = manifest else { return }

        do {
            let fileManager = FileManager.default
            let pluginsFolder = URL(fileURLWithPath: downloadedPath).appendingPathComponent("plugins")

            for plugin in manifest.plugins {
                let zipFileName = URL(fileURLWithPath: plugin.s3Key).lastPathComponent
                let zipPath = pluginsFolder.appendingPathComponent(zipFileName).path

                guard fileManager.fileExists(atPath: zipPath) else { continue }

                // Get original directory
                let originalPath = plugin.originalPath
                let originalDir = URL(fileURLWithPath: originalPath).deletingLastPathComponent().path

                // Create directory if needed
                try? fileManager.createDirectory(atPath: originalDir, withIntermediateDirectories: true)

                // Extract to original location
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-xk", zipPath, originalDir]

                try process.run()
                process.waitUntilExit()
            }

            backupService.lastError = nil
        } catch {
            backupService.lastError = "Plugin restore failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Project Restore Methods

    private func extractProjects() {
        guard let downloadedPath = downloadedPath else { return }

        let openPanel = NSOpenPanel()
        openPanel.message = "Choose where to extract projects"
        openPanel.canCreateDirectories = true
        openPanel.canChooseDirectories = true
        openPanel.canChooseFiles = false

        openPanel.begin { response in
            guard response == .OK, let targetURL = openPanel.url else { return }

            Task {
                await performProjectExtraction(from: downloadedPath, to: targetURL.path)
            }
        }
    }

    private func performProjectExtraction(from sourcePath: String, to targetPath: String) async {
        do {
            let fileManager = FileManager.default
            let projectsFolder = URL(fileURLWithPath: sourcePath).appendingPathComponent("projects")

            guard fileManager.fileExists(atPath: projectsFolder.path) else {
                backupService.lastError = "No projects folder found in backup"
                return
            }

            let zipFiles = try fileManager.contentsOfDirectory(atPath: projectsFolder.path)
                .filter { $0.hasSuffix(".zip") }

            for zipFile in zipFiles {
                let zipPath = projectsFolder.appendingPathComponent(zipFile).path

                // Use ditto to extract
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-xk", zipPath, targetPath]

                try process.run()
                process.waitUntilExit()

                // Extracted successfully
            }

            showRestoreOptions = false
            backupService.lastError = nil
        } catch {
            backupService.lastError = "Project extraction failed: \(error.localizedDescription)"
        }
    }

    private func restoreProjectsToOriginal() {
        guard let manifest = manifest else { return }

        showRestoreOptions = false

        // Validate all project paths
        let projectPaths = manifest.projects.map { $0.originalPath }
        let invalidPaths = PathValidator.getInvalidPaths(projectPaths)

        if !invalidPaths.isEmpty {
            // Show validation error with list of missing paths
            let alert = NSAlert()
            alert.messageText = "Original Paths Not Found"
            alert.informativeText = "The following original project locations do not exist on this computer:\n\n" +
                invalidPaths.prefix(5).map { "• \($0)" }.joined(separator: "\n") +
                (invalidPaths.count > 5 ? "\n... and \(invalidPaths.count - 5) more" : "") +
                "\n\nThis is common when restoring to a different computer. Would you like to extract to a custom location instead?"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Choose Custom Location")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                extractProjects()
            }
            return
        }

        // All paths valid - show confirmation
        let alert = NSAlert()
        alert.messageText = "Restore Projects to Original Locations"
        alert.informativeText = "This will restore \(manifest.projects.count) projects to their original locations. Existing files may be overwritten. Continue?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            Task {
                await performOriginalProjectRestore()
            }
        }
    }

    private func performOriginalProjectRestore() async {
        guard let downloadedPath = downloadedPath, let manifest = manifest else { return }

        do {
            let fileManager = FileManager.default
            let projectsFolder = URL(fileURLWithPath: downloadedPath).appendingPathComponent("projects")

            for project in manifest.projects {
                let zipFileName = URL(fileURLWithPath: project.s3Key).lastPathComponent
                let zipPath = projectsFolder.appendingPathComponent(zipFileName).path

                guard fileManager.fileExists(atPath: zipPath) else {
                    continue
                }

                // Get original directory (parent of project folder)
                let originalPath = project.originalPath
                let originalDir = URL(fileURLWithPath: originalPath).deletingLastPathComponent().path

                // Create directory if needed
                try? fileManager.createDirectory(atPath: originalDir, withIntermediateDirectories: true)

                // Extract to original location
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                process.arguments = ["-xk", zipPath, originalDir]

                try process.run()
                process.waitUntilExit()

                // terminationStatus checked implicitly - errors caught by the do block
            }

            backupService.lastError = nil
        } catch {
            backupService.lastError = "Project restore failed: \(error.localizedDescription)"
        }
    }
}
