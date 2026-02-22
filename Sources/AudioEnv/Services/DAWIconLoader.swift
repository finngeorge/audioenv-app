import AppKit
import Foundation

/// Loads DAW-specific icons from Resources/daw_icons
class DAWIconLoader {

    private static var iconCache: [String: NSImage] = [:]

    /// Resource bundle that works for both SPM (`swift run`) and Xcode (.app) builds.
    private static let resourceBundle: Bundle? = {
        // SPM .app bundles: Contents/Resources/AudioEnv_AudioEnv.bundle
        if let resourceURL = Bundle.main.resourceURL {
            let nested = resourceURL.appendingPathComponent("AudioEnv_AudioEnv.bundle")
            if let bundle = Bundle(path: nested.path) {
                return bundle
            }
        }
        // SPM `swift run`: resource bundle is next to the executable
        if let execURL = Bundle.main.executableURL {
            let adjacent = execURL.deletingLastPathComponent()
                .appendingPathComponent("AudioEnv_AudioEnv.bundle")
            if let bundle = Bundle(path: adjacent.path) {
                return bundle
            }
        }
        return Bundle.main
    }()

    /// Load a DAW icon by format name (for project lists)
    static func icon(for format: SessionFormat) -> NSImage? {
        let iconName = iconFileName(for: format)

        if let cached = iconCache[iconName] {
            return cached
        }

        // Try resource bundle, then Bundle.main
        if let bundle = resourceBundle,
           let image = loadFromBundle(bundle, iconName: iconName) {
            iconCache[iconName] = image
            return image
        }
        if let image = loadFromBundle(Bundle.main, iconName: iconName) {
            iconCache[iconName] = image
            return image
        }

        // Generic folder icon fallback
        if iconName == "folder" {
            let folderIcon = NSWorkspace.shared.icon(for: .folder)
            iconCache[iconName] = folderIcon
            return folderIcon
        }

        return nil
    }

    /// Load a session-specific DAW icon (for session detail views)
    static func sessionIcon(for format: SessionFormat) -> NSImage? {
        let iconName = sessionIconFileName(for: format)

        if let cached = iconCache[iconName] {
            return cached
        }

        // Try resource bundle, then Bundle.main
        if let bundle = resourceBundle,
           let image = loadFromBundle(bundle, iconName: iconName) {
            iconCache[iconName] = image
            return image
        }
        if let image = loadFromBundle(Bundle.main, iconName: iconName) {
            iconCache[iconName] = image
            return image
        }

        // Fallback to regular DAW icon
        return icon(for: format)
    }

    /// Returns the macOS document icon for a specific file path (e.g. a .logicx bundle).
    static func documentIcon(forFile path: String) -> NSImage {
        NSWorkspace.shared.icon(forFile: path)
    }

    /// Returns the Logic Pro session thumbnail (WindowImage.jpg) if it exists inside a .logicx bundle.
    static func logicThumbnail(forBundle path: String) -> NSImage? {
        let thumbPath = (path as NSString).appendingPathComponent("Alternatives/000/WindowImage.jpg")
        return NSImage(contentsOfFile: thumbPath)
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
