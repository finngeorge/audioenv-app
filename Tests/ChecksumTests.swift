import XCTest
import CryptoKit
@testable import AudioEnv

@MainActor
final class ChecksumTests: XCTestCase {

    // MARK: - Helpers

    private func withTempFile(content: Data, _ body: (String) throws -> Void) throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        try content.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try body(file.path)
    }

    private func withTempBundle(binaryContent: Data, _ body: (String) throws -> Void) throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".vst3")
        let macosDir = bundle.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macosDir, withIntermediateDirectories: true)
        try binaryContent.write(to: macosDir.appendingPathComponent("TestPlugin"))
        try "<?xml version=\"1.0\"?><plist><dict/></plist>".data(using: .utf8)!
            .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        defer { try? FileManager.default.removeItem(at: bundle) }
        try body(bundle.path)
    }

    // MARK: - Tests

    func testKnownFileProducesExpectedHash() throws {
        let content = "Hello, AudioEnv!".data(using: .utf8)!
        let expected = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()

        try withTempFile(content: content) { path in
            XCTAssertEqual(BackupService.sha256Checksum(forPluginAt: path), expected)
        }
    }

    func testBundleHashesExecutableBinary() throws {
        let binary = Data([0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xDD])
        let expected = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()

        try withTempBundle(binaryContent: binary) { path in
            XCTAssertEqual(BackupService.sha256Checksum(forPluginAt: path), expected)
        }
    }

    func testReturnsNilForNonExistentPath() {
        XCTAssertNil(BackupService.sha256Checksum(forPluginAt: "/nonexistent/path.vst3"))
    }

    func testDeterministic() throws {
        let content = Data(repeating: 0x42, count: 1024)
        try withTempFile(content: content) { path1 in
            try withTempFile(content: content) { path2 in
                let hash1 = BackupService.sha256Checksum(forPluginAt: path1)
                let hash2 = BackupService.sha256Checksum(forPluginAt: path2)
                XCTAssertNotNil(hash1)
                XCTAssertEqual(hash1, hash2)
            }
        }
    }

    func testDifferentContentDifferentHash() throws {
        try withTempFile(content: "version 1.0".data(using: .utf8)!) { path1 in
            try withTempFile(content: "version 2.0".data(using: .utf8)!) { path2 in
                XCTAssertNotEqual(
                    BackupService.sha256Checksum(forPluginAt: path1),
                    BackupService.sha256Checksum(forPluginAt: path2)
                )
            }
        }
    }

    func testEmptyFileProducesValidHash() throws {
        try withTempFile(content: Data()) { path in
            let checksum = BackupService.sha256Checksum(forPluginAt: path)
            XCTAssertNotNil(checksum)
            XCTAssertEqual(checksum!.count, 64)
        }
    }

    func testBundleWithoutMacOSDirFallsToPlist() throws {
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".component")
        let contentsDir = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsDir, withIntermediateDirectories: true)

        let plistContent = "<?xml version=\"1.0\"?><plist><dict><key>test</key><string>value</string></dict></plist>"
        try plistContent.data(using: .utf8)!.write(to: contentsDir.appendingPathComponent("Info.plist"))
        defer { try? FileManager.default.removeItem(at: bundle) }

        let checksum = BackupService.sha256Checksum(forPluginAt: bundle.path)
        XCTAssertNotNil(checksum)

        let expected = SHA256.hash(data: plistContent.data(using: .utf8)!).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(checksum, expected)
    }
}
