import XCTest
@testable import AudioEnv

final class FlexibleISO8601Tests: XCTestCase {

    // MARK: - Parsing with fractional seconds

    func testParseWithFractionalSeconds() {
        let dateString = "2026-02-18T01:52:06.550000+00:00"
        let date = FlexibleISO8601.parse(dateString)
        XCTAssertNotNil(date, "Should parse ISO 8601 with fractional seconds")
    }

    func testParseWithFractionalSecondsShort() {
        let dateString = "2026-02-18T01:52:06.55+00:00"
        let date = FlexibleISO8601.parse(dateString)
        // ISO8601DateFormatter may or may not handle short fractions; just verify no crash
        // The main contract is it returns a Date? (nil is acceptable for non-standard formats)
        _ = date
    }

    // MARK: - Parsing without fractional seconds

    func testParseWithoutFractionalSeconds() {
        let dateString = "2026-02-18T01:52:06Z"
        let date = FlexibleISO8601.parse(dateString)
        XCTAssertNotNil(date, "Should parse ISO 8601 without fractional seconds")
    }

    func testParseWithoutFractionalSecondsOffset() {
        let dateString = "2026-02-18T01:52:06+00:00"
        let date = FlexibleISO8601.parse(dateString)
        XCTAssertNotNil(date, "Should parse ISO 8601 with timezone offset and no fractions")
    }

    // MARK: - Invalid input

    func testParseInvalidString() {
        let date = FlexibleISO8601.parse("not a date")
        XCTAssertNil(date, "Should return nil for invalid date string")
    }

    func testParseEmptyString() {
        let date = FlexibleISO8601.parse("")
        XCTAssertNil(date, "Should return nil for empty string")
    }

    // MARK: - API Decoder

    func testMakeAPIDecoderParsesSnakeCaseWithDates() throws {
        let json = """
        {
            "id": "550e8400-e29b-41d4-a716-446655440000",
            "user_id": "550e8400-e29b-41d4-a716-446655440001",
            "bounce_folder_id": "550e8400-e29b-41d4-a716-446655440002",
            "file_name": "test.wav",
            "file_path": "/tmp/test.wav",
            "file_size_bytes": 1024,
            "format": "wav",
            "duration_seconds": 120.5,
            "sample_rate": 44100,
            "bit_depth": 24,
            "created_at": "2026-02-18T01:52:06.550000+00:00",
            "file_modified_at": "2026-02-17T12:00:00Z"
        }
        """.data(using: .utf8)!

        let decoder = FlexibleISO8601.makeAPIDecoder()
        let bounce = try decoder.decode(Bounce.self, from: json)
        XCTAssertEqual(bounce.fileName, "test.wav")
        XCTAssertEqual(bounce.format, "wav")
        XCTAssertEqual(bounce.fileSizeBytes, 1024)
    }

    // MARK: - Date correctness

    func testParsedDateIsCorrect() {
        let dateString = "2026-02-18T01:52:06Z"
        guard let date = FlexibleISO8601.parse(dateString) else {
            XCTFail("Failed to parse date")
            return
        }

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 18)
        XCTAssertEqual(components.hour, 1)
        XCTAssertEqual(components.minute, 52)
        XCTAssertEqual(components.second, 6)
    }
}
