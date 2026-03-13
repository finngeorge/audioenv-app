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
    case collection(name: String, projects: [SessionProject], plugins: [AudioPlugin], bounces: [Bounce] = [])

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
        case .collection(let name, _, _, _):
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
        case .collection(let name, _, _, _):
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
        case .collection(let name, let projects, let plugins, let bounces):
            var parts: [String] = []
            if !projects.isEmpty { parts.append("\(projects.count) projects") }
            if !bounces.isEmpty { parts.append("\(bounces.count) bounces") }
            if !plugins.isEmpty { parts.append("\(plugins.count) plugin dependencies") }
            return "Collection '\(name)': \(parts.joined(separator: ", "))"
        }
    }
}

/// Statistics about what will be included in a backup
struct BackupScopeStats {
    let pluginCount: Int
    let projectCount: Int
    let sessionCount: Int
    let bounceCount: Int
    let totalSize: UInt64
    let pluginSize: UInt64
    let projectSize: UInt64
    let bounceSize: UInt64

    init(pluginCount: Int, projectCount: Int, sessionCount: Int, bounceCount: Int = 0,
         totalSize: UInt64, pluginSize: UInt64, projectSize: UInt64, bounceSize: UInt64 = 0) {
        self.pluginCount = pluginCount
        self.projectCount = projectCount
        self.sessionCount = sessionCount
        self.bounceCount = bounceCount
        self.totalSize = totalSize
        self.pluginSize = pluginSize
        self.projectSize = projectSize
        self.bounceSize = bounceSize
    }

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(totalSize), countStyle: .file)
    }

    var formattedPluginSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(pluginSize), countStyle: .file)
    }

    var formattedProjectSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(projectSize), countStyle: .file)
    }

    var formattedBounceSize: String {
        ByteCountFormatter.string(fromByteCount: Int64(bounceSize), countStyle: .file)
    }

    var isEmpty: Bool {
        pluginCount == 0 && projectCount == 0 && bounceCount == 0
    }
}

/// Extension to calculate stats for a scope
extension BackupScope {
    @MainActor func calculateStats(scanner: ScannerService, matchUsedFormatsOnly: Bool = true) async -> BackupScopeStats {
        let (plugins, projects) = self.resolve(scanner: scanner, matchUsedFormatsOnly: matchUsedFormatsOnly)

        // Capture paths for off-thread file I/O
        let pluginPaths = plugins.map { $0.path }
        let projectPaths = projects.compactMap { $0.sessions.first }.map { FileSystemHelpers.getProjectFolderPath(from: $0) }
        let sessionCount = projects.flatMap(\.sessions).count

        let collectionBounces: [Bounce]
        if case .collection(_, _, _, let bounces) = self {
            collectionBounces = bounces
        } else {
            collectionBounces = []
        }

        // Heavy file I/O runs off the main thread
        let (pluginSize, projectSize, bounceSize) = await Task.detached {
            let pSize = pluginPaths.reduce(into: UInt64(0)) { result, path in
                result += Self.getPathSize(path)
            }
            let prSize = projectPaths.reduce(into: UInt64(0)) { result, path in
                result += FileSystemHelpers.calculateDirectorySize(path)
            }
            let bSize = collectionBounces.reduce(into: UInt64(0)) { result, bounce in
                result += UInt64(bounce.fileSizeBytes)
            }
            return (pSize, prSize, bSize)
        }.value

        return BackupScopeStats(
            pluginCount: plugins.count,
            projectCount: projects.count,
            sessionCount: sessionCount,
            bounceCount: collectionBounces.count,
            totalSize: pluginSize + projectSize + bounceSize,
            pluginSize: pluginSize,
            projectSize: projectSize,
            bounceSize: bounceSize
        )
    }

    /// Get the size of a file or bundle at a path by recursively summing all files
    static func getPathSize(_ path: String) -> UInt64 {
        let fileManager = FileManager.default
        var totalSize: UInt64 = 0

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            guard let enumerator = fileManager.enumerator(atPath: path) else {
                return 0
            }

            for case let file as String in enumerator {
                let filePath = (path as NSString).appendingPathComponent(file)
                if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                   let fileSize = attrs[.size] as? UInt64,
                   attrs[.type] as? FileAttributeType == .typeRegular {
                    totalSize += fileSize
                }
            }
        } else {
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                totalSize = size
            }
        }

        return totalSize
    }

    /// Resolve this scope into concrete plugins and projects.
    /// When `matchUsedFormatsOnly` is true (default), only the plugin format actually used
    /// in the project (AU/VST/VST3/AAX) is included rather than all installed formats.
    @MainActor func resolve(scanner: ScannerService, matchUsedFormatsOnly: Bool = true) -> (plugins: [AudioPlugin], projects: [SessionProject]) {
        switch self {
        case .everything:
            let projects = SessionProject.groupSessions(scanner.sessions)
            return (scanner.plugins, projects)

        case .projectWithDependencies(let project):
            // Collect structured plugin info (with format) from parsed sessions
            var pluginInfos: [AbletonPluginInfo] = []
            var pluginNames: Set<String> = []

            for session in project.sessions {
                guard let parsedProject = session.project else { continue }
                switch parsedProject {
                case .ableton(let abletonProject):
                    // Prefer structured pluginInfos from tracks (has format data)
                    for track in abletonProject.tracks {
                        if let infos = track.pluginInfos {
                            pluginInfos.append(contentsOf: infos)
                        }
                    }
                    pluginNames.formUnion(abletonProject.usedPlugins)
                case .logic(_), .proTools(_):
                    break
                }
            }

            // Build a set of (name, format) pairs for format-aware matching
            let usedFormats: [String: Set<String>] = {
                var map: [String: Set<String>] = [:]
                for info in pluginInfos {
                    let normalized = info.name.lowercased()
                    let fmt = info.format.uppercased()
                        .replacingOccurrences(of: "VST2", with: "VST")
                    map[normalized, default: []].insert(fmt)
                }
                return map
            }()

            // Match plugin names to actual plugins
            let usedPlugins = scanner.plugins.filter { plugin in
                let pluginName = plugin.name.lowercased()
                let nameMatch = pluginNames.contains { usedName in
                    let name = usedName.lowercased()
                    return name.contains(pluginName) || pluginName.contains(name)
                }
                guard nameMatch else { return false }

                // If format-aware matching is enabled and we have format data, filter by format
                if matchUsedFormatsOnly && !usedFormats.isEmpty {
                    // Check if any used plugin name matches this plugin AND uses its format
                    let pluginFmt = plugin.format.rawValue.uppercased()
                    for (usedName, formats) in usedFormats {
                        let nameMatches = usedName.contains(pluginName) || pluginName.contains(usedName)
                        if nameMatches && formats.contains(pluginFmt) {
                            return true
                        }
                    }
                    // Name matched but format didn't — check if we have format data for this plugin
                    // If no format info exists for this plugin name, include it (safe fallback)
                    let hasFormatData = usedFormats.keys.contains { key in
                        key.contains(pluginName) || pluginName.contains(key)
                    }
                    return !hasFormatData
                }

                return true
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

        case .collection(_, let projects, let plugins, _):
            return (plugins, projects)
        }
    }
}
