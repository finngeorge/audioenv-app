import Foundation

/// Validation result for a path
enum PathValidationResult {
    case valid
    case notFound
    case notAccessible
    case wouldOverwrite
}

/// Utility for validating paths for cross-computer restore operations
enum PathValidator {

    /// Validate if a path exists and is accessible
    /// - Parameter path: The path to validate
    /// - Returns: Validation result
    static func validate(_ path: String) -> PathValidationResult {
        let fileManager = FileManager.default

        // Check if path exists
        guard fileManager.fileExists(atPath: path) else {
            return .notFound
        }

        // Check if path is accessible (readable)
        guard fileManager.isReadableFile(atPath: path) else {
            return .notAccessible
        }

        return .valid
    }

    /// Check if restoring to a path would overwrite existing files
    /// - Parameter path: The destination path
    /// - Returns: Validation result
    static func checkForConflicts(_ path: String) -> PathValidationResult {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: path) {
            return .wouldOverwrite
        }

        return .valid
    }

    /// Suggest alternative locations when a path is invalid
    /// - Parameter originalPath: The original path that is invalid
    /// - Parameter isPlugin: Whether this is a plugin path (vs project path)
    /// - Returns: Array of suggested alternative paths
    static func suggestAlternatives(for originalPath: String, isPlugin: Bool = false) -> [String] {
        var suggestions: [String] = []

        if isPlugin {
            // Common plugin locations on macOS
            let pluginLocations = [
                "/Library/Audio/Plug-Ins/VST3",
                "/Library/Audio/Plug-Ins/VST",
                "/Library/Audio/Plug-Ins/Components",
                "~/Library/Audio/Plug-Ins/VST3",
                "~/Library/Audio/Plug-Ins/VST",
                "~/Library/Audio/Plug-Ins/Components"
            ]

            // Expand ~ to home directory
            suggestions = pluginLocations.map { path in
                (path as NSString).expandingTildeInPath
            }
        } else {
            // Common project locations
            let projectLocations = [
                "~/Documents",
                "~/Music",
                "~/Desktop",
                "/Volumes" // External drives
            ]

            // Expand ~ to home directory
            suggestions = projectLocations.map { path in
                (path as NSString).expandingTildeInPath
            }
        }

        // Filter to only existing paths
        return suggestions.filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Validate multiple paths and return detailed results
    /// - Parameter paths: Array of paths to validate
    /// - Returns: Dictionary mapping paths to their validation results
    static func validateBatch(_ paths: [String]) -> [String: PathValidationResult] {
        var results: [String: PathValidationResult] = [:]

        for path in paths {
            results[path] = validate(path)
        }

        return results
    }

    /// Check if all paths in a batch are valid
    /// - Parameter paths: Array of paths to validate
    /// - Returns: True if all paths are valid, false otherwise
    static func allValid(_ paths: [String]) -> Bool {
        return paths.allSatisfy { validate($0) == .valid }
    }

    /// Get invalid paths from a batch
    /// - Parameter paths: Array of paths to validate
    /// - Returns: Array of paths that are not valid
    static func getInvalidPaths(_ paths: [String]) -> [String] {
        return paths.filter { validate($0) != .valid }
    }
}
