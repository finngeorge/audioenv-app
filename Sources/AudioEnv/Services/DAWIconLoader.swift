import AppKit
import Foundation

/// Loads DAW-specific icons from Resources/daw_icons
class DAWIconLoader {

    private static var iconCache: [String: NSImage] = [:]

    /// The SwiftPM resource bundle — Bundle.module works for `swift run`,
    /// but for .app bundles the bundle is in Contents/Resources/.
    private static let resourceBundle: Bundle? = {
        // 1) Bundle.module works when running via `swift run` (build dir)
        //    It also works if the build dir still exists after `open .app`
        let moduleBundle = Bundle.module

        // 2) For .app bundles, also check Contents/Resources/
        if let resourceURL = Bundle.main.resourceURL {
            let appBundlePath = resourceURL
                .appendingPathComponent("AudioEnv_AudioEnv.bundle").path
            if let appBundle = Bundle(path: appBundlePath) {
                return appBundle
            }
        }

        return moduleBundle
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
