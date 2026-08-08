import Foundation
import Observation

// A status change always triggers an immediate read, so these presets bound
// only how stale a streaming message can get between changes.
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

// Sole writer of the excerpt preference. It gates the row display and the
// background terminal reads alike: AgentReadMonitor consults it on each
// snapshot tick rather than being notified.
@Observable @MainActor
final class ExcerptSetting {
    static let shared = ExcerptSetting()

    static let isEnabledKey = "ShowAgentExcerpts"
    static let readIntervalKey = "AgentExcerptReadInterval"

    // Off by default while the feature is experimental, which the missing-key
    // reading of `defaults.bool` already gives.
    var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.isEnabledKey) }
    }

    var readInterval: ExcerptReadInterval {
        didSet { defaults.set(readInterval.rawValue, forKey: Self.readIntervalKey) }
    }

    private let defaults: UserDefaults

    // Tests pass a dedicated suite. A missing key reads as 0 and a hand-edited
    // one can hold anything, and both land on the ten-second fallback.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.isEnabledKey)
        readInterval = ExcerptReadInterval(
            rawValue: defaults.integer(forKey: Self.readIntervalKey)
        ) ?? .tenSeconds
    }
}
