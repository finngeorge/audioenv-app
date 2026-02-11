import Foundation

/// Shared file system utilities for backup operations
enum FileSystemHelpers {

    /// Recursively calculate the total size of a directory
    /// - Parameter url: The directory URL to calculate
    /// - Returns: Total size in bytes, or 0 if path doesn't exist
    static func calculateDirectorySize(_ url: URL) throws -> UInt64 {
        return calculateDirectorySize(url.path)
    }

    /// Recursively calculate the total size of a directory
    /// - Parameter path: The directory path to calculate
    /// - Returns: Total size in bytes, or 0 if path doesn't exist
    static func calculateDirectorySize(_ path: String) -> UInt64 {
        let fileManager = FileManager.default
        var totalSize: UInt64 = 0
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return 0
        }

        if isDirectory.boolValue {
            // Recursively calculate total size of all files in the directory
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
            // Single file
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let size = attrs[.size] as? UInt64 {
                totalSize = size
            }
        }

        return totalSize
    }

    /// Get the latest modification date in a directory tree
    /// - Parameter path: The directory path to check
    /// - Returns: The most recent modification date, or nil if path doesn't exist
    static func getDirectoryModificationDate(_ path: String) -> Date? {
        let fileManager = FileManager.default
        var latestDate: Date? = nil
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }

        if isDirectory.boolValue {
            // Check modification date of all files in the directory
            guard let enumerator = fileManager.enumerator(atPath: path) else {
                return nil
            }

            // First check the directory itself
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                latestDate = modDate
            }

            // Then check all files
            for case let file as String in enumerator {
                let filePath = (path as NSString).appendingPathComponent(file)
                if let attrs = try? fileManager.attributesOfItem(atPath: filePath),
                   let modDate = attrs[.modificationDate] as? Date {
                    if let currentLatest = latestDate {
                        if modDate > currentLatest {
                            latestDate = modDate
                        }
                    } else {
                        latestDate = modDate
                    }
                }
            }
        } else {
            // Single file
            if let attrs = try? fileManager.attributesOfItem(atPath: path),
               let modDate = attrs[.modificationDate] as? Date {
                latestDate = modDate
            }
        }

        return latestDate
    }

    /// Extract the project folder path from a session file
    /// Handles DAW-specific folder structures:
    /// - Ableton: Session may be in /Backups subfolder, return parent project folder
    /// - Pro Tools: Session may be in /Session File Backups, return parent project folder
    /// - Logic: Return the .logicx bundle itself
    ///
    /// - Parameter session: The audio session
    /// - Returns: The project folder path (parent of session file)
    static func getProjectFolderPath(from session: AudioSession) -> String {
        let sessionPath = session.path
        let sessionURL = URL(fileURLWithPath: sessionPath)

        // For Logic, the .logicx bundle IS the project
        if session.format == .logic {
            return sessionPath
        }

        // For Ableton and Pro Tools, check if in a Backups subfolder
        let parentURL = sessionURL.deletingLastPathComponent()
        let parentName = parentURL.lastPathComponent

        // If in a Backups folder, go up one more level to get project root
        if parentName.lowercased().contains("backup") {
            return parentURL.deletingLastPathComponent().path
        }

        // Otherwise, the parent directory is the project folder
        return parentURL.path
    }
}
