import XCTest
@testable import AudioEnv

final class BackupScopeTests: XCTestCase {

    private func makeProject(name: String) -> SessionProject {
        SessionProject(id: "test-\(name)", name: name, format: .ableton, sessions: [], backups: [], latestDate: Date())
    }

    private func makePlugin(name: String, format: PluginFormat = .vst3) -> AudioPlugin {
        AudioPlugin(name: name, path: "/tmp/\(name)", format: format)
    }

    // MARK: - generateName

    func testEverythingName() {
        XCTAssertEqual(BackupScope.everything.generateName(), "Complete Environment Backup")
    }

    func testProjectWithDepsName() {
        let scope = BackupScope.projectWithDependencies(makeProject(name: "My Song"))
        XCTAssertEqual(scope.generateName(), "My Song + Dependencies")
    }

    func testSingleProjectName() {
        let scope = BackupScope.singleProject(makeProject(name: "Demo Track"))
        XCTAssertEqual(scope.generateName(), "Demo Track Only")
    }

    func testSinglePluginName() {
        let scope = BackupScope.singlePlugin(makePlugin(name: "Pro-Q 3"))
        XCTAssertEqual(scope.generateName(), "Pro-Q 3 Plugin")
    }

    func testSelectedPluginsName() {
        let scope = BackupScope.selectedPlugins([makePlugin(name: "A"), makePlugin(name: "B"), makePlugin(name: "C")])
        XCTAssertEqual(scope.generateName(), "3 Selected Plugins")
    }

    func testSelectedProjectsName() {
        let scope = BackupScope.selectedProjects([makeProject(name: "X"), makeProject(name: "Y")])
        XCTAssertEqual(scope.generateName(), "2 Selected Projects")
    }

    func testCustomName() {
        let scope = BackupScope.custom(
            plugins: [makePlugin(name: "A"), makePlugin(name: "B")],
            projects: [makeProject(name: "X")]
        )
        XCTAssertEqual(scope.generateName(), "2 plugins + 1 project")
    }

    func testCustomNameSingular() {
        let scope = BackupScope.custom(
            plugins: [makePlugin(name: "A")],
            projects: [makeProject(name: "X")]
        )
        XCTAssertEqual(scope.generateName(), "1 plugin + 1 project")
    }

    // MARK: - getDescription

    func testEverythingDescription() {
        XCTAssertEqual(BackupScope.everything.getDescription(), "All plugins and all project files")
    }

    func testProjectWithDepsDescription() {
        let scope = BackupScope.projectWithDependencies(makeProject(name: "Beat"))
        XCTAssertEqual(scope.getDescription(), "Project 'Beat' and all plugins used in its sessions")
    }

    func testSingleProjectDescription() {
        let scope = BackupScope.singleProject(makeProject(name: "Demo"))
        XCTAssertEqual(scope.getDescription(), "Only the project files for 'Demo' (no plugins)")
    }

    func testSinglePluginDescription() {
        let scope = BackupScope.singlePlugin(makePlugin(name: "Serum", format: .vst3))
        XCTAssertEqual(scope.getDescription(), "Only the 'Serum' plugin (VST3)")
    }

    func testSelectedPluginsDescriptionPlural() {
        let scope = BackupScope.selectedPlugins([makePlugin(name: "A"), makePlugin(name: "B")])
        XCTAssertEqual(scope.getDescription(), "2 manually selected plugins")
    }

    func testSelectedPluginsDescriptionSingular() {
        let scope = BackupScope.selectedPlugins([makePlugin(name: "A")])
        XCTAssertEqual(scope.getDescription(), "1 manually selected plugin")
    }

    func testCustomDescription() {
        let scope = BackupScope.custom(
            plugins: [makePlugin(name: "A")],
            projects: [makeProject(name: "X"), makeProject(name: "Y")]
        )
        XCTAssertEqual(scope.getDescription(), "Custom selection: 1 plugins, 2 projects")
    }

    // MARK: - id uniqueness

    func testDistinctIds() {
        let ids = [
            BackupScope.everything.id,
            BackupScope.singlePlugin(makePlugin(name: "A")).id,
            BackupScope.selectedPlugins([makePlugin(name: "A")]).id,
            BackupScope.selectedProjects([makeProject(name: "X")]).id,
            BackupScope.custom(plugins: [], projects: []).id,
        ]
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
