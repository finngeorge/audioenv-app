import Foundation

/// Service for comparing backups and detecting changes
/// Enables version tracking and incremental backup decisions
@MainActor
class BackupComparisonService {

    /// Check if a project has changed since a previous backup
    /// - Parameters:
    ///   - project: The current project to check
    ///   - previousBackup: The previous backup manifest to compare against
    /// - Returns: True if the project has changed (different size or modification date)
    static func hasProjectChanged(
        _ project: SessionProject,
        comparedTo previousBackup: BackupManifest
    ) -> Bool {
        guard let firstSession = project.sessions.first else { return true }

        // Get current project folder info
        let projectPath = FileSystemHelpers.getProjectFolderPath(from: firstSession)
        let currentSize = FileSystemHelpers.calculateDirectorySize(projectPath)
        guard let currentModDate = FileSystemHelpers.getDirectoryModificationDate(projectPath) else {
            return true // Can't determine, assume changed
        }

        // Find matching project in previous backup
        guard let previousProject = previousBackup.projects.first(where: { $0.projectName == project.name }) else {
            return true // New project
        }

        // Compare size and modification date
        if currentSize != previousProject.totalSizeBytes {
            return true // Size changed
        }

        // Compare modification dates (allow 1 second tolerance for filesystem quirks)
        let timeDiff = abs(currentModDate.timeIntervalSince(previousProject.lastModified))
        if timeDiff > 1.0 {
            return true // Modified date changed
        }

        return false // No changes detected
    }

    /// Get list of projects that have changed since the previous backup
    /// - Parameters:
    ///   - currentProjects: Current projects to check
    ///   - previousBackup: Previous backup manifest to compare against
    /// - Returns: Array of projects that have changed
    static func getChangedProjects(
        from currentProjects: [SessionProject],
        comparedTo previousBackup: BackupManifest
    ) -> [SessionProject] {
        return currentProjects.filter { project in
            hasProjectChanged(project, comparedTo: previousBackup)
        }
    }

    /// Calculate storage savings from skipping unchanged projects
    /// - Parameters:
    ///   - currentProjects: All current projects
    ///   - previousBackup: Previous backup manifest
    /// - Returns: Number of bytes that would be saved by only backing up changed projects
    static func calculateSavings(
        from currentProjects: [SessionProject],
        comparedTo previousBackup: BackupManifest
    ) -> UInt64 {
        let unchangedProjects = currentProjects.filter { project in
            !hasProjectChanged(project, comparedTo: previousBackup)
        }

        return unchangedProjects.reduce(UInt64(0)) { total, project in
            guard let firstSession = project.sessions.first else { return total }
            let projectPath = FileSystemHelpers.getProjectFolderPath(from: firstSession)
            return total + FileSystemHelpers.calculateDirectorySize(projectPath)
        }
    }

    /// Get summary statistics for a comparison
    /// - Parameters:
    ///   - currentProjects: Current projects to check
    ///   - previousBackup: Previous backup manifest
    /// - Returns: Summary statistics
    static func getComparisonStats(
        from currentProjects: [SessionProject],
        comparedTo previousBackup: BackupManifest
    ) -> ComparisonStats {
        let changedProjects = getChangedProjects(from: currentProjects, comparedTo: previousBackup)
        let unchangedCount = currentProjects.count - changedProjects.count
        let savings = calculateSavings(from: currentProjects, comparedTo: previousBackup)

        return ComparisonStats(
            totalProjects: currentProjects.count,
            changedProjects: changedProjects.count,
            unchangedProjects: unchangedCount,
            estimatedSavings: savings
        )
    }
}

/// Statistics from comparing current state to previous backup
struct ComparisonStats {
    let totalProjects: Int
    let changedProjects: Int
    let unchangedProjects: Int
    let estimatedSavings: UInt64 // Bytes that could be saved with incremental backup

    var formattedSavings: String {
        ByteCountFormatter.string(fromByteCount: Int64(estimatedSavings), countStyle: .file)
    }

    var changePercentage: Double {
        guard totalProjects > 0 else { return 0 }
        return Double(changedProjects) / Double(totalProjects) * 100
    }
}
