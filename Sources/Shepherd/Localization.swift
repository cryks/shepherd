// The app has no Xcode project and builds with swift build plus a
// hand-assembled bundle, so it uses no .lproj / Localizable.strings. Every
// display site instead lists its translations in a tr(_:ja:) call, and the
// signature makes the compiler demand one string per supported language: a new
// language means a new ResolvedLanguage case and a new parameter on tr /
// trStored, which turns every call site into a compile error until translated.

import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    static let userDefaultsKey = "AppLanguage"

    // A missing or unknown rawValue falls back to system, so hand-edited
    // defaults or a later change of storage format cannot break launch.
    nonisolated static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: userDefaultsKey) else { return .system }
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    nonisolated var resolved: ResolvedLanguage {
        switch self {
        case .system: .systemPreferred()
        case .english: .english
        case .japanese: .japanese
        }
    }

    // Each concrete language keeps its native name so a user who cannot read
    // the current UI language can still find their own.
    @MainActor var displayName: String {
        switch self {
        case .system: tr("System", ja: "システム")
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

enum ResolvedLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case japanese = "ja"

    // Locale.preferredLanguages holds BCP 47 tags such as "ja-JP" in priority
    // order, so the match uses the language component only. English is the
    // base language and answers for everything unsupported.
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

// @Observable is what makes a language change take effect without a restart:
// every view that read the selection through tr(_:ja:) redraws.
@Observable @MainActor
final class LanguageSetting {
    static let shared = LanguageSetting()

    var selection: AppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: AppLanguage.userDefaultsKey) }
    }

    private let defaults: UserDefaults

    // The parameter exists for tests, which pass a dedicated suite.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppLanguage.stored(in: defaults)
    }
}

@MainActor
func tr(_ english: String, ja japanese: String) -> String {
    switch LanguageSetting.shared.selection.resolved {
    case .english: english
    case .japanese: japanese
    }
}

// For strings built off the MainActor, such as
// LocalizedError.errorDescription. Reading UserDefaults directly means no
// observation, so a string already captured into @State keeps its old language
// after a switch — acceptable, because error displays are transient.
nonisolated func trStored(_ english: String, ja japanese: String) -> String {
    switch AppLanguage.stored().resolved {
    case .english: english
    case .japanese: japanese
    }
}
