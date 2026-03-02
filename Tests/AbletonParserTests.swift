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

    /// Rich fixture with multiple plugin formats, sample rate, key, and time signature.
    private let richFixtureXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Ableton MinorVersion="12.0.1">
        <LiveSet>
            <MasterTrack>
                <SampleRate>
                    <Value Value="96000" />
                </SampleRate>
            </MasterTrack>
            <Transport>
                <Tempo>
                    <Manual Value="128" />
                </Tempo>
            </Transport>
            <GlobalQuantisation>
                <RemoteableTimeSignature>
                    <Numerator Value="3" />
                    <Denominator Value="4" />
                </RemoteableTimeSignature>
            </GlobalQuantisation>
            <ScaleInformation>
                <Root Value="5" />
                <Name Value="Minor" />
            </ScaleInformation>
            <Tracks>
                <MidiTrack Id="1">
                    <Name>
                        <EffectiveName Value="Synth" />
                    </Name>
                    <DeviceChain>
                        <DeviceChain>
                            <Devices>
                                <PluginDevice Id="10">
                                    <On>
                                        <Value Value="true" />
                                    </On>
                                    <PluginDesc>
                                        <Vst3PluginInfo>
                                            <Name Value="Serum" />
                                        </Vst3PluginInfo>
                                    </PluginDesc>
                                    <UserName Value="Init Preset" />
                                </PluginDevice>
                                <Compressor Id="11">
                                    <On>
                                        <Value Value="true" />
                                    </On>
                                </Compressor>
                                <PluginDevice Id="12">
                                    <On>
                                        <Value Value="false" />
                                    </On>
                                    <PluginDesc>
                                        <AuPluginInfo>
                                            <Name Value="FabFilter Pro-Q 3" />
                                            <Manufacturer Value="FbFl" />
                                            <SubType Value="PrQ3" />
                                        </AuPluginInfo>
                                    </PluginDesc>
                                </PluginDevice>
                            </Devices>
                        </DeviceChain>
                    </DeviceChain>
                </MidiTrack>
                <AudioTrack Id="2">
                    <Name>
                        <EffectiveName Value="Bass" />
                    </Name>
                    <DeviceChain>
                        <DeviceChain>
                            <Devices>
                                <PluginDevice Id="20">
                                    <On>
                                        <Value Value="true" />
                                    </On>
                                    <PluginDesc>
                                        <VstPluginInfo>
                                            <PlugName Value="Decapitator" />
                                        </VstPluginInfo>
                                    </PluginDesc>
                                </PluginDevice>
                                <Eq8 Id="21">
                                    <On>
                                        <Value Value="true" />
                                    </On>
                                </Eq8>
                            </Devices>
                        </DeviceChain>
                    </DeviceChain>
                </AudioTrack>
            </Tracks>
        </LiveSet>
    </Ableton>
    """

    // MARK: - Basic Tests

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

    // MARK: - Plugin Format Identification Tests

    func testVST3PluginFormat() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)

            let synthTrack = project?.tracks.first { $0.name == "Synth" }
            XCTAssertNotNil(synthTrack)

            let serumInfo = synthTrack?.pluginInfos?.first { $0.name == "Serum" }
            XCTAssertNotNil(serumInfo)
            XCTAssertEqual(serumInfo?.format, "VST3")
        }
    }

    func testAUPluginFormat() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)

            let synthTrack = project?.tracks.first { $0.name == "Synth" }
            let proQInfo = synthTrack?.pluginInfos?.first { $0.name == "FabFilter Pro-Q 3" }
            XCTAssertNotNil(proQInfo)
            XCTAssertEqual(proQInfo?.format, "AU")
        }
    }

    func testVST2PluginFormat() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)

            let bassTrack = project?.tracks.first { $0.name == "Bass" }
            let decapInfo = bassTrack?.pluginInfos?.first { $0.name == "Decapitator" }
            XCTAssertNotNil(decapInfo)
            XCTAssertEqual(decapInfo?.format, "VST2")
        }
    }

    // MARK: - Preset Name Tests

    func testPresetNameExtraction() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            let synthTrack = project?.tracks.first { $0.name == "Synth" }
            let serumInfo = synthTrack?.pluginInfos?.first { $0.name == "Serum" }
            XCTAssertEqual(serumInfo?.presetName, "Init Preset")
        }
    }

    // MARK: - AU Manufacturer/SubType Tests

    func testAUManufacturerExtraction() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            let synthTrack = project?.tracks.first { $0.name == "Synth" }
            let proQInfo = synthTrack?.pluginInfos?.first { $0.name == "FabFilter Pro-Q 3" }
            XCTAssertEqual(proQInfo?.manufacturer, "FbFl")
            XCTAssertEqual(proQInfo?.auSubtype, "PrQ3")
        }
    }

    // MARK: - Sample Rate Tests

    func testSampleRateExtraction() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertEqual(project?.sampleRate, 96000)
        }
    }

    func testSampleRateNilWhenMissing() throws {
        try withAbletonFixture(xml: minimalAbletonXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertNil(project?.sampleRate)
        }
    }

    func testSampleRateBoundsCheck() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton MinorVersion="12.0">
            <LiveSet>
                <MasterTrack>
                    <SampleRate>
                        <Value Value="500000" />
                    </SampleRate>
                </MasterTrack>
                <Transport><Tempo><Manual Value="120" /></Tempo></Transport>
                <Tracks/>
            </LiveSet>
        </Ableton>
        """

        try withAbletonFixture(xml: xml) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNil(project?.sampleRate) // 500000 is out of bounds
        }
    }

    // MARK: - Backward Compatibility Tests

    func testBackwardCompat_PluginsMatchPluginInfoNames() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)

            for track in project!.tracks {
                if let infos = track.pluginInfos {
                    let infoNames = Set(infos.map(\.name))
                    let pluginNames = Set(track.plugins)
                    XCTAssertEqual(pluginNames, infoNames,
                        "track.plugins should match track.pluginInfos.map(\\.name) for track '\(track.name)'")
                }
            }
        }
    }

    // MARK: - Device Chain Tests

    func testDeviceChainOrdering() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)

            // Check that every track with plugins has a device chain
            for track in project!.tracks {
                if let chain = track.deviceChain {
                    // Verify indices are sequential
                    for (i, device) in chain.enumerated() {
                        XCTAssertEqual(device.index, i, "Device index mismatch on track '\(track.name)'")
                    }
                }
            }

            // Bass track has 2 devices: Decapitator (PluginDevice) + Eq8 (native)
            let bassTrack = project?.tracks.first { $0.name == "Bass" }
            let bassChain = bassTrack?.deviceChain
            XCTAssertNotNil(bassChain)
            XCTAssertEqual(bassChain?.count, 2)
            XCTAssertEqual(bassChain?[0].name, "Decapitator")
            XCTAssertEqual(bassChain?[1].name, "Eq8")
        }
    }

    func testDeviceChainNativeVsThirdParty() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            let bassTrack = project?.tracks.first { $0.name == "Bass" }
            let chain = bassTrack?.deviceChain

            // Decapitator = thirdParty
            if case .thirdParty(let info) = chain?[0].deviceType {
                XCTAssertEqual(info.name, "Decapitator")
                XCTAssertEqual(info.format, "VST2")
            } else {
                XCTFail("Expected Decapitator to be thirdParty")
            }

            // Eq8 = native
            if case .native = chain?[1].deviceType {
                // pass
            } else {
                XCTFail("Expected Eq8 to be native")
            }
        }
    }

    func testDeviceChainEnabledState() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            let bassTrack = project?.tracks.first { $0.name == "Bass" }
            let chain = bassTrack?.deviceChain

            XCTAssertEqual(chain?[0].isEnabled, true)  // Decapitator: true
            XCTAssertEqual(chain?[1].isEnabled, true)  // Eq8: true
        }
    }

    func testDeviceChainContainsAllTracksDevices() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            let synthTrack = project?.tracks.first { $0.name == "Synth" }
            let chain = synthTrack?.deviceChain
            XCTAssertNotNil(chain)

            // Synth track should have Serum + Compressor + FabFilter Pro-Q 3
            let names = chain?.map(\.name) ?? []
            XCTAssertTrue(names.contains("Serum"), "Missing Serum in chain: \(names)")
            XCTAssertTrue(names.contains("Compressor"), "Missing Compressor in chain: \(names)")
        }
    }

    // MARK: - Key/Scale/Time Signature in Rich Fixture

    func testRichFixtureKeyAndScale() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertEqual(project?.keyRoot, "F")  // MIDI note 5 = F
            XCTAssertEqual(project?.keyScale, "min")
        }
    }

    func testRichFixtureTimeSignature() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertEqual(project?.timeSignature, "3/4")
        }
    }

    // MARK: - Sample Path Extraction Tests

    func testExtractsSamplePathsFromSessionViewClips() throws {
        // The minimalAbletonXML has a session-view clip with a FileRef
        try withAbletonFixture(xml: minimalAbletonXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertFalse(project!.samplePaths.isEmpty, "samplePaths should not be empty")
            XCTAssertTrue(project!.samplePaths.contains("Samples/kick.wav"),
                "samplePaths should contain 'Samples/kick.wav', got: \(project!.samplePaths)")
        }
    }

    func testExtractsSamplePathsFromInstrumentFileRef() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton MinorVersion="11.3.2">
            <LiveSet>
                <Transport><Tempo><Manual Value="120" /></Tempo></Transport>
                <Tracks>
                    <MidiTrack Id="1">
                        <Name><EffectiveName Value="Sampler" /></Name>
                        <DeviceChain>
                            <DeviceChain>
                                <Devices>
                                    <OriginalSimpler Id="1">
                                        <Player>
                                            <MultiSampleMap>
                                                <SampleParts>
                                                    <MultiSamplePart Id="0">
                                                        <SampleRef>
                                                            <FileRef>
                                                                <Path Value="/Users/test/Library/Samples/piano.aif" />
                                                                <RelativePath Value="../../Library/Samples/piano.aif" />
                                                            </FileRef>
                                                        </SampleRef>
                                                    </MultiSamplePart>
                                                </SampleParts>
                                            </MultiSampleMap>
                                        </Player>
                                    </OriginalSimpler>
                                </Devices>
                            </DeviceChain>
                        </DeviceChain>
                    </MidiTrack>
                </Tracks>
            </LiveSet>
        </Ableton>
        """

        try withAbletonFixture(xml: xml) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertTrue(project!.samplePaths.contains("/Users/test/Library/Samples/piano.aif"),
                "samplePaths should contain instrument sample, got: \(project!.samplePaths)")
        }
    }

    func testExtractsSamplePathsFromArrangementClips() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Ableton MinorVersion="11.3.2">
            <LiveSet>
                <Transport><Tempo><Manual Value="120" /></Tempo></Transport>
                <Tracks>
                    <AudioTrack Id="1">
                        <Name><EffectiveName Value="Audio" /></Name>
                        <DeviceChain>
                            <DeviceChain><Devices /></DeviceChain>
                            <MainSequencer>
                                <Sample>
                                    <ArrangerAutomation>
                                        <Events />
                                    </ArrangerAutomation>
                                </Sample>
                                <ClipTimeable>
                                    <ArrangerAutomation>
                                        <Events>
                                            <AudioClip Id="0">
                                                <Name Value="vocal" />
                                                <SampleRef>
                                                    <FileRef>
                                                        <Path Value="/Users/test/Samples/vocal.wav" />
                                                        <RelativePath Value="Samples/vocal.wav" />
                                                    </FileRef>
                                                </SampleRef>
                                            </AudioClip>
                                        </Events>
                                    </ArrangerAutomation>
                                </ClipTimeable>
                            </MainSequencer>
                        </DeviceChain>
                    </AudioTrack>
                </Tracks>
            </LiveSet>
        </Ableton>
        """

        try withAbletonFixture(xml: xml) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)
            XCTAssertTrue(project!.samplePaths.contains("/Users/test/Samples/vocal.wav"),
                "samplePaths should contain arrangement clip sample, got: \(project!.samplePaths)")
        }
    }

    func testSessionViewClipsAppearInTrackClips() throws {
        try withAbletonFixture(xml: minimalAbletonXML) { path in
            let project = AbletonParser.parse(path: path)
            let drumsTrack = project?.tracks.first { $0.name == "Drums" }
            XCTAssertNotNil(drumsTrack)
            let audioClips = drumsTrack?.clips.filter { $0.type == .audio }
            XCTAssertFalse(audioClips?.isEmpty ?? true, "Session-view audio clips should be extracted")
            XCTAssertEqual(audioClips?.first?.samplePath, "Samples/kick.wav")
        }
    }

    // MARK: - Aggregated Plugins Test

    func testUsedPluginsAggregatesAllTracks() throws {
        try withAbletonFixture(xml: richFixtureXML) { path in
            let project = AbletonParser.parse(path: path)
            XCTAssertNotNil(project)

            let plugins = project!.usedPlugins
            XCTAssertTrue(plugins.contains("Serum"))
            XCTAssertTrue(plugins.contains("FabFilter Pro-Q 3"))
            XCTAssertTrue(plugins.contains("Decapitator"))
        }
    }
}
