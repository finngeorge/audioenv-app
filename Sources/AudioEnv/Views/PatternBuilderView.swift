import SwiftUI

/// Sheet for visual bounce filename pattern teaching.
struct PatternBuilderView: View {
    @EnvironmentObject var patternService: PatternService
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService
    @Environment(\.dismiss) private var dismiss

    @State private var exampleFileName = ""
    @State private var patternName = "New Pattern"
    @State private var segments: [(text: String, type: PatternSegmentType)] = []
    @State private var patternString = ""
    @State private var delimiters: [String] = []
    @State private var testResults: [(Bounce, ExtractedBounceMetadata)] = []
    @State private var isTestingPattern = false
    @State private var saveError: String?
    @State private var showSaveError = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                Text("Pattern Builder")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Teach the pattern engine how your bounce files are named")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color.secondary.opacity(0.05))

            ScrollView {
                VStack(spacing: 20) {
                    // Pattern name
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Pattern Name")
                            .font(.headline)

                        TextField("e.g. Standard Bounce Format", text: $patternName)
                            .textFieldStyle(.roundedBorder)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)

                    // Example filename input
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Example Filename")
                            .font(.headline)

                        TextField("e.g. MyTrack_128bpm_v3_rough.wav", text: $exampleFileName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .onChange(of: exampleFileName) { _, newValue in
                                splitIntoSegments(newValue)
                            }

                        Text("Paste or type a bounce filename. The engine will split it into segments.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(12)

                    // Segment chips
                    if !segments.isEmpty {
                        segmentChipsSection
                    }

                    // Pattern string
                    if !segments.isEmpty {
                        patternStringSection
                    }

                    // Test results
                    if !testResults.isEmpty || isTestingPattern {
                        testResultsSection
                    }
                }
                .padding()
            }

            // Footer
            HStack(spacing: 12) {
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Test Pattern") {
                    testPattern()
                }
                .buttonStyle(.bordered)
                .disabled(segments.isEmpty)

                Button("Save Pattern") {
                    savePattern()
                }
                .buttonStyle(.borderedProminent)
                .disabled(patternName.trimmingCharacters(in: .whitespaces).isEmpty || segments.isEmpty)
            }
            .padding()
            .background(Color.secondary.opacity(0.05))
        }
        .frame(width: 700, height: 600)
        .alert("Save Failed", isPresented: $showSaveError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "Unknown error")
        }
    }

    // MARK: - Segment Chips

    private var segmentChipsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Segment Types")
                .font(.headline)

            Text("Click each segment to assign its type. Click again to cycle through types.")
                .font(.caption)
                .foregroundColor(.secondary)

            // Legend
            HStack(spacing: 12) {
                ForEach(PatternSegmentType.allCases.filter { $0 != .literal }) { type in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color(hex: type.color) ?? .gray)
                            .frame(width: 8, height: 8)
                        Text(type.label)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            // Chips
            HStack(spacing: 4) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Button {
                        cycleSegmentType(at: index)
                    } label: {
                        Text(segment.text)
                            .font(.system(.caption, design: .monospaced))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color(hex: segment.type.color)?.opacity(0.2) ?? Color.secondary.opacity(0.1))
                            .foregroundColor(Color(hex: segment.type.color) ?? .primary)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color(hex: segment.type.color) ?? .secondary, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help(segment.type.label)

                    // Show delimiter between segments
                    if index < segments.count - 1 {
                        Text(index < delimiters.count ? delimiters[index] : "_")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Pattern String

    private var patternStringSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pattern String")
                .font(.headline)

            TextField("Pattern", text: $patternString)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Text("Edit directly or use the chips above. Format: {title}_{bpm}bpm_v{version}_{stage}")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Test Results

    private var testResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Test Results")
                    .font(.headline)
                Spacer()
                if isTestingPattern {
                    ProgressView()
                        .controlSize(.small)
                }
                Text("\(testResults.count) matches")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if testResults.isEmpty && !isTestingPattern {
                Text("No bounces matched this pattern")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(testResults.prefix(10).enumerated()), id: \.offset) { _, result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.0.fileName)
                            .font(.system(.caption, design: .monospaced))
                            .fontWeight(.medium)

                        HStack(spacing: 12) {
                            if let title = result.1.title {
                                metadataBadge("Title", title, "3B82F6")
                            }
                            if let bpm = result.1.bpm {
                                metadataBadge("BPM", "\(bpm)", "EF4444")
                            }
                            if let version = result.1.version {
                                metadataBadge("v", "\(version)", "F59E0B")
                            }
                            if let stage = result.1.stage {
                                metadataBadge("Stage", stage.label, "10B981")
                            }
                            if let key = result.1.key {
                                metadataBadge("Key", key, "EC4899")
                            }
                        }
                    }
                    .padding(.vertical, 4)

                    if result.0.id != testResults.last?.0.id {
                        Divider()
                    }
                }

                if testResults.count > 10 {
                    Text("... and \(testResults.count - 10) more matches")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(12)
    }

    private func metadataBadge(_ label: String, _ value: String, _ colorHex: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(Color(hex: colorHex) ?? .primary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background((Color(hex: colorHex) ?? .gray).opacity(0.1))
        .cornerRadius(4)
    }

    // MARK: - Actions

    private func splitIntoSegments(_ fileName: String) {
        let result = patternService.splitFileNameWithDelimiters(fileName)
        segments = result.segments.map { (text: $0, type: PatternSegmentType.literal) }
        delimiters = result.delimiters
        updatePatternString()
    }

    private func cycleSegmentType(at index: Int) {
        let types: [PatternSegmentType] = [.literal, .title, .artist, .bpm, .version, .stage, .key, .date, .take]
        if let currentIdx = types.firstIndex(of: segments[index].type) {
            let nextIdx = (currentIdx + 1) % types.count
            segments[index].type = types[nextIdx]
        } else {
            segments[index].type = .title
        }
        updatePatternString()
    }

    private func updatePatternString() {
        var result = ""
        for (index, segment) in segments.enumerated() {
            if segment.type == .literal {
                result += segment.text
            } else {
                result += "{\(segment.type.rawValue)}"
            }
            if index < segments.count - 1 {
                result += index < delimiters.count ? delimiters[index] : "_"
            }
        }
        patternString = result
    }

    private func testPattern() {
        let taggedRanges = segments.map { ($0.text, $0.type) }
        let pattern = patternService.buildPatternFromTaggedRanges(
            fileName: exampleFileName,
            taggedRanges: taggedRanges
        )
        testResults = patternService.applyPatternToBounces(pattern, bounces: bounceService.bounces)
    }

    private func savePattern() {
        let taggedRanges = segments.map { ($0.text, $0.type) }
        var pattern = patternService.buildPatternFromTaggedRanges(
            fileName: exampleFileName,
            taggedRanges: taggedRanges
        )
        pattern = BouncePattern(
            name: patternName,
            segments: pattern.segments,
            exampleFileName: exampleFileName
        )

        Task {
            do {
                let token = try await auth.validToken()
                try await patternService.savePattern(pattern, token: token)
                dismiss()
            } catch PatternService.PatternSaveError.unauthorized {
                // Token was stale — refresh and retry once
                if await auth.handleUnauthorized(), let freshToken = auth.authToken {
                    do {
                        try await patternService.savePattern(pattern, token: freshToken)
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                        showSaveError = true
                    }
                } else {
                    saveError = "Session expired. Please log in again."
                    showSaveError = true
                }
            } catch {
                saveError = error.localizedDescription
                showSaveError = true
            }
        }
    }
}
