// Owns the heading display setting for the local section (This Mac). Only two
// UserDefaults keys are persisted (display style and custom label), and the
// heading string resolution (blank fallback for custom, nil for hidden) is also
// centralized here. Only the heading row's display changes: this has no bearing
// on the local monitoring runtime, the menu bar state aggregation, or agent row
// display.

import Foundation
import Observation

/// Display style for the local section heading. Chosen with a Picker in Settings (General tab).
enum LocalSectionTitleStyle: String, CaseIterable, Identifiable, Sendable {
    /// Use the default name (This Mac / この Mac) as the heading.
    case standard
    /// Use LocalSectionTitleSetting.customTitle as the heading.
    case custom
    /// Never draw the local heading row, even when remote sections are listed alongside.
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

/// The sole writer of the local-section heading setting. Being @Observable, any
/// view that read style or localHeaderTitle during body evaluation (SourceList,
/// Settings) is redrawn when the setting changes.
@Observable @MainActor
final class LocalSectionTitleSetting {
    static let shared = LocalSectionTitleSetting()

    /// UserDefaults storage keys. The display style is stored as its rawValue, the custom label as the raw string.
    static let styleKey = "LocalSectionTitleStyle"
    static let customTitleKey = "LocalSectionCustomTitle"

    /// Heading display style. Persisted to UserDefaults on every write.
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

    /// Heading string for the local section. nil is the instruction to not draw
    /// the heading row (hidden). A custom label that is whitespace-only falls
    /// back to the default name so no empty heading row remains.
    var localHeaderTitle: String? {
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

    /// Default heading. Shared by custom's blank fallback and the placeholder in the settings screen.
    static var defaultTitle: String { tr("This Mac", ja: "この Mac") }
}
