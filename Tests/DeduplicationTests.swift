import XCTest
@testable import AudioEnv

final class DeduplicationTests: XCTestCase {

    private func makePlugin(name: String, path: String, format: PluginFormat, bundleID: String? = nil) -> AudioPlugin {
        AudioPlugin(name: name, path: path, format: format, bundleID: bundleID)
    }

    func testGroupsByBundleID() {
        let plugins = [
            makePlugin(name: "Pro-Q 3", path: "/au/Pro-Q 3.component", format: .audioUnit, bundleID: "com.fabfilter.Pro-Q.3"),
            makePlugin(name: "Pro-Q 3", path: "/vst3/Pro-Q 3.vst3", format: .vst3, bundleID: "com.fabfilter.Pro-Q.3"),
            makePlugin(name: "Pro-Q 3", path: "/vst/Pro-Q 3.vst", format: .vst, bundleID: "com.fabfilter.Pro-Q.3"),
            makePlugin(name: "Serum", path: "/vst3/Serum.vst3", format: .vst3, bundleID: "com.xferrecords.Serum"),
        ]

        let deduped = PluginDeduplicator.deduplicate(plugins)
        XCTAssertEqual(deduped.count, 2)
    }

    func testPreferredFormatOrdering() {
        let plugins = [
            makePlugin(name: "EQ", path: "/aax/EQ.aaxplugin", format: .aax, bundleID: "com.test.eq"),
            makePlugin(name: "EQ", path: "/vst/EQ.vst", format: .vst, bundleID: "com.test.eq"),
            makePlugin(name: "EQ", path: "/au/EQ.component", format: .audioUnit, bundleID: "com.test.eq"),
            makePlugin(name: "EQ", path: "/vst3/EQ.vst3", format: .vst3, bundleID: "com.test.eq"),
        ]

        let deduped = PluginDeduplicator.deduplicate(plugins)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].format, .vst3)
    }

    func testGroupsByNormalizedNameWhenNoBundleID() {
        let plugins = [
            makePlugin(name: "FabFilter Pro-Q 3", path: "/vst3/Pro-Q.vst3", format: .vst3),
            makePlugin(name: "FabFilter Pro-Q 3", path: "/au/Pro-Q.component", format: .audioUnit),
        ]

        let deduped = PluginDeduplicator.deduplicate(plugins)
        XCTAssertEqual(deduped.count, 1)
    }

    func testSinglePluginReturnsSelf() {
        let plugins = [
            makePlugin(name: "Synth", path: "/vst3/Synth.vst3", format: .vst3, bundleID: "com.test.synth"),
        ]

        let deduped = PluginDeduplicator.deduplicate(plugins)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped[0].name, "Synth")
    }

    func testEmptyInput() {
        let deduped = PluginDeduplicator.deduplicate([])
        XCTAssertTrue(deduped.isEmpty)
    }

    func testSavingsCalculation() {
        let original = [
            makePlugin(name: "EQ", path: "/vst3/EQ.vst3", format: .vst3, bundleID: "com.test.eq"),
            makePlugin(name: "EQ", path: "/au/EQ.component", format: .audioUnit, bundleID: "com.test.eq"),
            makePlugin(name: "EQ", path: "/vst/EQ.vst", format: .vst, bundleID: "com.test.eq"),
            makePlugin(name: "Synth", path: "/vst3/Synth.vst3", format: .vst3, bundleID: "com.test.synth"),
        ]
        let deduped = PluginDeduplicator.deduplicate(original)
        let stats = PluginDeduplicator.calculateSavings(original: original, deduplicated: deduped)

        XCTAssertEqual(stats.originalCount, 4)
        XCTAssertEqual(stats.deduplicatedCount, 2)
    }
}
