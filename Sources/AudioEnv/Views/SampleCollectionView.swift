import SwiftUI

/// View for collecting project samples and media files
struct SampleCollectionView: View {
    let session: AudioSession
    @EnvironmentObject var sampleCollector: SampleCollectionService
    @EnvironmentObject var scanner: ScannerService
    @Environment(\.dismiss) private var dismiss

    @State private var outputDirectory: String = ""
    @State private var showingFilePicker = false

    /// Always read the latest version of this session from the scanner's array
    private var liveSession: AudioSession {
        scanner.sessions.first(where: { $0.path == session.path }) ?? session
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Collect Samples")
                        .font(.title2)
                        .bold()
                    Text(session.name)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            // Warning banner for Logic/Pro Tools
            if session.format != .ableton {
                warningBanner
            }

            // Output directory selection
            VStack(alignment: .leading, spacing: 8) {
                Label("Output Directory", systemImage: "folder")
                    .font(.headline)
                    .fontWeight(.semibold)

                HStack {
                    Text(outputDirectory.isEmpty ? "Not selected" : outputDirectory)
                        .font(.caption)
                        .foregroundStyle(outputDirectory.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Choose...") {
                        showingFilePicker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)

                Text("Default: Samples/Collected inside the project folder")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Progress view
            if sampleCollector.isCollecting {
                progressView
            }

            // Results view
            if let result = sampleCollector.lastResult, !sampleCollector.isCollecting {
                resultsView(result: result)
            }

            // Error display
            if let error = sampleCollector.lastError {
                errorView(error: error)
            }

            Spacer()

            // Action buttons
            HStack {
                if !sampleCollector.isCollecting {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button {
                    Task {
                        await collectSamples()
                    }
                } label: {
                    HStack {
                        Image(systemName: "tray.and.arrow.down")
                        Text("Collect Samples")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(sampleCollector.isCollecting)
            }
        }
        .padding()
        .frame(width: 600, height: 500)
        .onAppear {
            setupDefaultOutputDirectory()
        }
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                outputDirectory = url.path
            }
        }
    }

    // MARK: - Subviews

    private var warningBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Binary Format Limitation")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text("This DAW uses a proprietary binary format. Collection will include project media folders but may miss externally referenced samples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    private var progressView: some View {
        VStack(spacing: 12) {
            HStack {
                ProgressView()
                    .scaleEffect(0.8)
                Text("Collecting samples...")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            ProgressView(value: sampleCollector.collectionProgress)
                .progressViewStyle(.linear)

            Text("\(Int(sampleCollector.collectionProgress * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Recent log entries
            if !sampleCollector.collectionLog.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sampleCollector.collectionLog.suffix(10)) { entry in
                            logEntryRow(entry)
                        }
                    }
                }
                .frame(height: 100)
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(Color.blue.opacity(0.05))
        .cornerRadius(8)
    }

    private func resultsView(result: CollectionResult) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Collection Complete")
                        .font(.headline)
                        .fontWeight(.semibold)

                    Text("\(result.copiedFiles) files collected (\(result.formattedSize))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if result.failedFiles > 0 {
                Text("⚠️ \(result.failedFiles) files failed to copy")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !result.missingFiles.isEmpty {
                Text("⚠️ \(result.missingFiles.count) files were missing")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let warning = result.warning {
                Text("ℹ️ \(warning)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Text("Output:")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(result.outputDirectory.path)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: result.outputDirectory.path)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .cornerRadius(8)
    }

    private func errorView(error: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
            Text(error)
                .font(.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    private func logEntryRow(_ entry: CollectionLogEntry) -> some View {
        HStack(spacing: 4) {
            statusIcon(entry.status)
            Text(entry.path)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: CollectionStatus) -> some View {
        switch status {
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
        case .missing:
            Image(systemName: "questionmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .info:
            Image(systemName: "info.circle.fill")
                .font(.caption2)
                .foregroundStyle(.blue)
        }
    }

    // MARK: - Actions

    private func setupDefaultOutputDirectory() {
        // Default to "Samples/Collected" inside the project folder (matches Ableton's "Collect All and Save")
        let projectPath = FileSystemHelpers.getProjectFolderPath(from: session)
        let projectURL = URL(fileURLWithPath: projectPath)
        let defaultOutput = projectURL.appendingPathComponent("Samples").appendingPathComponent("Collected")
        outputDirectory = defaultOutput.path
    }

    private func collectSamples() async {
        guard !sampleCollector.isCollecting else { return }

        let outputURL = URL(fileURLWithPath: outputDirectory)

        // Force a fresh parse to ensure samplePaths are populated (cache may be stale)
        await withCheckedContinuation { continuation in
            scanner.parseIndividualSession(path: session.path) {
                continuation.resume()
            }
        }

        do {
            _ = try await sampleCollector.collectSamples(for: liveSession, outputDirectory: outputURL)
        } catch {
            sampleCollector.lastError = error.localizedDescription
        }
    }
}

#Preview {
    let session = AudioSession(
        name: "Test Project",
        path: "/Users/test/Music/Test Project.als",
        format: .ableton,
        modifiedDate: Date(),
        fileSize: 1024000,
        project: nil
    )

    return SampleCollectionView(session: session)
        .environmentObject(SampleCollectionService())
}
