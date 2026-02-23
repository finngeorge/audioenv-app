import Foundation

// MARK: - Pattern segment types

/// Types of segments that can appear in a bounce filename pattern.
enum PatternSegmentType: String, CaseIterable, Codable, Identifiable, Equatable {
    case title
    case artist
    case bpm
    case version
    case stage
    case key
    case date
    case take
    case literal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title: return "Title"
        case .artist: return "Artist"
        case .bpm: return "BPM"
        case .version: return "Version"
        case .stage: return "Stage"
        case .key: return "Key"
        case .date: return "Date"
        case .take: return "Take"
        case .literal: return "Literal"
        }
    }

    var color: String {
        switch self {
        case .title: return "3B82F6"    // blue
        case .artist: return "8B5CF6"   // purple
        case .bpm: return "EF4444"      // red
        case .version: return "F59E0B"  // amber
        case .stage: return "10B981"    // emerald
        case .key: return "EC4899"      // pink
        case .date: return "06B6D4"     // cyan
        case .take: return "F97316"     // orange
        case .literal: return "6B7280"  // gray
        }
    }

    /// Default regex fragment for matching this segment type.
    var defaultRegex: String {
        switch self {
        case .title: return "(?<title>.+?)"
        case .artist: return "(?<artist>.+?)"
        case .bpm: return "(?<bpm>\\d{2,3})"
        case .version: return "(?<version>\\d+)"
        case .stage: return "(?<stage>rough|mix|master|stem|demo|export|final)"
        case .key: return "(?<key>[A-Ga-g][#b]?m?)"
        case .date: return "(?<date>\\d{4}[-_]?\\d{2}[-_]?\\d{2})"
        case .take: return "(?<take>\\d+)"
        case .literal: return ""
        }
    }
}

// MARK: - Pattern segment

/// A single segment within a bounce filename pattern.
struct PatternSegment: Codable, Equatable, Identifiable {
    let id: UUID
    var type: PatternSegmentType
    var literalValue: String?
    var customRegex: String?

    init(type: PatternSegmentType, literalValue: String? = nil, customRegex: String? = nil) {
        self.id = UUID()
        self.type = type
        self.literalValue = literalValue
        self.customRegex = customRegex
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case literalValue = "literal_value"
        case customRegex = "custom_regex"
    }

    /// The regex fragment for this segment.
    var regexFragment: String {
        if let custom = customRegex, !custom.isEmpty {
            return custom
        }
        if type == .literal, let lit = literalValue {
            return NSRegularExpression.escapedPattern(for: lit)
        }
        return type.defaultRegex
    }

    /// The pattern token for this segment (e.g. `{title}` or literal text).
    var patternToken: String {
        if type == .literal {
            return literalValue ?? ""
        }
        return "{\(type.rawValue)}"
    }
}

// MARK: - Bounce pattern

/// A named pattern for parsing bounce filenames into structured metadata.
struct BouncePattern: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var segments: [PatternSegment]
    var exampleFileName: String?
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        segments: [PatternSegment],
        exampleFileName: String? = nil,
        createdAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.segments = segments
        self.exampleFileName = exampleFileName
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, segments
        case exampleFileName = "example_file_name"
        case createdAt = "created_at"
        case patternString = "pattern_string"
        case segmentsJson = "segments_json"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decode(String.self, forKey: .name)
        exampleFileName = try container.decodeIfPresent(String.self, forKey: .exampleFileName)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)

        // Try native format first: segments array
        if let segs = try? container.decode([PatternSegment].self, forKey: .segments) {
            segments = segs
        }
        // API response format: segments_json contains array of segment dicts
        else if let segData = try? container.decode([[String: String]].self, forKey: .segmentsJson) {
            segments = segData.compactMap { dict -> PatternSegment? in
                guard let typeStr = dict["type"],
                      let segType = PatternSegmentType(rawValue: typeStr) else { return nil }
                return PatternSegment(
                    type: segType,
                    literalValue: dict["literal_value"],
                    customRegex: dict["custom_regex"]
                )
            }
        }
        // Last resort: parse pattern_string
        else if let ps = try? container.decode(String.self, forKey: .patternString) {
            segments = BouncePattern.parsePatternStringStatic(ps)
        } else {
            segments = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(segments, forKey: .segments)
        try container.encodeIfPresent(exampleFileName, forKey: .exampleFileName)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    /// The full pattern string, e.g. `{title}_{bpm}bpm_v{version}_{stage}`.
    var patternString: String {
        segments.map(\.patternToken).joined()
    }

    /// Static helper for decoding pattern strings without a PatternService instance.
    static func parsePatternStringStatic(_ patternString: String) -> [PatternSegment] {
        var segments: [PatternSegment] = []
        var remaining = patternString[...]

        while !remaining.isEmpty {
            if remaining.hasPrefix("{") {
                if let closeBrace = remaining.dropFirst().firstIndex(of: "}") {
                    let typeStr = String(remaining[remaining.index(after: remaining.startIndex)..<closeBrace])
                    if let segType = PatternSegmentType(rawValue: typeStr) {
                        segments.append(PatternSegment(type: segType))
                    } else {
                        segments.append(PatternSegment(type: .literal, literalValue: "{\(typeStr)}"))
                    }
                    remaining = remaining[remaining.index(after: closeBrace)...]
                } else {
                    segments.append(PatternSegment(type: .literal, literalValue: String(remaining)))
                    break
                }
            } else {
                if let nextBrace = remaining.firstIndex(of: "{") {
                    segments.append(PatternSegment(type: .literal, literalValue: String(remaining[..<nextBrace])))
                    remaining = remaining[nextBrace...]
                } else {
                    segments.append(PatternSegment(type: .literal, literalValue: String(remaining)))
                    break
                }
            }
        }

        return segments
    }
}

// MARK: - Extracted metadata

/// Metadata extracted from a bounce filename using a pattern.
struct ExtractedBounceMetadata: Equatable {
    var title: String?
    var artist: String?
    var bpm: Int?
    var version: Int?
    var stage: BounceStage?
    var key: String?
    var date: String?
    var take: Int?

    var isEmpty: Bool {
        title == nil && artist == nil && bpm == nil && version == nil
            && stage == nil && key == nil && date == nil && take == nil
    }
}

// MARK: - Bounce stage

/// Standard stages in audio production workflow.
enum BounceStage: String, CaseIterable, Codable, Identifiable, Equatable {
    case rough
    case mix
    case master
    case stem
    case demo
    case export
    case final_ = "final"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rough: return "Rough"
        case .mix: return "Mix"
        case .master: return "Master"
        case .stem: return "Stem"
        case .demo: return "Demo"
        case .export: return "Export"
        case .final_: return "Final"
        }
    }

    /// Initialize from a matched string (case-insensitive).
    init?(from string: String) {
        let lower = string.lowercased()
        if let match = BounceStage.allCases.first(where: { $0.rawValue == lower }) {
            self = match
        } else if lower == "final" {
            self = .final_
        } else {
            return nil
        }
    }
}

// MARK: - Collection source

/// How a collection's contents are determined.
enum CollectionSource: Codable, Equatable {
    case manual
    case query(Query)
    case smart(Query)
    case pattern(BouncePattern)

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .query: return "Query-Based"
        case .smart: return "Smart (Auto-Update)"
        case .pattern: return "Pattern-Based"
        }
    }

    var icon: String {
        switch self {
        case .manual: return "hand.tap"
        case .query: return "magnifyingglass"
        case .smart: return "sparkles"
        case .pattern: return "textformat.abc"
        }
    }
}
