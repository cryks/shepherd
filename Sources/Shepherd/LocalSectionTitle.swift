// Owns the local-source label used when at least one remote section is visible.
// Only two UserDefaults keys are persisted (display style and custom label), and
// label resolution (blank fallback for custom, nil for hidden) is centralized
// here. Callers omit the label entirely in a local-only presentation. The setting
// has no bearing on the local monitoring runtime, menu bar state aggregation, or
// agent row display.

import Foundation
import Observation

/// Display style for the local source when it is presented alongside remotes.
/// Chosen with a Picker in Settings (General tab).
enum LocalSectionTitleStyle: String, CaseIterable, Identifiable, Sendable {
    /// Use the default name (This Mac / この Mac) as the source label.
    case standard
    /// Use LocalSectionTitleSetting.customTitle as the source label.
    case custom
    /// Omit the local source label even when remote sections are listed alongside.
    case hidden

    var id: String { rawValue }

    @MainActor var displayName: String {
        switch self {
        case .standard: tr("Default (This Mac)", ja: "デフォルト（この Mac）")
        case .custom: tr("Custom name", ja: "カスタム名")
        case .hidden: tr("Hidden", ja: "非表示")
        }
    }
}

/// The sole writer of the local-source label setting. Being @Observable, views
/// that read style or localTitleWithRemotes during body evaluation are redrawn
/// when the setting changes.
@Observable @MainActor
final class LocalSectionTitleSetting {
    static let shared = LocalSectionTitleSetting()

    /// UserDefaults storage keys. The display style is stored as its rawValue, the custom label as the raw string.
    static let styleKey = "LocalSectionTitleStyle"
    static let customTitleKey = "LocalSectionCustomTitle"

    /// Source-label display style. Persisted to UserDefaults on every write.
    var style: LocalSectionTitleStyle {
        didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
    }

    /// Label used by the custom style. Stored independently of style, so
    /// switching to another style does not lose the entered label.
    var customTitle: String {
        didSet { defaults.set(customTitle, forKey: Self.customTitleKey) }
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: Storage destination. The app proper uses standard; tests pass a dedicated suite.
    /// A missing or unknown rawValue is treated as standard, so hand-edited
    /// defaults or a future change to the storage format cannot break launch.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Self.styleKey)
            .flatMap(LocalSectionTitleStyle.init(rawValue:)) ?? .standard
        customTitle = defaults.string(forKey: Self.customTitleKey) ?? ""
    }

    /// Local source label when remote sections are visible. nil instructs menu,
    /// Monitor, and notification callers to omit the source label. A custom label
    /// that is whitespace-only falls back to the default name.
    var localTitleWithRemotes: String? {
        switch style {
        case .hidden:
            return nil
        case .standard:
            return Self.defaultTitle
        case .custom:
            let trimmed = customTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? Self.defaultTitle : trimmed
        }
    }

    /// Default label. Shared by custom's blank fallback and the placeholder in Settings.
    static var defaultTitle: String { tr("This Mac", ja: "この Mac") }
}
