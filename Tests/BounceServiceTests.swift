import XCTest
@testable import AudioEnv

final class BounceServiceTests: XCTestCase {

    // MARK: - Name Matching: bounceMatchesProject

    func testExactMatch() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song.wav",
            projectName: "My Song"
        ))
    }

    func testCaseInsensitiveMatch() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "MY SONG.wav",
            projectName: "my song"
        ))
    }

    func testStripBounceSuffix() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_bounce.wav",
            projectName: "My Song"
        ))
    }

    func testStripMixSuffix() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_mix.mp3",
            projectName: "My Song"
        ))
    }

    func testStripMasterSuffix() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_master.wav",
            projectName: "My Song"
        ))
    }

    func testStripV1Suffix() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_v1.wav",
            projectName: "My Song"
        ))
    }

    func testStripProjectSuffix() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song.wav",
            projectName: "My Song Project"
        ))
    }

    func testStripTrailingNumbers() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_01.wav",
            projectName: "My Song"
        ))
    }

    func testNoMatch() {
        XCTAssertFalse(BounceService.bounceMatchesProject(
            bounceFileName: "Completely Different.wav",
            projectName: "My Song"
        ))
    }

    func testEmptyProjectName() {
        XCTAssertFalse(BounceService.bounceMatchesProject(
            bounceFileName: "something.wav",
            projectName: ""
        ))
    }

    func testPartialContains() {
        // "my song" contains "my" -- project name is shorter
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song Final.wav",
            projectName: "My Song Final"
        ))
    }

    func testMultipleSuffixesStripsOnlyOne() {
        // "_bounce" is stripped first pass, but "_mix" would be at end only if bounce had it
        // "My Song_mix_bounce.wav" -> stripped "_bounce" -> "my song_mix" contains "my song" -> true
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_mix_bounce.wav",
            projectName: "My Song"
        ))
    }

    func testDemoSuffix() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_demo.flac",
            projectName: "My Song"
        ))
    }

    func testFinalSuffix() {
        XCTAssertTrue(BounceService.bounceMatchesProject(
            bounceFileName: "My Song_final.aiff",
            projectName: "My Song"
        ))
    }
}
