// The feed URL and the EdDSA public key live in Support/Info.plist (SUFeedURL
// / SUPublicEDKey), and .github/workflows/release.yml generates and signs the
// appcast. Sparkle stores the automatic-check preference itself
// (SUEnableAutomaticChecks in UserDefaults); this file keeps no copy.

import Combine
import Observation
import Sparkle

// SPUUpdater publishes its state through KVO, which @Observable views cannot
// subscribe to, so this model mirrors it and forwards writes back.
@Observable @MainActor
final class UpdaterModel {
    // Sparkle ignores checkForUpdates while an update session runs, so
    // disabling the menu item only makes that no-op visible.
    private(set) var canCheckForUpdates = false

    // Sparkle's own permission prompt (shown once, on the second launch)
    // writes the stored value without passing through this model, so refresh()
    // re-reads it whenever the settings pane appears.
    var automaticallyChecksForUpdates: Bool {
        didSet {
            if controller.updater.automaticallyChecksForUpdates
                != automaticallyChecksForUpdates
            {
                controller.updater.automaticallyChecksForUpdates =
                    automaticallyChecksForUpdates
            }
        }
    }

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var canCheckSubscription: AnyCancellable?

    init() {
        // startingUpdater: true schedules Sparkle's automatic check cycle at
        // launch. Info.plist sets no SUEnableAutomaticChecks, so Sparkle's
        // standard prompt collects consent and the settings Toggle edits that
        // same stored answer.
        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        self.controller = controller
        automaticallyChecksForUpdates =
            controller.updater.automaticallyChecksForUpdates
        canCheckSubscription = controller.updater
            .publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in
                // SPUUpdater is bound to the main thread, so its KVO
                // notifications arrive there.
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = canCheck
                }
            }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // The didSet guard keeps an unchanged value from echoing back into Sparkle.
    func refresh() {
        automaticallyChecksForUpdates =
            controller.updater.automaticallyChecksForUpdates
    }
}
