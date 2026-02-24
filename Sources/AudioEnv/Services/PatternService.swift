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

    // MARK: - Built-in Patterns

    /// Default patterns that always appear for all users.
    static let builtInPatterns: [BouncePattern] = [
        BouncePattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "BPM (brackets)",
            segments: [
                PatternSegment(type: .title),
                PatternSegment(type: .literal, literalValue: " ["),
                PatternSegment(type: .bpm),
                PatternSegment(type: .literal, literalValue: "] "),
                PatternSegment(type: .stage),
            ],
            exampleFileName: "BA SongName [120] mix.wav",
            isBuiltIn: true
        ),
        BouncePattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "BPM suffix + version + stage",
            segments: [
                PatternSegment(type: .title),
                PatternSegment(type: .literal, literalValue: "_"),
                PatternSegment(type: .bpm),
                PatternSegment(type: .literal, literalValue: "bpm_v"),
                PatternSegment(type: .version),
                PatternSegment(type: .literal, literalValue: "_"),
                PatternSegment(type: .stage),
            ],
            exampleFileName: "TrackName_120bpm_v2_rough.wav",
            isBuiltIn: true
        ),
        BouncePattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Key + BPM + stage",
            segments: [
                PatternSegment(type: .title),
                PatternSegment(type: .literal, literalValue: "_"),
                PatternSegment(type: .key),
                PatternSegment(type: .literal, literalValue: "_"),
                PatternSegment(type: .bpm),
                PatternSegment(type: .literal, literalValue: "bpm_"),
                PatternSegment(type: .stage),
            ],
            exampleFileName: "MySong_Cm_128bpm_master.wav",
            isBuiltIn: true
        ),
        BouncePattern(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Version + stage",
            segments: [
                PatternSegment(type: .title),
                PatternSegment(type: .literal, literalValue: "_v"),
                PatternSegment(type: .version),
                PatternSegment(type: .literal, literalValue: "_"),
                PatternSegment(type: .stage),
            ],
            exampleFileName: "Song Name_v3_final.wav",
            isBuiltIn: true
        ),
    ]

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

    /// Split a filename into segments and the delimiters between them.
    /// `delimiters[i]` is the delimiter string between `segments[i]` and `segments[i+1]`.
    func splitFileNameWithDelimiters(_ fileName: String) -> (segments: [String], delimiters: [String]) {
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
            return ([baseName], [])
        }

        let range = NSRange(baseName.startIndex..<baseName.endIndex, in: baseName)
        var segments: [String] = []
        var delimiters: [String] = []
        var lastEnd = baseName.startIndex

        regex.enumerateMatches(in: baseName, range: range) { match, _, _ in
            guard let match else { return }
            let matchRange = Range(match.range, in: baseName)!
            let segment = String(baseName[lastEnd..<matchRange.lowerBound])
            if !segment.isEmpty {
                segments.append(segment)
                delimiters.append(String(baseName[matchRange]))
            }
            lastEnd = matchRange.upperBound
        }

        // Add remaining
        let remaining = String(baseName[lastEnd...])
        if !remaining.isEmpty {
            segments.append(remaining)
        }

        // delimiters should have one fewer element than segments
        if delimiters.count >= segments.count && !delimiters.isEmpty {
            delimiters.removeLast()
        }

        return (segments, delimiters)
    }

    /// Split a filename into segments on common delimiters (backward-compatible).
    func splitFileName(_ fileName: String) -> [String] {
        splitFileNameWithDelimiters(fileName).segments
    }

    // MARK: - API Persistence

    func fetchPatterns(token: String) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let url = URL(string: "\(baseURL)/api/patterns/")!
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                lastError = "Failed to fetch patterns"
                return
            }

            let decoder = FlexibleISO8601.makeAPIDecoder()
            var userPatterns: [BouncePattern]
            // Try paginated response first, fall back to plain array
            if let paginated = try? decoder.decode(PaginatedResponse<BouncePattern>.self, from: data) {
                userPatterns = paginated.items
            } else {
                userPatterns = try decoder.decode([BouncePattern].self, from: data)
            }
            // Merge built-in patterns (first) with user patterns
            let userIds = Set(userPatterns.map(\.id))
            let builtIns = Self.builtInPatterns.filter { !userIds.contains($0.id) }
            patterns = builtIns + userPatterns
        } catch {
            lastError = error.localizedDescription
            logger.error("fetchPatterns failed: \(error)")
            // Still show built-in patterns if fetch fails
            if patterns.isEmpty {
                patterns = Self.builtInPatterns
            }
        }
    }

    func savePattern(_ pattern: BouncePattern, token: String) async throws {
        let url = URL(string: "\(baseURL)/api/patterns/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        // Build API-compatible payload: pattern_string + segments_json
        let segmentDicts: [[String: String]] = pattern.segments.map { seg in
            var dict: [String: String] = ["type": seg.type.rawValue]
            if let lit = seg.literalValue { dict["literal_value"] = lit }
            if let cr = seg.customRegex { dict["custom_regex"] = cr }
            return dict
        }

        var payload: [String: Any] = [
            "name": pattern.name,
            "pattern_string": pattern.patternString,
            "segments_json": segmentDicts,
        ]
        if let example = pattern.exampleFileName {
            payload["example_file_name"] = example
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PatternSaveError.serverError("Invalid response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PatternSaveError.unauthorized
        }
        guard http.statusCode == 200 || http.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let msg = "Failed to save pattern (HTTP \(http.statusCode)): \(body)"
            lastError = msg
            throw PatternSaveError.serverError(msg)
        }

        let decoder = FlexibleISO8601.makeAPIDecoder()
        let saved = try decoder.decode(BouncePattern.self, from: data)
        patterns.insert(saved, at: 0)
        logger.info("Saved pattern: \(saved.name)")
    }

    enum PatternSaveError: LocalizedError {
        case serverError(String)
        case unauthorized

        var errorDescription: String? {
            switch self {
            case .serverError(let msg): return msg
            case .unauthorized: return "Not authenticated"
            }
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
