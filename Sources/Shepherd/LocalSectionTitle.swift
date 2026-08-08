import Foundation
import Observation

// Raw values are persisted in UserDefaults; renaming a case breaks stored
// settings.
enum LocalSectionTitleStyle: String, CaseIterable, Identifiable, Sendable {
    case standard
    case custom
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

@Observable @MainActor
final class LocalSectionTitleSetting {
    static let shared = LocalSectionTitleSetting()

    static let styleKey = "LocalSectionTitleStyle"
    static let customTitleKey = "LocalSectionCustomTitle"

    var style: LocalSectionTitleStyle {
        didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
    }

    // Kept apart from `style` so switching away from custom and back does not
    // lose what the user typed.
    var customTitle: String {
        didSet { defaults.set(customTitle, forKey: Self.customTitleKey) }
    }

    private let defaults: UserDefaults

    // An unknown rawValue falls back to standard: a hand-edited or
    // future-format defaults entry must not stop the app from launching.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Self.styleKey)
            .flatMap(LocalSectionTitleStyle.init(rawValue:)) ?? .standard
        customTitle = defaults.string(forKey: Self.customTitleKey) ?? ""
    }

    // nil tells menu, Monitor, and notification callers to omit the source
    // label entirely.
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

    static var defaultTitle: String { tr("This Mac", ja: "この Mac") }
}
