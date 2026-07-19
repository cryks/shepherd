// Sparkle integration. Owns the app's SPUStandardUpdaterController for the
// process lifetime and re-publishes the two pieces of updater state the
// settings pane reads. The feed URL and EdDSA public key live in
// Support/Info.plist (SUFeedURL / SUPublicEDKey); the appcast itself is
// generated and signed by .github/workflows/release.yml. Persistence of the
// automatic-check preference belongs to Sparkle (SUEnableAutomaticChecks in
// UserDefaults), not to this file.

import Combine
import Observation
import Sparkle

/// Bridge between SPUUpdater and SwiftUI. SPUUpdater publishes state through
/// KVO, which @Observable views cannot subscribe to, so this model mirrors
/// what the UI needs and forwards writes back to the updater.
@Observable @MainActor
final class UpdaterModel {
    /// False while an update session is running. The "Check for Updates…"
    /// button is disabled in that state; SPUUpdater ignores checkForUpdates
    /// calls then, so the disabled state only makes the no-op visible.
    private(set) var canCheckForUpdates = false

    /// Mirror of SPUUpdater.automaticallyChecksForUpdates for the settings
    /// Toggle. Sparkle's own permission prompt (shown once, on the second
    /// launch) writes the underlying value without going through this model,
    /// so refresh() re-reads it whenever the settings pane appears.
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
        // launch. Info.plist sets no SUEnableAutomaticChecks, so consent for
        // background checks is collected by Sparkle's standard prompt and the
        // settings Toggle edits that same stored answer.
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
                // SPUUpdater is main-thread bound, so its KVO notifications
                // arrive on the main thread and assumeIsolated holds.
                MainActor.assumeIsolated {
                    self?.canCheckForUpdates = canCheck
                }
            }
    }

    /// User-initiated check through Sparkle's standard UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Re-reads automaticallyChecksForUpdates from the updater; the didSet
    /// guard keeps an unchanged value from echoing back into Sparkle.
    func refresh() {
        automaticallyChecksForUpdates =
            controller.updater.automaticallyChecksForUpdates
    }
}
