import XCTest
@testable import AudioEnv

final class LogicParserTests: XCTestCase {

    // MARK: - Helpers

    private func withLogicBundle(metadata: [String: Any], body: (String) throws -> Void) throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".logicx")
        let altDir = bundle.appendingPathComponent("Alternatives/000")
        try fm.createDirectory(at: altDir, withIntermediateDirectories: true)

        let plistData = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try plistData.write(to: altDir.appendingPathComponent("MetaData.plist"))

        defer { try? fm.removeItem(at: bundle) }
        try body(bundle.path)
    }

    private func withLogicBundleAndProjectInfo(
        metadata: [String: Any] = [:],
        projectInfo: [String: Any],
        body: (String) throws -> Void
    ) throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".logicx")
        let altDir = bundle.appendingPathComponent("Alternatives/000")
        let resDir = bundle.appendingPathComponent("Resources")
        try fm.createDirectory(at: altDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: resDir, withIntermediateDirectories: true)

        if !metadata.isEmpty {
            let metaData = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
            try metaData.write(to: altDir.appendingPathComponent("MetaData.plist"))
        }

        let projData = try PropertyListSerialization.data(fromPropertyList: projectInfo, format: .xml, options: 0)
        try projData.write(to: resDir.appendingPathComponent("ProjectInformation.plist"))

        defer { try? fm.removeItem(at: bundle) }
        try body(bundle.path)
    }

    // MARK: - Tests

    func testExtractsBPM() throws {
        try withLogicBundle(metadata: ["BeatsPerMinute": 140]) { path in
            let project = LogicParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertEqual(project?.tempo, 140.0)
        }
    }

    func testExtractsSampleRate() throws {
        try withLogicBundle(metadata: ["SampleRate": 48000]) { path in
            XCTAssertEqual(LogicParser.parse(path: path)?.sampleRate, 48000)
        }
    }

    func testExtractsTrackCount() throws {
        try withLogicBundle(metadata: ["NumberOfTracks": 24]) { path in
            XCTAssertEqual(LogicParser.parse(path: path)?.trackCount, 24)
        }
    }

    func testExtractsKeyAndScale() throws {
        try withLogicBundle(metadata: ["SongKey": "F#", "SongGenderKey": "minor"]) { path in
            let project = LogicParser.parse(path: path)
            XCTAssertEqual(project?.songKey, "F#")
            XCTAssertEqual(project?.songScale, "minor")
        }
    }

    func testDefaultKeyFiltered() throws {
        try withLogicBundle(metadata: ["SongKey": "C", "SongGenderKey": "major"]) { path in
            let project = LogicParser.parse(path: path)
            XCTAssertNil(project?.songKey)
            XCTAssertNil(project?.songScale)
        }
    }

    func testDefaultTimeSigFiltered() throws {
        try withLogicBundle(metadata: ["SongSignatureNumerator": 4, "SongSignatureDenominator": 4]) { path in
            let project = LogicParser.parse(path: path)
            XCTAssertNil(project?.timeSignatureNumerator)
            XCTAssertNil(project?.timeSignatureDenominator)
        }
    }

    func testNonDefaultTimeSig() throws {
        try withLogicBundle(metadata: ["SongSignatureNumerator": 6, "SongSignatureDenominator": 8]) { path in
            let project = LogicParser.parse(path: path)
            XCTAssertEqual(project?.timeSignatureNumerator, 6)
            XCTAssertEqual(project?.timeSignatureDenominator, 8)
        }
    }

    func testExtractsLogicVersion() throws {
        try withLogicBundleAndProjectInfo(
            metadata: ["BeatsPerMinute": 120],
            projectInfo: ["LastSavedFrom": "Logic Pro X 11.0.0 (6011)"]
        ) { path in
            XCTAssertEqual(LogicParser.parse(path: path)?.logicVersion, "Logic Pro X 11.0.0 (6011)")
        }
    }

    func testReturnsNilForNonExistentPath() {
        XCTAssertNil(LogicParser.parse(path: "/nonexistent/path.logicx"))
    }

    func testEmptyPlist() throws {
        try withLogicBundle(metadata: [:]) { path in
            let project = LogicParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertNil(project?.tempo)
            XCTAssertNil(project?.sampleRate)
            XCTAssertNil(project?.trackCount)
        }
    }

    func testProjectNameFromBundleFilename() throws {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory.appendingPathComponent("My Cool Song.logicx")
        let altDir = bundle.appendingPathComponent("Alternatives/000")
        try fm.createDirectory(at: altDir, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(fromPropertyList: [:] as [String: Any], format: .xml, options: 0)
        try plistData.write(to: altDir.appendingPathComponent("MetaData.plist"))
        defer { try? fm.removeItem(at: bundle) }

        XCTAssertEqual(LogicParser.parse(path: bundle.path)?.name, "My Cool Song")
    }

    func testAUPluginBinaryScanning() {
        var bytes = Data(repeating: 0x00, count: 100)
        bytes.replaceSubrange(20..<24, with: "aufx".data(using: .ascii)!)
        bytes.replaceSubrange(24..<28, with: "EQxx".data(using: .ascii)!)
        bytes.replaceSubrange(28..<32, with: "Appl".data(using: .ascii)!)

        let hints = LogicParser.scanBinaryForAUPlugins(bytes)
        XCTAssertTrue(hints.contains("aufx:EQxx:Appl"))
    }

    func testAUPluginScanningIgnoresGarbage() {
        let bytes = Data(repeating: 0x00, count: 100)
        XCTAssertTrue(LogicParser.scanBinaryForAUPlugins(bytes).isEmpty)
    }

    func testHasARAPlugins() throws {
        try withLogicBundle(metadata: ["HasARAPlugins": 1]) { path in
            XCTAssertEqual(LogicParser.parse(path: path)?.hasARAPlugins, true)
        }
    }

    func testAssetFileArrays() throws {
        try withLogicBundle(metadata: [
            "AudioFiles": ["/path/to/kick.wav", "/path/to/snare.wav"],
            "SamplerInstrumentsFiles": ["/path/to/piano.exs"],
            "AlchemyFiles": ["/path/to/pad.alc"]
        ]) { path in
            let project = LogicParser.parse(path: path)
            XCTAssertEqual(project?.samplerInstrumentFiles, ["piano.exs"])
            XCTAssertEqual(project?.alchemyFiles, ["pad.alc"])
        }
    }
}
