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

    // MARK: - DAW media exclusions

    func testDAWMediaFoldersAreExcluded() {
        let excluded = [
            "/Users/me/Music/Pro Tools/Teddy 435/Audio Files",
            "/Users/me/Music/Pro Tools/Teddy 435/Rendered Files",
            "/Users/me/Music/Pro Tools/Teddy 435/Session File Backups",
            "/Users/me/Music/Ableton/candy bass Project/Samples/Recorded",
            "/Users/me/Music/Ableton/candy bass Project/Backup",
            "/Users/me/Music/Logic/Grandpa 1.2.logicx/Media/Audio Files",
            "/Users/me/Music/Logic/Grandpa 1.2.logicx",
            "/Users/me/Music/Logic/Tell It True/Audio Files",
            "/Users/me/Music/Logic/Tell It True/Freeze Files.nosync",
        ]
        for path in excluded {
            XCTAssertTrue(BounceService.isDAWMediaDirectory(path), path)
        }
    }

    func testBounceFoldersAreNotExcluded() {
        let kept = [
            "/Users/me/Music/Originals",
            "/Users/me/Music/Pro Tools/Teddy 435/Bounced Files",
            "/Users/me/Music/Pro Tools/Teddy 435",
            "/Users/me/Music/Ableton/candy bass Project",
            "/Users/me/Music/Logic/Bounces",
            "/Users/me/Music/Logic/Tell It True/Bounces",
            "/Volumes/Backup/Bounces",          // "Backup" outside an Ableton project
            "/Users/me/Samples/Bounce Library", // "Samples" outside an Ableton project
        ]
        for path in kept {
            XCTAssertFalse(BounceService.isDAWMediaDirectory(path), path)
        }
    }

    func testProToolsDuplicateFilesAreExcluded() {
        XCTAssertTrue(BounceService.isDAWGeneratedAudioFile("HAPPY DAYS .dup1_01.L.wav"))
        XCTAssertTrue(BounceService.isDAWGeneratedAudioFile("Vox.DUP2_03.wav"))
        XCTAssertFalse(BounceService.isDAWGeneratedAudioFile("Mix 1.L.wav"))      // split-mono bounce
        XCTAssertFalse(BounceService.isDAWGeneratedAudioFile("candy bass 1.1 [135].wav"))
    }
}
