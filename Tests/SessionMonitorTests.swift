import XCTest
@testable import AudioEnv

final class SessionMonitorTests: XCTestCase {

    // MARK: - Ableton Log Parsing

    func testParseAbletonLogFindsCurrentProject() {
        let log = """
        2024-03-15T14:30:00.000000 info: Started: Live Build: 2024-03-01
        2024-03-15T14:32:07.123456 info: Loading document "/Users/test/Music/MyProject.als"
        2024-03-15T14:33:00.000000 info: Some other log line
        """

        let results = SessionMonitorService.parseAbletonLogLines(log)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].0, "/Users/test/Music/MyProject.als")
    }

    func testParseAbletonLogSkipsUntitled() {
        let log = """
        2024-03-15T14:30:00.000000 info: Started: Live Build: 2024-03-01
        2024-03-15T14:32:07.123456 info: Loading document "/Users/test/Music/untitled.als"
        2024-03-15T14:32:08.123456 info: Loading document "/Users/test/Music/untitled 2.als"
        2024-03-15T14:33:00.000000 info: Loading document "/Users/test/Music/RealProject.als"
        """

        let results = SessionMonitorService.parseAbletonLogLines(log)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].0, "/Users/test/Music/RealProject.als")
    }

    func testParseAbletonLogStopsAtSessionBoundary() {
        let log = """
        2024-03-14T10:00:00.000000 info: Started: Live Build: 2024-03-01
        2024-03-14T10:01:00.000000 info: Loading document "/Users/test/Music/OldProject.als"
        2024-03-15T14:30:00.000000 info: Started: Live Build: 2024-03-01
        2024-03-15T14:32:07.123456 info: Loading document "/Users/test/Music/NewProject.als"
        """

        let results = SessionMonitorService.parseAbletonLogLines(log)
        // Should only find NewProject (stops at the most recent "Started: Live Build:" boundary)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].0, "/Users/test/Music/NewProject.als")
    }

    func testParseAbletonLogExtractsTimestamp() {
        let log = """
        2024-03-15T14:30:00.000000 info: Started: Live Build: 2024-03-01
        2024-03-15T14:32:07.123456 info: Loading document "/Users/test/Music/MyProject.als"
        """

        let results = SessionMonitorService.parseAbletonLogLines(log)
        XCTAssertEqual(results.count, 1)

        // Ableton timestamps are local time — build expected date in local timezone
        let calendar = Calendar(identifier: .gregorian)
        var components = DateComponents()
        components.year = 2024
        components.month = 3
        components.day = 15
        components.hour = 14
        components.minute = 32
        components.second = 7
        let expected = calendar.date(from: components)!

        XCTAssertEqual(results[0].1.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1.0)
    }

    func testParseLogTimestamp() {
        let line = "2024-03-15T14:32:07.123456 info: Loading document \"/Users/test/project.als\""
        let date = SessionMonitorService.parseLogTimestamp(line)
        XCTAssertNotNil(date)

        // Ableton timestamps are local time
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 32)
        XCTAssertEqual(components.second, 7)
    }

    func testParseLogTimestampReturnsNilForGarbage() {
        let line = "not a timestamp at all"
        XCTAssertNil(SessionMonitorService.parseLogTimestamp(line))
    }

    // MARK: - LiveSession openedAt

    func testLiveSessionUsesProvidedOpenedAt() {
        let customDate = Date(timeIntervalSince1970: 1_000_000)
        let session = LiveSession(
            projectPath: "/tmp/test.als",
            projectName: "test",
            format: .ableton,
            dawPID: 123,
            openedAt: customDate
        )
        XCTAssertEqual(session.openedAt, customDate)
    }

    func testLiveSessionDefaultsOpenedAtToNow() {
        let before = Date()
        let session = LiveSession(
            projectPath: "/tmp/test.als",
            projectName: "test",
            format: .ableton,
            dawPID: 123
        )
        let after = Date()
        XCTAssertGreaterThanOrEqual(session.openedAt, before)
        XCTAssertLessThanOrEqual(session.openedAt, after)
    }

    // MARK: - Session Lifecycle

    func testSessionClosedSetsClosedAt() {
        var session = LiveSession(
            projectPath: "/tmp/test.als",
            projectName: "test",
            format: .ableton,
            dawPID: 123
        )
        XCTAssertTrue(session.isOpen)
        XCTAssertNil(session.closedAt)

        session.closedAt = Date()
        XCTAssertFalse(session.isOpen)
        XCTAssertNotNil(session.closedAt)
    }

    func testSessionDuration() {
        let openedAt = Date(timeIntervalSinceNow: -60) // 60 seconds ago
        var session = LiveSession(
            projectPath: "/tmp/test.als",
            projectName: "test",
            format: .ableton,
            dawPID: 123,
            openedAt: openedAt
        )
        // Open session — duration should be ~60s
        XCTAssertEqual(session.duration, 60, accuracy: 1.0)

        // Close it
        session.closedAt = Date()
        let closedDuration = session.duration
        // Should be ~60s and frozen
        XCTAssertEqual(closedDuration, 60, accuracy: 1.0)
    }

    func testSaveCountIncrements() {
        var session = LiveSession(
            projectPath: "/tmp/test.als",
            projectName: "test",
            format: .ableton,
            dawPID: 123
        )
        XCTAssertEqual(session.saveCount, 0)

        session.saveCount += 1
        XCTAssertEqual(session.saveCount, 1)

        session.saveCount += 1
        session.saveCount += 1
        XCTAssertEqual(session.saveCount, 3)
    }

    // MARK: - Snapshot Diffing

    func testSnapshotDiffDetectsAddedPlugins() {
        let prev = SessionSnapshot(
            fileSize: 1000,
            pluginNames: ["Pro-Q 3", "Serum"]
        )
        let curr = SessionSnapshot(
            fileSize: 1200,
            pluginNames: ["Pro-Q 3", "Serum", "Valhalla Room"]
        )

        let diff = SnapshotDiff.diff(from: prev, to: curr)
        XCTAssertEqual(diff.addedPlugins, ["Valhalla Room"])
        XCTAssertEqual(diff.removedPlugins, [])
    }

    func testSnapshotDiffDetectsRemovedPlugins() {
        let prev = SessionSnapshot(
            fileSize: 1200,
            pluginNames: ["Pro-Q 3", "Serum", "Valhalla Room"]
        )
        let curr = SessionSnapshot(
            fileSize: 1000,
            pluginNames: ["Pro-Q 3"]
        )

        let diff = SnapshotDiff.diff(from: prev, to: curr)
        XCTAssertEqual(diff.addedPlugins, [])
        XCTAssertEqual(diff.removedPlugins, ["Serum", "Valhalla Room"])
    }

    func testSnapshotDiffNoChangeReturnsEmpty() {
        let prev = SessionSnapshot(
            fileSize: 1000,
            pluginCount: 3,
            trackCount: 5,
            tempo: 120.0,
            pluginNames: ["Pro-Q 3", "Serum"]
        )
        let curr = SessionSnapshot(
            fileSize: 1000,
            pluginCount: 3,
            trackCount: 5,
            tempo: 120.0,
            pluginNames: ["Pro-Q 3", "Serum"]
        )

        let diff = SnapshotDiff.diff(from: prev, to: curr)
        XCTAssertEqual(diff.addedPlugins, [])
        XCTAssertEqual(diff.removedPlugins, [])
        XCTAssertEqual(diff.addedTracks, 0)
        XCTAssertEqual(diff.removedTracks, 0)
        XCTAssertFalse(diff.tempoChanged)
        XCTAssertNil(diff.oldTempo)
        XCTAssertNil(diff.newTempo)
    }

    func testSnapshotDiffDetectsTempoChange() {
        let prev = SessionSnapshot(fileSize: 1000, tempo: 120.0)
        let curr = SessionSnapshot(fileSize: 1000, tempo: 140.0)

        let diff = SnapshotDiff.diff(from: prev, to: curr)
        XCTAssertTrue(diff.tempoChanged)
        XCTAssertEqual(diff.oldTempo, 120.0)
        XCTAssertEqual(diff.newTempo, 140.0)
    }

    func testSnapshotDiffDetectsTrackChanges() {
        let prev = SessionSnapshot(fileSize: 1000, trackCount: 5)
        let curr = SessionSnapshot(fileSize: 1200, trackCount: 8)

        let diff = SnapshotDiff.diff(from: prev, to: curr)
        XCTAssertEqual(diff.addedTracks, 3)
        XCTAssertEqual(diff.removedTracks, 0)
    }

    func testSnapshotDiffDetectsTrackRemoval() {
        let prev = SessionSnapshot(fileSize: 1200, trackCount: 8)
        let curr = SessionSnapshot(fileSize: 1000, trackCount: 5)

        let diff = SnapshotDiff.diff(from: prev, to: curr)
        XCTAssertEqual(diff.addedTracks, 0)
        XCTAssertEqual(diff.removedTracks, 3)
    }

    func testLatestDiffNilWithFewerThanTwoSnapshots() {
        var session = LiveSession(
            projectPath: "/tmp/test.als",
            projectName: "test",
            format: .ableton,
            dawPID: 123
        )
        XCTAssertNil(session.latestDiff)

        session.snapshots.append(SessionSnapshot(fileSize: 1000))
        XCTAssertNil(session.latestDiff)
    }

    func testLatestDiffWithTwoSnapshots() {
        var session = LiveSession(
            projectPath: "/tmp/test.als",
            projectName: "test",
            format: .ableton,
            dawPID: 123
        )
        session.snapshots.append(SessionSnapshot(
            fileSize: 1000,
            pluginNames: ["Pro-Q 3"]
        ))
        session.snapshots.append(SessionSnapshot(
            fileSize: 1200,
            pluginNames: ["Pro-Q 3", "Serum"]
        ))

        let diff = session.latestDiff
        XCTAssertNotNil(diff)
        XCTAssertEqual(diff?.addedPlugins, ["Serum"])
        XCTAssertEqual(diff?.removedPlugins, [])
    }
}
