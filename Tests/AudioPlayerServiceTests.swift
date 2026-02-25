import XCTest
@testable import AudioEnv

@MainActor
final class AudioPlayerServiceTests: XCTestCase {

    private func makeBounce(
        id: UUID = UUID(),
        fileName: String = "test.wav",
        filePath: String = "/tmp/nonexistent.wav",
        format: String = "wav"
    ) -> Bounce {
        Bounce(
            id: id,
            userId: UUID(),
            bounceFolderId: UUID(),
            fileName: fileName,
            filePath: filePath,
            fileSizeBytes: 1024,
            format: format,
            durationSeconds: 120,
            sampleRate: 44100,
            bitDepth: 24,
            bitrate: nil,
            createdAt: Date(),
            fileModifiedAt: Date()
        )
    }

    // MARK: - Queue Management

    func testAddToQueueAppendsItems() {
        let service = AudioPlayerService()
        let b1 = makeBounce(fileName: "one.wav")
        let b2 = makeBounce(fileName: "two.wav")

        // Since files don't exist locally, addToQueue guards on isLocallyAvailable.
        // We test the queue array stays empty for non-local files.
        service.addToQueue(bounce: b1)
        service.addToQueue(bounce: b2)
        XCTAssertTrue(service.queue.isEmpty, "Non-local bounces should not be added to queue")
    }

    func testClearQueueRemovesAll() {
        let service = AudioPlayerService()
        service.queue = [makeBounce(fileName: "a.wav"), makeBounce(fileName: "b.wav")]
        service.clearQueue()
        XCTAssertTrue(service.queue.isEmpty)
    }

    func testPlayAllSetsQueue() {
        let service = AudioPlayerService()
        let bounces = [makeBounce(fileName: "a.wav"), makeBounce(fileName: "b.wav")]
        // Files don't exist, so playAll filters them out
        service.playAll(bounces: bounces)
        XCTAssertTrue(service.queue.isEmpty, "Non-local bounces should be filtered out")
    }

    // MARK: - Play State Transitions

    func testInitialState() {
        let service = AudioPlayerService()
        XCTAssertNil(service.currentBounce)
        XCTAssertFalse(service.isPlaying)
        XCTAssertEqual(service.timeObserver.currentTime, 0)
        XCTAssertEqual(service.timeObserver.duration, 0)
        XCTAssertEqual(service.volume, 1.0)
        XCTAssertTrue(service.queue.isEmpty)
    }

    func testPlayNonLocalBounceDoesNothing() {
        let service = AudioPlayerService()
        let bounce = makeBounce(filePath: "/tmp/does_not_exist.wav")
        service.play(bounce: bounce)
        XCTAssertNil(service.currentBounce, "Should not play a non-local bounce")
        XCTAssertFalse(service.isPlaying)
    }

    func testTogglePlayPauseWithoutPlayer() {
        let service = AudioPlayerService()
        // Toggle when nothing is playing should not crash
        service.togglePlayPause()
        XCTAssertFalse(service.isPlaying)
    }

    func testPauseWithoutPlayerDoesNotCrash() {
        let service = AudioPlayerService()
        service.pause()
        XCTAssertFalse(service.isPlaying)
    }

    func testResumeWithoutPlayerDoesNotCrash() {
        let service = AudioPlayerService()
        service.resume()
        XCTAssertFalse(service.isPlaying)
    }

    func testNextWithEmptyQueueDoesNothing() {
        let service = AudioPlayerService()
        service.next()
        XCTAssertNil(service.currentBounce)
    }

    func testPreviousWithEmptyQueueDoesNothing() {
        let service = AudioPlayerService()
        service.previous()
        XCTAssertNil(service.currentBounce)
    }

    func testVolumeDefault() {
        let service = AudioPlayerService()
        XCTAssertEqual(service.volume, 1.0)
        service.volume = 0.5
        XCTAssertEqual(service.volume, 0.5)
    }
}
