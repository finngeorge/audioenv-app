import Foundation

/// Defines what should be included in a backup
enum BackupScope: Equatable, Identifiable {
    case everything
    case projectWithDependencies(SessionProject)
    case singleProject(SessionProject)
    case singlePlugin(AudioPlugin)
    case selectedPlugins([AudioPlugin])
    case selectedProjects([SessionProject])
    case custom(plugins: [AudioPlugin], projects: [SessionProject])
    case collection(name: String, projects: [SessionProject], plugins: [AudioPlugin])

    var id: String {
        switch self {
        case .everything:
            return "everything"
        case .projectWithDependencies(let project):
            return "project-deps-\(project.id)"
        case .singleProject(let project):
            return "single-project-\(project.id)"
        case .singlePlugin(let plugin):
            return "single-plugin-\(plugin.id)"
        case .selectedPlugins(let plugins):
            return "plugins-\(plugins.count)"
        case .selectedProjects(let projects):
            return "projects-\(projects.count)"
        case .custom:
            return "custom"
        case .collection(let name, _, _):
            return "collection-\(name)"
        }
    }

    /// Generate a user-friendly name for this backup scope
    func generateName() -> String {
        switch self {
        case .everything:
            return "Complete Environment Backup"
        case .projectWithDependencies(let project):
            return "\(project.name) + Dependencies"
        case .singleProject(let project):
            return "\(project.name) Only"
        case .singlePlugin(let plugin):
            return "\(plugin.name) Plugin"
        case .selectedPlugins(let plugins):
            return "\(plugins.count) Selected Plugins"
        case .selectedProjects(let projects):
            return "\(projects.count) Selected Projects"
        case .custom(let plugins, let projects):
            let parts = [
                plugins.isEmpty ? nil : "\(plugins.count) plugin\(plugins.count == 1 ? "" : "s")",
                projects.isEmpty ? nil : "\(projects.count) project\(projects.count == 1 ? "" : "s")"
            ].compactMap { $0 }
            return parts.joined(separator: " + ")
        case .collection(let name, _, _):
            return "\(name) Collection"
        }
    }

    /// Detailed description of what's included
    func getDescription() -> String {
        switch self {
        case .everything:
            return "All plugins and all project files"
        case .projectWithDependencies(let project):
            return "Project '\(project.name)' and all plugins used in its sessions"
        case .singleProject(let project):
            return "Only the project files for '\(project.name)' (no plugins)"
        case .singlePlugin(let plugin):
            return "Only the '\(plugin.name)' plugin (\(plugin.format.rawValue))"
        case .selectedPlugins(let plugins):
            return "\(plugins.count) manually selected plugin\(plugins.count == 1 ? "" : "s")"
        case .selectedProjects(let projects):
            return "\(projects.count) manually selected project\(projects.count == 1 ? "" : "s")"
        case .custom(let plugins, let projects):
            return "Custom selection: \(plugins.count) plugins, \(projects.count) projects"
        case .collection(let name, let projects, let plugins):
            return "Collection '\(name)': \(projects.count) projects, \(plugins.count) plugin dependencies"
        }
    }
}

/// Statistics about what will be included in a backup
struct BackupScopeStats {
    let pluginCount: Int
    let projectCount: Int
    let sessionCount: Int
    let totalSize: UInt64
    let pluginSize: UInt64
    let projectSize: UInt64

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }

    var formattedPluginSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(pluginSize), countStyle: .file)
    }

    var formattedProjectSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(projectSize), countStyle: .file)
    }

    var isEmpty: Bool {
        pluginCount == 0 && projectCount == 0
    }
}

/// Extension to calculate stats for a scope
extension BackupScope {
    @MainActor func calculateStats(scanner: ScannerService) -> BackupScopeStats {
        let (plugins, projects) = self.resolve(scanner: scanner)

        let pluginSize = plugins.reduce(into: UInt64(0)) { result, plugin in
            result += getPluginSize(plugin)
        }

        // Calculate entire project folder sizes (not just session files)
        let projectSize = projects.reduce(into: UInt64(0)) { result, project in
            guard let firstSession = project.sessions.first else { return }
            let projectPath = FileSystemHelpers.getProjectFolderPath(from: firstSession)
            result += FileSystemHelpers.calculateDirectorySize(projectPath)
        }

        let sessionCount = projects.flatMap(\.sessions).count

        return BackupScopeStats(
            pluginCount: plugins.count,
            projectCount: projects.count,
            sessionCount: sessionCount,
            totalSize: pluginSize + projectSize,
            pluginSize: pluginSize,
            projectSize: projectSize
        )
    }

    /// Get the size of a plugin bundle by recursively summing all files
    private func getPluginSize(_ plugin: AudioPlugin) -> UInt64 {
        let fileManager = FileManager.default
        var totalSize: UInt64 = 0

        // Check if path is a directory (bundle)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: plugin.path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            // Recursively calculate total size of all files in the bundle
            guard let enumerator = fileManager.enumerator(atPath: plugin.path) else {
                return 0
            }

            for case let file as String in enumerator {
                let filePath = (plugin.path as NSString).appendingPathComponent(file)
                if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                   let fileSize = attrs[.size] as? UInt64,
                   attrs[.type] as? FileAttributeType == .typeRegular {
                    totalSize += fileSize
                }
            }
        } else {
            // Single file
            if let attrs = try? fileManager.attributesOfItem(atPath: plugin.path),
               let size = attrs[.size] as? UInt64 {
                totalSize = size
            }
        }

        return totalSize
    }

    /// Resolve this scope into concrete plugins and projects
    @MainActor func resolve(scanner: ScannerService) -> (plugins: [AudioPlugin], projects: [SessionProject]) {
        switch self {
        case .everything:
            let projects = SessionProject.groupSessions(scanner.sessions)
            return (scanner.plugins, projects)

        case .projectWithDependencies(let project):
            // Get all plugins used in this project's sessions
            let usedPluginNames = Set(project.sessions.flatMap { session -> [String] in
                guard let parsedProject = session.project else { return [] }
                switch parsedProject {
                case .ableton(let abletonProject):
                    return abletonProject.usedPlugins
                case .logic(_), .proTools(_):
                    // Logic and Pro Tools parsing doesn't extract plugin info yet
                    return []
                }
            })

            // Match plugin names to actual plugins (fuzzy match)
            let usedPlugins = scanner.plugins.filter { plugin in
                let pluginName = plugin.name.lowercased()
                return usedPluginNames.contains { usedName in
                    let name = usedName.lowercased()
                    return name.contains(pluginName) || pluginName.contains(name)
                }
            }
            return (usedPlugins, [project])

        case .singleProject(let project):
            return ([], [project])

        case .singlePlugin(let plugin):
            return ([plugin], [])

        case .selectedPlugins(let plugins):
            return (plugins, [])

        case .selectedProjects(let projects):
            return ([], projects)

        case .custom(let plugins, let projects):
            return (plugins, projects)

        case .collection(_, let projects, let plugins):
            return (plugins, projects)
        }
    }
}
