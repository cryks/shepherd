// Persisted app-wide preference for the experimental agent excerpt display.
// The excerpt feature reads terminal screens in the background, so the
// preference gates both the row display (FleetStore.agentExcerptState) and
// the reads themselves (AgentReadMonitor consults it on every snapshot tick).
// It ships off by default while the feature is experimental.

import Foundation
import Observation

/// Background re-read cadence presets for a pane whose status stays working
/// or blocked. Status changes always read immediately, so this bounds only
/// how stale a streaming message can get.
enum ExcerptReadInterval: Int, CaseIterable, Identifiable {
    case twoSeconds = 2
    case fiveSeconds = 5
    case tenSeconds = 10

    var id: Int { rawValue }

    var duration: Duration { .seconds(rawValue) }

    @MainActor var displayName: String {
        tr("\(rawValue) seconds", ja: "\(rawValue)秒")
    }
}

/// The sole writer of the excerpt preference. Being @Observable, views that
/// read isEnabled or readInterval during body evaluation are redrawn when the
/// setting changes; AgentReadMonitor picks the change up on its next snapshot
/// tick instead of being notified.
@Observable @MainActor
final class ExcerptSetting {
    static let shared = ExcerptSetting()

    /// UserDefaults storage keys. The interval is stored as its rawValue in
    /// seconds.
    static let isEnabledKey = "ShowAgentExcerpts"
    static let readIntervalKey = "AgentExcerptReadInterval"

    /// Whether excerpts are shown and terminal screens are read at all.
    /// Persisted to UserDefaults on every write.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.isEnabledKey) }
    }

    /// Re-read cadence while a pane stays working or blocked. Stored
    /// independently of isEnabled, so toggling the feature off and on keeps
    /// the chosen interval.
    var readInterval: ExcerptReadInterval {
        didSet { defaults.set(readInterval.rawValue, forKey: Self.readIntervalKey) }
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: Storage destination. The app proper uses
    ///   standard; tests pass a dedicated suite. A missing or unknown stored
    ///   interval falls back to ten seconds, and a missing enabled flag reads
    ///   as false, so hand-edited defaults cannot break launch.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        readInterval = ExcerptReadInterval(
            rawValue: defaults.integer(forKey: Self.readIntervalKey)
        ) ?? .tenSeconds
    }
}
