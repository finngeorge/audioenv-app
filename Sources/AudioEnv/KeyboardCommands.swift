import Foundation
import SwiftUI

// MARK: - Notification Names for Keyboard Shortcuts

extension Notification.Name {
    static let triggerRescan = Notification.Name("AudioEnv.triggerRescan")
    static let showPathManager = Notification.Name("AudioEnv.showPathManager")
    static let focusSearch = Notification.Name("AudioEnv.focusSearch")
    static let navigateToSummary = Notification.Name("AudioEnv.navigateToSummary")
}

// MARK: - App Commands

struct AudioEnvCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Replace default new item command (we don't need it)
        }

        CommandMenu("Actions") {
            Button("Scan for Plugins & Sessions") {
                NotificationCenter.default.post(name: .triggerRescan, object: nil)
            }
            .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("Manage Scan Paths...") {
                NotificationCenter.default.post(name: .showPathManager, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Focus Search") {
                NotificationCenter.default.post(name: .focusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }
    }
}
