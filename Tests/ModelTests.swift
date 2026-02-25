import XCTest
@testable import AudioEnv

// MARK: - AudioPlugin Codable

final class AudioPluginCodableTests: XCTestCase {

    func testRoundTripPreservesAllFields() throws {
        let plugin = AudioPlugin(
            name: "Pro-Q 3",
            path: "/Library/Audio/Plug-Ins/VST3/Pro-Q 3.vst3",
            format: .vst3,
            bundleID: "com.fabfilter.Pro-Q.3",
            version: "3.21",
            manufacturer: "FabFilter",
            auManufacturerCode: "FabF"
        )

        let data = try JSONEncoder().encode(plugin)
        let decoded = try JSONDecoder().decode(AudioPlugin.self, from: data)

        XCTAssertEqual(decoded.name, "Pro-Q 3")
        XCTAssertEqual(decoded.path, plugin.path)
        XCTAssertEqual(decoded.format, .vst3)
        XCTAssertEqual(decoded.bundleID, "com.fabfilter.Pro-Q.3")
        XCTAssertEqual(decoded.version, "3.21")
        XCTAssertEqual(decoded.manufacturer, "FabFilter")
        XCTAssertEqual(decoded.auManufacturerCode, "FabF")
    }

    func testNilOptionalFields() throws {
        let plugin = AudioPlugin(name: "Serum", path: "/tmp/Serum.vst", format: .vst)

        let data = try JSONEncoder().encode(plugin)
        let decoded = try JSONDecoder().decode(AudioPlugin.self, from: data)

        XCTAssertEqual(decoded.name, "Serum")
        XCTAssertNil(decoded.bundleID)
        XCTAssertNil(decoded.version)
        XCTAssertNil(decoded.manufacturer)
        XCTAssertNil(decoded.auManufacturerCode)
    }

    func testAllFormatsEncodeDecode() throws {
        for format in PluginFormat.allCases {
            let plugin = AudioPlugin(name: "Test", path: "/tmp/test", format: format)
            let data = try JSONEncoder().encode(plugin)
            let decoded = try JSONDecoder().decode(AudioPlugin.self, from: data)
            XCTAssertEqual(decoded.format, format)
        }
    }
}

// MARK: - AudioSession Codable

final class AudioSessionCodableTests: XCTestCase {

    private let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }()

    func testRoundTrip() throws {
        let session = AudioSession(
            name: "My Song", path: "/Users/test/Music/My Song.als",
            format: .ableton, modifiedDate: Date(timeIntervalSince1970: 1700000000),
            fileSize: 1_048_576
        )

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(AudioSession.self, from: data)

        XCTAssertEqual(decoded.name, "My Song")
        XCTAssertEqual(decoded.format, .ableton)
        XCTAssertEqual(decoded.fileSize, 1_048_576)
        XCTAssertNil(decoded.project)
    }

    func testWithAbletonProject() throws {
        let project = AbletonProject(
            version: "11.3.2", tempo: 128.0, tracks: [],
            usedPlugins: ["Serum", "Pro-Q 3"], samplePaths: [],
            projectSampleFiles: [], bouncedFiles: [], projectRootPath: "/tmp",
            timeSignature: nil, keyRoot: nil, keyScale: nil, sampleRate: nil
        )
        let session = AudioSession(
            name: "Test", path: "/tmp/test.als", format: .ableton,
            modifiedDate: Date(timeIntervalSince1970: 1700000000),
            fileSize: 500_000, project: .ableton(project)
        )

        let data = try encoder.encode(session)
        let decoded = try decoder.decode(AudioSession.self, from: data)

        if case .ableton(let p) = decoded.project {
            XCTAssertEqual(p.tempo, 128.0)
            XCTAssertEqual(p.usedPlugins, ["Serum", "Pro-Q 3"])
        } else {
            XCTFail("Expected Ableton project")
        }
    }

    func testAllFormats() throws {
        for format in SessionFormat.allCases {
            let session = AudioSession(
                name: "Test", path: "/tmp/test", format: format,
                modifiedDate: Date(), fileSize: 100
            )
            let data = try encoder.encode(session)
            let decoded = try decoder.decode(AudioSession.self, from: data)
            XCTAssertEqual(decoded.format, format)
        }
    }

    func testAbletonBackupDetection() {
        let backup1 = AudioSession(name: "Song [auto-save]", path: "/Music/Project/Song [auto-save].als", format: .ableton, modifiedDate: Date(), fileSize: 100)
        let backup2 = AudioSession(name: "Song", path: "/Music/Project/Backups/Song.als", format: .ableton, modifiedDate: Date(), fileSize: 100)
        let primary = AudioSession(name: "Song", path: "/Music/Project/Song.als", format: .ableton, modifiedDate: Date(), fileSize: 100)

        XCTAssertTrue(backup1.isBackup)
        XCTAssertTrue(backup2.isBackup)
        XCTAssertFalse(primary.isBackup)
    }

    func testProToolsBackupDetection() {
        let backup = AudioSession(name: "Session", path: "/Music/Session File Backups/Session.ptx", format: .proTools, modifiedDate: Date(), fileSize: 100)
        let bakFile = AudioSession(name: "Session.bak.001", path: "/Music/Session.bak.001.ptx", format: .proTools, modifiedDate: Date(), fileSize: 100)
        let primary = AudioSession(name: "Session", path: "/Music/Session.ptx", format: .proTools, modifiedDate: Date(), fileSize: 100)

        XCTAssertTrue(backup.isBackup)
        XCTAssertTrue(bakFile.isBackup)
        XCTAssertFalse(primary.isBackup)
    }
}

