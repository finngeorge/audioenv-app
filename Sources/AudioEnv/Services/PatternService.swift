import Foundation
import os.log

/// Manages bounce filename pattern interpretation, metadata extraction, and pattern persistence.
@MainActor
class PatternService: ObservableObject {

    private let logger = Logger(subsystem: "com.audioenv.app", category: "Patterns")

    // MARK: - Published State

    @Published var patterns: [BouncePattern] = []
    @Published var isLoading = false
    @Published var lastError: String?

    private let baseURL: String = {
        if let override = UserDefaults.standard.string(forKey: "apiBaseURL"), !override.isEmpty {
            return override
        }
        return "https://api.audioenv.com"
    }()

    // MARK: - Pattern Parsing

    /// Parse a pattern string like `{title}_{bpm}bpm_v{version}_{stage}` into segments.
    func parsePatternString(_ patternString: String) -> [PatternSegment] {
        var segments: [PatternSegment] = []
        var remaining = patternString[...]

        while !remaining.isEmpty {
            if remaining.hasPrefix("{") {
                // Find closing brace
                if let closeBrace = remaining.dropFirst().firstIndex(of: "}") {
                    let typeStr = String(remaining[remaining.index(after: remaining.startIndex)..<closeBrace])
                    if let segType = PatternSegmentType(rawValue: typeStr) {
                        segments.append(PatternSegment(type: segType))
                    } else {
                        // Unknown type, treat as literal
                        segments.append(PatternSegment(type: .literal, literalValue: "{\(typeStr)}"))
                    }
                    remaining = remaining[remaining.index(after: closeBrace)...]
                } else {
                    // No closing brace, treat rest as literal
                    segments.append(PatternSegment(type: .literal, literalValue: String(remaining)))
                    break
                }
            } else {
                // Consume literal text until next `{` or end
                if let nextBrace = remaining.firstIndex(of: "{") {
                    let literal = String(remaining[..<nextBrace])
                    segments.append(PatternSegment(type: .literal, literalValue: literal))
                    remaining = remaining[nextBrace...]
                } else {
                    segments.append(PatternSegment(type: .literal, literalValue: String(remaining)))
                    break
                }
            }
        }

        return segments
    }

    // MARK: - Regex Building

    /// Build a regex pattern string from segments with named capture groups.
    func buildRegex(from segments: [PatternSegment]) -> String {
        segments.map(\.regexFragment).joined()
    }

    /// Build a regex from a BouncePattern.
    func buildRegex(from pattern: BouncePattern) -> String {
        buildRegex(from: pattern.segments)
    }

    // MARK: - Metadata Extraction

    /// Extract metadata from a filename using a pattern.
    func extractMetadata(from fileName: String, using pattern: BouncePattern) -> ExtractedBounceMetadata? {
        let regexStr = buildRegex(from: pattern)
        guard !regexStr.isEmpty else { return nil }

        // Strip file extension for matching
        let baseName: String
        if let dotIndex = fileName.lastIndex(of: ".") {
            baseName = String(fileName[..<dotIndex])
        } else {
            baseName = fileName
        }

        do {
            let regex = try NSRegularExpression(pattern: "^" + regexStr + "$", options: [.caseInsensitive])
            let range = NSRange(baseName.startIndex..<baseName.endIndex, in: baseName)

            guard let match = regex.firstMatch(in: baseName, range: range) else {
                return nil
            }

            var metadata = ExtractedBounceMetadata()

            metadata.title = extractNamedGroup("title", from: match, in: baseName)
            metadata.artist = extractNamedGroup("artist", from: match, in: baseName)

            if let bpmStr = extractNamedGroup("bpm", from: match, in: baseName) {
                metadata.bpm = Int(bpmStr)
            }

            if let versionStr = extractNamedGroup("version", from: match, in: baseName) {
                metadata.version = Int(versionStr)
            }

            if let stageStr = extractNamedGroup("stage", from: match, in: baseName) {
                metadata.stage = BounceStage(from: stageStr)
            }

            metadata.key = extractNamedGroup("key", from: match, in: baseName)
            metadata.date = extractNamedGroup("date", from: match, in: baseName)

            if let takeStr = extractNamedGroup("take", from: match, in: baseName) {
                metadata.take = Int(takeStr)
            }

            return metadata.isEmpty ? nil : metadata
        } catch {
            logger.error("Regex build failed for pattern '\(regexStr)': \(error)")
            return nil
        }
    }

