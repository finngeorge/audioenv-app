import Foundation
import os.log
import Sparkle

@MainActor
class UpdaterService: ObservableObject {
    private let logger = Logger(subsystem: "com.audioenv.app", category: "Updater")

    private let updaterController: SPUStandardUpdaterController

    @Published var canCheckForUpdates = false

    init() {
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        // Bind canCheckForUpdates to the updater's state
        updaterController.updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        logger.info("Checking for updates...")
        updaterController.checkForUpdates(nil)
    }
}
