import Foundation
import Sparkle

public final class UpdaterController: ObservableObject {
    public let controller: SPUStandardUpdaterController

    public init(startAutomatically: Bool) {
        controller = SPUStandardUpdaterController(startingUpdater: startAutomatically,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
    }

    /// Reads and writes Sparkle's actual automatic-check flag.
    /// Backed by `updater.automaticallyChecksForUpdates` — not a separate UserDefaults key.
    public var autoUpdateEnabled: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    public func checkNow() { controller.checkForUpdates(nil) }
}
