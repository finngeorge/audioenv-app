import SwiftUI

/// Content column for the Patterns sidebar entry.
/// Lists saved patterns, shows match counts, and opens the pattern builder.
struct PatternBrowserView: View {
    @EnvironmentObject var patternService: PatternService
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService

    @Binding var selectedPattern: BouncePattern?

    @State private var showPatternBuilder = false
    @State private var search = ""

    private var filteredPatterns: [BouncePattern] {
        if search.isEmpty { return patternService.patterns }
        let q = search.lowercased()
        return patternService.patterns.filter {
            $0.name.lowercased().contains(q) || $0.patternString.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search + create
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search patterns...", text: $search)
                    .textFieldStyle(.roundedBorder)

                Button {
                    showPatternBuilder = true
                } label: {
                    Label("New Pattern", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal)

            Divider().padding(.top, 4)

            if patternService.isLoading && patternService.patterns.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Loading patterns...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredPatterns.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No Patterns")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Patterns extract metadata like BPM, key, and version from your bounce filenames automatically.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                    Button("Create Pattern") {
                        showPatternBuilder = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredPatterns, selection: $selectedPattern) { pattern in
                    PatternRow(pattern: pattern, bounceCount: bounceService.bounces.count)
                        .tag(pattern)
                }
                .listStyle(.inset)
            }
        }
        .task {
            if let token = try? await auth.validToken() {
                await patternService.fetchPatterns(token: token)
            }
        }
        .sheet(isPresented: $showPatternBuilder) {
            PatternBuilderView()
        }
    }
}

// MARK: - Pattern Row

private struct PatternRow: View {
    let pattern: BouncePattern
    let bounceCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(pattern.name)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(1)

                if pattern.isBuiltIn {
                    Text("Built-in")
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.12))
                        .foregroundColor(.secondary)
                        .cornerRadius(3)
                }
            }

            Text(pattern.patternString)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)

            HStack(spacing: 8) {
                // Segment type badges
                let types = pattern.segments.filter { $0.type != .literal }.map(\.type)
                ForEach(Array(Set(types)).sorted(by: { $0.rawValue < $1.rawValue })) { type in
                    Text(type.label)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background((Color(hex: type.color) ?? .gray).opacity(0.12))
                        .foregroundColor(Color(hex: type.color) ?? .gray)
                        .cornerRadius(3)
                }

                if let example = pattern.exampleFileName {
                    Spacer()
                    Text(example)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}


// MARK: - Pattern Detail Panel

struct PatternDetailPanel: View {
    let pattern: BouncePattern
    @EnvironmentObject var patternService: PatternService
    @EnvironmentObject var bounceService: BounceService
    @EnvironmentObject var auth: AuthenticationService

    @State private var testResults: [(Bounce, ExtractedBounceMetadata)] = []
    @State private var hasTestedOnce = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 40))
                            .foregroundColor(.accentColor)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Text(pattern.name)
                            .font(.title)
                            .fontWeight(.bold)
                        if pattern.isBuiltIn {
                            Text("Built-in")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.15))
                                .foregroundColor(.secondary)
                                .cornerRadius(4)
                        }
                    }
                }
                .padding(.bottom, 8)

                // Pattern string
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pattern")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    Text(pattern.patternString)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)

                    if let example = pattern.exampleFileName {
                        InfoRow(label: "Example", value: example)
                    }

                    if let date = pattern.createdAt {
                        let formatter = DateFormatter()
                        let _ = formatter.dateStyle = .medium
                        InfoRow(label: "Created", value: formatter.string(from: date))
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Segments
                VStack(alignment: .leading, spacing: 12) {
                    Text("Segments")
                        .font(.headline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        ForEach(pattern.segments) { segment in
                            Text(segment.patternToken)
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                                .background((Color(hex: segment.type.color) ?? .gray).opacity(0.15))
                                .foregroundColor(Color(hex: segment.type.color) ?? .primary)
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(hex: segment.type.color) ?? .secondary, lineWidth: 1)
                                )
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Test results
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Matching Bounces")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Test") {
                            runTest()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    if testResults.isEmpty {
                        if hasTestedOnce {
                            Text("No bounces matched this pattern")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            Text("Click Test to find matching bounces")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("\(testResults.count) bounces matched")
                            .font(.caption)
                            .foregroundColor(.blue)

                        ForEach(Array(testResults.prefix(20).enumerated()), id: \.offset) { _, result in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(result.0.fileName)
                                    .font(.system(.caption, design: .monospaced))
                                    .fontWeight(.medium)

                                HStack(spacing: 8) {
                                    if let title = result.1.title {
                                        extractedBadge("Title", title, "3B82F6")
                                    }
                                    if let bpm = result.1.bpm {
                                        extractedBadge("BPM", "\(bpm)", "EF4444")
                                    }
                                    if let version = result.1.version {
                                        extractedBadge("v", "\(version)", "F59E0B")
                                    }
                                    if let stage = result.1.stage {
                                        extractedBadge("Stage", stage.label, "10B981")
                                    }
                                    if let key = result.1.key {
                                        extractedBadge("Key", key, "EC4899")
                                    }
                                }
                            }
                            .padding(.vertical, 4)

                            if result.0.id != testResults.last?.0.id {
                                Divider()
                            }
                        }

                        if testResults.count > 20 {
                            Text("... and \(testResults.count - 20) more")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(12)

                // Actions
                if !pattern.isBuiltIn {
                    HStack(spacing: 8) {
                        Button(role: .destructive) {
                            Task {
                                if let token = auth.authToken {
                                    await patternService.deletePattern(id: pattern.id, token: token)
                                }
                            }
                        } label: {
                            Label("Delete Pattern", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                }

                Spacer()
            }
            .padding(20)
        }
        .onAppear {
            runTest()
        }
    }

    private func runTest() {
        testResults = patternService.applyPatternToBounces(pattern, bounces: bounceService.bounces)
        hasTestedOnce = true
    }

    private func extractedBadge(_ label: String, _ value: String, _ colorHex: String) -> some View {
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
}
