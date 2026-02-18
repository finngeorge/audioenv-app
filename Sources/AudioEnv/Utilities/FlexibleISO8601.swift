import Foundation

/// A flexible ISO 8601 date decoding strategy that handles Python's datetime.isoformat() output.
/// Python outputs: "2026-02-18T01:52:06.550000+00:00" (with fractional seconds and timezone offset)
/// Swift's built-in .iso8601 only handles: "2026-02-18T01:52:06Z" (no fractional seconds)
enum FlexibleISO8601 {

    /// ISO8601 formatter with fractional seconds support.
    private static let formatterWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// ISO8601 formatter without fractional seconds (fallback).
    private static let formatterWithout: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Parse an ISO 8601 date string, handling both with and without fractional seconds.
    static func parse(_ string: String) -> Date? {
        formatterWithFractional.date(from: string)
            ?? formatterWithout.date(from: string)
    }

    /// A JSONDecoder.DateDecodingStrategy that handles Python's datetime output.
    static var dateDecodingStrategy: JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = parse(string) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Cannot parse date: \(string)"
            ))
        }
    }

    /// Create a JSONDecoder configured for API responses (snake_case keys, flexible dates).
    static func makeAPIDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = dateDecodingStrategy
        return decoder
    }
}