// MARK: - BackupManifest Codable

final class BackupManifestCodableTests: XCTestCase {

    func testRoundTrip() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let manifest = BackupManifest(
            backupId: "2026-02-14T120000Z-ABCD1234",
            userId: "user-123", backupName: "Full Backup",
            scopeDescription: "All plugins and projects",
            createdAt: Date(timeIntervalSince1970: 1700000000),
            pluginCount: 5, projectCount: 3, sessionCount: 10,
            totalSizeBytes: 1_073_741_824, appVersion: "1.0",
            plugins: [
                PluginBackupItem(
                    name: "Pro-Q 3", format: "VST3",
                    originalPath: "/Library/Audio/Plug-Ins/VST3/Pro-Q 3.vst3",
                    s3Key: "users/123/backups/abc/plugins/sha256.zip",
                    bundleId: "com.fabfilter.Pro-Q.3",
                    version: "3.21", manufacturer: "FabFilter",
                    checksum: "abc123def456"
                )
            ],
            projects: []
        )

        let data = try encoder.encode(manifest)
        let decoded = try decoder.decode(BackupManifest.self, from: data)

        XCTAssertEqual(decoded.backupId, manifest.backupId)
        XCTAssertEqual(decoded.userId, "user-123")
        XCTAssertEqual(decoded.pluginCount, 5)
        XCTAssertEqual(decoded.totalSizeBytes, 1_073_741_824)
        XCTAssertEqual(decoded.plugins.count, 1)
        XCTAssertEqual(decoded.plugins[0].checksum, "abc123def456")
    }
}

// MARK: - ScanCache

final class ScanCacheCodableTests: XCTestCase {

    func testRoundTrip() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let cache = ScanCacheStore.makeCache(
            plugins: [AudioPlugin(name: "Serum", path: "/tmp/Serum.vst3", format: .vst3)],
            sessions: [AudioSession(name: "Test", path: "/tmp/test.als", format: .ableton, modifiedDate: Date(timeIntervalSince1970: 1700000000), fileSize: 100)],
            lastScanDate: Date(timeIntervalSince1970: 1700000000),
            skippedLargeSessions: 2,
            scanRoots: ["/Users/test/Music"],
            rootModTimes: ["/Users/test/Music": Date(timeIntervalSince1970: 1700000000)],
            pluginDirModTimes: [:]
        )

        let data = try encoder.encode(cache)
        let decoded = try decoder.decode(ScanCache.self, from: data)

        XCTAssertEqual(decoded.version, 6)
        XCTAssertEqual(decoded.plugins.count, 1)
        XCTAssertEqual(decoded.sessions.count, 1)
        XCTAssertEqual(decoded.skippedLargeSessions, 2)
        XCTAssertEqual(decoded.scanRoots, ["/Users/test/Music"])
    }

    func testVersionMismatch() throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let cache = ScanCache(
            version: 999, createdAt: Date(), lastScanDate: nil,
            skippedLargeSessions: 0, scanRoots: [], rootModTimes: [:],
            pluginDirModTimes: [:],
            plugins: [], sessions: []
        )

        let data = try encoder.encode(cache)
        let decoded = try decoder.decode(ScanCache.self, from: data)
        XCTAssertEqual(decoded.version, 999)
    }
}