    /// Batch-apply a pattern to a list of bounces, returning matched bounces with extracted metadata.
    func applyPatternToBounces(_ pattern: BouncePattern, bounces: [Bounce]) -> [(Bounce, ExtractedBounceMetadata)] {
        bounces.compactMap { bounce in
            if let metadata = extractMetadata(from: bounce.fileName, using: pattern) {
                return (bounce, metadata)
            }
            return nil
        }
    }

    // MARK: - Visual Pattern Teaching

    /// Build a pattern from user-tagged filename segments.
    /// `taggedRanges` maps segment indices (from splitting on delimiters) to their assigned types.
    func buildPatternFromTaggedRanges(
        fileName: String,
        taggedRanges: [(segment: String, type: PatternSegmentType)]
    ) -> BouncePattern {
        var segments: [PatternSegment] = []

        for (index, tagged) in taggedRanges.enumerated() {
            if tagged.type == .literal {
                segments.append(PatternSegment(type: .literal, literalValue: tagged.segment))
            } else {
                segments.append(PatternSegment(type: tagged.type))
            }

            // Add delimiter between segments (if not last)
            if index < taggedRanges.count - 1 {
                // Detect delimiter between this segment and next in original filename
                if let delimiter = detectDelimiter(between: tagged.segment, and: taggedRanges[index + 1].segment, in: fileName) {
                    segments.append(PatternSegment(type: .literal, literalValue: delimiter))
                }
            }
        }

        return BouncePattern(
            name: "Custom Pattern",
            segments: segments,
            exampleFileName: fileName
        )
    }

    /// Split a filename into segments on common delimiters.
    func splitFileName(_ fileName: String) -> [String] {
        // Strip extension
        let baseName: String
        if let dotIndex = fileName.lastIndex(of: ".") {
            baseName = String(fileName[..<dotIndex])
        } else {
            baseName = fileName
        }

        // Split on underscores, hyphens, and spaces
        let pattern = "[_\\-\\s]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [baseName]
        }

        let range = NSRange(baseName.startIndex..<baseName.endIndex, in: baseName)
        var segments: [String] = []
        var lastEnd = baseName.startIndex

        regex.enumerateMatches(in: baseName, range: range) { match, _, _ in
            guard let match else { return }
            let matchRange = Range(match.range, in: baseName)!
            let segment = String(baseName[lastEnd..<matchRange.lowerBound])
            if !segment.isEmpty {
                segments.append(segment)
            }
            lastEnd = matchRange.upperBound
        }

        // Add remaining
        let remaining = String(baseName[lastEnd...])
        if !remaining.isEmpty {
            segments.append(remaining)
        }

        return segments
    }

    // MARK: - API Persistence

    func fetchPatterns(token: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let url = URL(string: "\(baseURL)/api/patterns")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Failed to fetch patterns"
                return
            }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            patterns = try decoder.decode([BouncePattern].self, from: data)
        } catch {
            lastError = error.localizedDescription
            logger.error("fetchPatterns failed: \(error)")
        }
    }

    func savePattern(_ pattern: BouncePattern, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/patterns")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            request.httpBody = try encoder.encode(pattern)

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.statusCode == 200 || http.statusCode == 201 else {
                lastError = "Failed to save pattern"
                return
            }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            let saved = try decoder.decode(BouncePattern.self, from: data)
            patterns.insert(saved, at: 0)
            logger.info("Saved pattern: \(saved.name)")
        } catch {
            lastError = error.localizedDescription
            logger.error("savePattern failed: \(error)")
        }
    }

    func deletePattern(id: UUID, token: String) async {
        do {
            let url = URL(string: "\(baseURL)/api/patterns/\(id.uuidString)")!
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Failed to delete pattern"
                return
            }

            patterns.removeAll { $0.id == id }
        } catch {
            lastError = error.localizedDescription
            logger.error("deletePattern failed: \(error)")
        }
    }

    // MARK: - Private Helpers

    private func extractNamedGroup(_ name: String, from match: NSTextCheckingResult, in string: String) -> String? {
        let range = match.range(withName: name)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: string) else {
            return nil
        }
        return String(string[swiftRange])
    }

    private func detectDelimiter(between first: String, and second: String, in fileName: String) -> String? {
        guard let firstRange = fileName.range(of: first),
              let secondRange = fileName.range(of: second, range: firstRange.upperBound..<fileName.endIndex) else {
            return nil
        }
        let delimiter = String(fileName[firstRange.upperBound..<secondRange.lowerBound])
        return delimiter.isEmpty ? nil : delimiter
    }
}
