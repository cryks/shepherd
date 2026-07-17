// Owns the display language setting and its resolution. There is no string
// table; each display site lists English (base) and Japanese side by side via
// tr(_:ja:). No .lproj / Localizable.strings is used. This app has no Xcode
// project and is built entirely with swift build + a hand-assembled bundle, so
// instead of the bundle localization machinery it uses a function signature
// that lets the compiler enforce a translation for every supported language.
// To add a language:
//   1. Add a case to ResolvedLanguage
//   2. Add a parameter to the tr / trStored signatures (every call site becomes a compile error)
//   3. Add the translation at each errored site, then add the choice to AppLanguage and the settings Picker
// The only persisted value is AppLanguage.rawValue (UserDefaults "AppLanguage").

import Foundation
import Observation

/// Display language chosen in Settings (General tab). `system` picks a
/// supported language from macOS's preferred-language list, falling back to
/// English when no preferred language is supported.
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    /// UserDefaults storage key. Shared by LanguageSetting (writes) and stored(in:) (reads).
    static let userDefaultsKey = "AppLanguage"

    /// Reads the persisted value. A missing or unknown rawValue is treated as
    /// system, so hand-edited defaults or a future change to the storage format
    /// cannot break launch.
    nonisolated static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: userDefaultsKey) else { return .system }
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    /// The language actually used for display, with system resolved against the
    /// OS preferred languages.
    nonisolated var resolved: ResolvedLanguage {
        switch self {
        case .system: .systemPreferred()
        case .english: .english
        case .japanese: .japanese
        }
    }

    /// Option labels for the settings Picker. Only system follows the UI
    /// language; each concrete language is fixed to its own native name (so a
    /// user who cannot read the current UI language can still find theirs).
    @MainActor var displayName: String {
        switch self {
        case .system: tr("System", ja: "システム")
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

/// Display language after system resolution. The switch subject of tr(_:ja:),
/// with one case per supported language.
enum ResolvedLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case japanese = "ja"

    /// Picks a supported language from macOS's preferred-language list (BCP 47
    /// tags like "ja-JP", in priority order). Matches on the language component
    /// only and returns the first match. English (the base language) when
    /// nothing matches.
    nonisolated static func systemPreferred(
        preferences: [String] = Locale.preferredLanguages
    ) -> ResolvedLanguage {
        for preference in preferences {
            guard let code = Locale(identifier: preference).language.languageCode?.identifier
            else { continue }
            if let match = ResolvedLanguage(rawValue: code) {
                return match
            }
        }
        return .english
    }
}

/// The sole writer of the language setting. Being @Observable, any view that
/// read selection via tr(_:ja:) during body evaluation is redrawn when the
/// setting changes, so language switching takes effect without a restart.
@Observable @MainActor
final class LanguageSetting {
    static let shared = LanguageSetting()

    /// Current selection. Persisted to UserDefaults on every write.
    var selection: AppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: AppLanguage.userDefaultsKey) }
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: Storage destination. The app proper uses standard; tests pass a dedicated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppLanguage.stored(in: defaults)
    }
}

/// Language switch for display strings. English is the base, and the call site
/// lists translations for every supported language. Because it observes
/// LanguageSetting.shared, any string obtained from a view's body (directly or
/// through a display computed property) is redrawn immediately on a language
/// change.
@MainActor
func tr(_ english: String, ja japanese: String) -> String {
    switch LanguageSetting.shared.selection.resolved {
    case .english: english
    case .japanese: japanese
    }
}

/// Nonisolated variant of tr. For strings that may be produced off the
/// MainActor, such as LocalizedError.errorDescription, it reads the persisted
/// UserDefaults value directly. It is not observed, so error strings already
/// captured into @State and the like are not retranslated on a language switch
/// (acceptable since error displays are transient).
nonisolated func trStored(_ english: String, ja japanese: String) -> String {
    switch AppLanguage.stored().resolved {
    case .english: english
    case .japanese: japanese
    }
}
