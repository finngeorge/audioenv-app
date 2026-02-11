import AppKit
import Foundation

/// Loads DAW-specific icons from Resources/daw_icons
class DAWIconLoader {

    private static var iconCache: [String: NSImage] = [:]

    /// Load a DAW icon by format name (for project lists)
    static func icon(for format: SessionFormat) -> NSImage? {
        let iconName = iconFileName(for: format)

        // Check cache first
        if let cached = iconCache[iconName] {
            return cached
        }

        // Load from Bundle.main
        if let image = loadFromBundle(Bundle.main, iconName: iconName) {
            iconCache[iconName] = image
            return image
        }

        // If looking for generic folder icon, use macOS system folder icon
        if iconName == "folder" {
            if #available(macOS 11.0, *) {
                let folderIcon = NSWorkspace.shared.icon(for: .folder)
                iconCache[iconName] = folderIcon
                return folderIcon
            } else {
                let folderIcon = NSWorkspace.shared.icon(forFileType: NSFileTypeForHFSTypeCode(OSType(kGenericFolderIcon)))
                iconCache[iconName] = folderIcon
                return folderIcon
            }
        }

        return nil
    }

    /// Load a session-specific DAW icon (for session detail views)
    static func sessionIcon(for format: SessionFormat) -> NSImage? {
        let iconName = sessionIconFileName(for: format)

        // Check cache first
        if let cached = iconCache[iconName] {
            return cached
        }

        // Load from Bundle.main
        if let image = loadFromBundle(Bundle.main, iconName: iconName) {
            iconCache[iconName] = image
            return image
        }

        // Fallback to regular DAW icon if session-specific not found
        return icon(for: format)
    }

    private static func loadFromBundle(_ bundle: Bundle, iconName: String) -> NSImage? {
        // SwiftPM flattens Resources folder, so icons are at bundle root
        // Try .icns extension first
        if let iconURL = bundle.url(forResource: iconName, withExtension: "icns") {
            return NSImage(contentsOf: iconURL)
        }

        // Try with subdirectory (for other bundle types)
        if let iconURL = bundle.url(forResource: iconName, withExtension: "icns", subdirectory: "daw_icons") {
            return NSImage(contentsOf: iconURL)
        }

        // Try with path prefix
        if let iconURL = bundle.url(forResource: "daw_icons/\(iconName)", withExtension: "icns") {
            return NSImage(contentsOf: iconURL)
        }

        // Try direct file path
        if let resourcePath = bundle.resourcePath {
            let iconPath = "\(resourcePath)/\(iconName).icns"
            if let image = NSImage(contentsOfFile: iconPath) {
                return image
            }
            // Also try with subdirectory
            let subdirPath = "\(resourcePath)/daw_icons/\(iconName).icns"
            return NSImage(contentsOfFile: subdirPath)
        }

        return nil
    }

    private static func iconFileName(for format: SessionFormat) -> String {
        // Projects use folder icons
        switch format {
        case .ableton:
            return "ableton-folder"  // Ableton has custom folder icon
        case .logic:
            return "folder"  // Logic uses generic macOS folder
        case .proTools:
            return "folder"  // Pro Tools uses generic macOS folder
        }
    }

    private static func sessionIconFileName(for format: SessionFormat) -> String {
        // Sessions use session-specific icons
        switch format {
        case .ableton:
            return "ableton-session"
        case .logic:
            return "logic-session"
        case .proTools:
            return "pro-tools-session"
        }
    }
}
