import XCTest
@testable import AudioEnv

final class AbletonParserTests: XCTestCase {

    // MARK: - Helpers

    /// Create a minimal Ableton .als file (gzip-compressed XML) and run the test body.
    private func withAbletonFixture(xml: String, _ body: (String) throws -> Void) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let xmlFile = dir.appendingPathComponent("test.xml")
        try xml.data(using: .utf8)!.write(to: xmlFile)

        // Gzip the XML to create an .als file
        let alsFile = dir.appendingPathComponent("test.als")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", xmlFile.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let gzipData = pipe.fileHandleForReading.readDataToEndOfFile()
        try gzipData.write(to: alsFile)

        defer { try? fm.removeItem(at: dir) }
        try body(alsFile.path)
    }

    // Minimal Ableton Live Set XML with tempo and one audio track
    private let minimalAbletonXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Ableton MinorVersion="11.3.2">
        <LiveSet>
            <MasterTrack>
                <AutomationEnvelopes>
                    <Envelopes>
                        <AutomationEnvelope Id="0">
                            <EnvelopeTarget>
                                <PointeeId Value="4" />
                            </EnvelopeTarget>
                        </AutomationEnvelope>
                    </Envelopes>
                </AutomationEnvelopes>
            </MasterTrack>
            <Transport>
                <Tempo>
                    <Manual Value="140" />
                </Tempo>
            </Transport>
            <Tracks>
                <AudioTrack Id="1">
                    <Name>
                        <EffectiveName Value="Drums" />
                    </Name>
                    <DeviceChain>
                        <DeviceChain>
                            <Devices>
                                <PluginDevice Id="1">
                                    <PluginDesc>
                                        <VstPluginInfo>
                                            <PlugName Value="Pro-Q 3" />
                                        </VstPluginInfo>
                                    </PluginDesc>
                                </PluginDevice>
                            </Devices>
                        </DeviceChain>
                        <MainSequencer>
                            <ClipSlotList>
                                <ClipSlot Id="0">
                                    <Value>
                                        <AudioClip Id="0">
                                            <Name Value="kick" />
                                            <CurrentStart Value="0" />
                                            <CurrentEnd Value="4" />
                                            <SampleRef>
                                                <FileRef>
                                                    <Path Value="Samples/kick.wav" />
                                                    <RelativePath Value="Samples/kick.wav" />
                                                </FileRef>
                                            </SampleRef>
                                        </AudioClip>
                                    </Value>
                                </ClipSlot>
                            </ClipSlotList>
                        </MainSequencer>
                    </DeviceChain>
                    <TrackGroupId Value="-1" />
                    <DevicesListWrapper LomId="0" />
                </AudioTrack>
            </Tracks>
        </LiveSet>
    </Ableton>
    """

    // MARK: - Tests

    func testParsesTempo() throws {
        try withAbletonFixture(xml: minimalAbletonXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertEqual(project?.tempo, 140.0)
        }
    }

    func testExtractsVersion() throws {
        try withAbletonFixture(xml: minimalAbletonXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertEqual(project?.version, "11.3.2")
        }
    }

    func testExtractsTracks() throws {
        try withAbletonFixture(xml: minimalAbletonXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertGreaterThanOrEqual(project?.tracks.count ?? 0, 1)
        }
    }

    func testExtractsPlugins() throws {
        try withAbletonFixture(xml: minimalAbletonXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertTrue(project?.usedPlugins.contains("Pro-Q 3") == true)
        }
    }

    func testReturnsNilForNonExistentPath() {
        XCTAssertNil(AbletonParser.parse(path: "/nonexistent/song.als"))
    }

    func testReturnsNilForMalformedGzip() throws {
        let fm = FileManager.default
        let path = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".als")
        try "This is not gzip data".data(using: .utf8)!.write(to: path)
        defer { try? fm.removeItem(at: path) }

        XCTAssertNil(AbletonParser.parse(path: path.path))
    }

    func testValidGzipInvalidXML() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let textFile = dir.appendingPathComponent("bad.txt")
        try "not xml at all <broken>".data(using: .utf8)!.write(to: textFile)

        let alsFile = dir.appendingPathComponent("bad.als")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c", textFile.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        try pipe.fileHandleForReading.readDataToEndOfFile().write(to: alsFile)

        defer { try? fm.removeItem(at: dir) }

        let project = AbletonParser.parse(path: alsFile.path)
        // Parser may return nil or a project with defaults depending on XML handling
        // The key is it doesn't crash
        if let project = project {
            XCTAssertGreaterThanOrEqual(project.tempo, 0)
        }
    }

    func testEmptyXML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton MinorVersion="11.0">
            <LiveSet>
                <Transport>
                    <Tempo>
                        <Manual Value="120" />
                    </Tempo>
                </Transport>
                <Tracks/>
            </LiveSet>
        </Ableton>
        """

        try withAbletonFixture(xml: xml) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertEqual(project?.tempo, 120.0)
            XCTAssertEqual(project?.tracks.isEmpty, true)
            XCTAssertEqual(project?.usedPlugins.isEmpty, true)
        }
    }
}
