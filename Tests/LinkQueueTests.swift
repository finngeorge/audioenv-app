import XCTest
@testable import AudioEnv

@MainActor
final class LinkQueueTests: XCTestCase {

    /// Shape of GET /api/bounces/link-queue (see audioenv-api tests/test_link_queue.py).
    private let json = """
    {"total_bounces": 3, "total_groups": 2, "computed_at": "2026-10-08T12:00:00.123456+00:00",
     "groups": [
      {"song_key": "/Ableton/candy bass Project", "project_name": "candy bass", "count": 2, "max_score": 0.9,
       "items": [
        {"bounce": {"id": "11111111-1111-1111-1111-111111111111", "file_name": "candy bass 1.1 [135].wav",
                    "file_path": "/Users/me/Music/Originals/candy bass 1.1 [135].wav", "format": "wav",
                    "file_size_bytes": 1000, "duration_seconds": 182.5, "bpm": 135,
                    "file_modified_at": "2026-08-19T20:00:00+00:00"},
         "scanned_session_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "project_name": "candy bass", "score": 0.9,
         "reasons": [{"signal": "name", "label": "Name matches “candy bass”", "weight": 0.6},
                     {"signal": "tempo_mismatch", "label": "135 BPM vs project 120", "weight": -0.2}],
         "alternatives": [{"scanned_session_id": "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb",
                           "project_name": "candy bass beat", "score": 0.45, "reasons": []}]},
        {"bounce": {"id": "22222222-2222-2222-2222-222222222222", "file_name": "candy bass 1.2.wav",
                    "file_path": "/x/candy bass 1.2.wav", "format": "wav", "file_size_bytes": 1,
                    "duration_seconds": null, "bpm": null, "file_modified_at": "2026-08-20T20:00:00Z"},
         "scanned_session_id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", "project_name": "candy bass", "score": 0.6,
         "reasons": [], "alternatives": []}]},
      {"song_key": "/Ableton/glance Project", "project_name": "glance", "count": 1, "max_score": 0.6,
       "items": [
        {"bounce": {"id": "33333333-3333-3333-3333-333333333333", "file_name": "glance.wav",
                    "file_path": "/x/glance.wav", "format": "wav", "file_size_bytes": 1,
                    "duration_seconds": null, "bpm": null, "file_modified_at": "2026-08-21T20:00:00Z"},
         "scanned_session_id": "cccccccc-cccc-cccc-cccc-cccccccccccc", "project_name": "glance", "score": 0.6,
         "reasons": [], "alternatives": []}]}
     ]}
    """

    private func loadedQueue() throws -> LinkQueueService {
        let response = try FlexibleISO8601.makeAPIDecoder().decode(LinkQueueResponse.self, from: Data(json.utf8))
        let queue = LinkQueueService()
        queue.replaceGroups(response.groups)
        return queue
    }

    func testDecodesQueueWithTopPredictionFirst() throws {
        let queue = try loadedQueue()
        XCTAssertEqual(queue.remainingCount, 3)
        let item = try XCTUnwrap(queue.currentItem)
        XCTAssertEqual(item.bounce.fileName, "candy bass 1.1 [135].wav")
        XCTAssertEqual(item.predictions.map(\.projectName), ["candy bass", "candy bass beat"])
        XCTAssertEqual(item.predictions[0].reasons[1].weight, -0.2)
        XCTAssertEqual(item.bounce.asBounce.filePath, "/Users/me/Music/Originals/candy bass 1.1 [135].wav")
    }

    func testUpDownStaysWithinPredictions() throws {
        let queue = try loadedQueue()
        queue.movePrediction(by: -1)
        XCTAssertEqual(queue.predictionIndex, 0)
        queue.movePrediction(by: 1)
        XCTAssertEqual(queue.predictionIndex, 1)
        queue.movePrediction(by: 1)
        XCTAssertEqual(queue.predictionIndex, 1)          // only two predictions
    }

    func testSkipMovesCardToBackOfGroup() throws {
        let queue = try loadedQueue()
        queue.skip()
        XCTAssertEqual(queue.currentItem?.bounce.fileName, "candy bass 1.2.wav")
        XCTAssertEqual(queue.currentGroup?.items.last?.bounce.fileName, "candy bass 1.1 [135].wav")
        XCTAssertEqual(queue.remainingCount, 3)            // skipping records nothing
    }

    func testSkippingALoneCardMovesItsGroupToTheEnd() throws {
        let queue = try loadedQueue()
        queue.selectGroup(1)
        queue.skip()
        XCTAssertEqual(queue.groups.last?.projectName, "glance")
    }

    func testRefreshKeepsTheSameSongSelected() throws {
        let queue = try loadedQueue()
        queue.selectGroup(1)
        queue.replaceGroups(queue.groups.reversed())
        XCTAssertEqual(queue.currentGroup?.projectName, "glance")
    }
}
