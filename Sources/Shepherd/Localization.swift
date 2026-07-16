// 表示言語の設定と解決を所有する。文字列表は持たず、各表示箇所が tr(_:ja:) で
// 英語 (base) と日本語を並記する。.lproj / Localizable.strings は使わない。
// この app は Xcode プロジェクトを持たず swift build + 手組みバンドルで完結するため、
// bundle の localization 機構ではなく、コンパイラが全対応言語の訳文を強制できる
// 関数 signature を採用する。言語を追加する手順:
//   1. ResolvedLanguage に case を足す
//   2. tr / trStored の signature に引数を足す (全呼び出し箇所がコンパイルエラーになる)
//   3. エラーになった箇所へ訳文を足し、AppLanguage と設定 Picker に選択肢を足す
// 保存するのは AppLanguage.rawValue (UserDefaults "AppLanguage") だけ。

import Foundation
import Observation

/// 設定 (一般タブ) で選ぶ表示言語。`system` は macOS の優先言語リストから
/// 対応言語を選び、どの優先言語にも対応言語が無ければ英語に落とす。
enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case japanese = "ja"

    var id: String { rawValue }

    /// UserDefaults の保存キー。LanguageSetting (書き込み) と stored(in:) (読み出し) が共有する。
    static let userDefaultsKey = "AppLanguage"

    /// 保存値を読む。未保存または未知の rawValue は system として扱い、
    /// 手編集された defaults や将来の保存形式変更で起動を壊さない。
    nonisolated static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        guard let rawValue = defaults.string(forKey: userDefaultsKey) else { return .system }
        return AppLanguage(rawValue: rawValue) ?? .system
    }

    /// system を OS 優先言語で解決した、実際に表示へ使う言語。
    nonisolated var resolved: ResolvedLanguage {
        switch self {
        case .system: .systemPreferred()
        case .english: .english
        case .japanese: .japanese
        }
    }

    /// 設定 Picker の選択肢名。system だけ UI 言語に追従し、各言語は自分の言語名で
    /// 固定する (今の UI 言語を読めない利用者でも自分の言語を見つけられるように)。
    @MainActor var displayName: String {
        switch self {
        case .system: tr("System", ja: "システム")
        case .english: "English"
        case .japanese: "日本語"
        }
    }
}

/// system 解決後の表示言語。tr(_:ja:) の switch 対象で、対応言語 1 つにつき 1 case。
enum ResolvedLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case japanese = "ja"

    /// macOS の優先言語リスト ("ja-JP" のような BCP 47 タグ、優先度順) から
    /// 対応言語を選ぶ。言語部分だけで照合し、最初に一致した言語を返す。
    /// 一致が無ければ英語 (base 言語)。
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

/// 言語設定の唯一の書き込み元。@Observable なので、body 評価中に tr(_:ja:) 経由で
/// selection を読んだ view は設定変更で再描画され、言語切り替えが再起動なしで反映される。
@Observable @MainActor
final class LanguageSetting {
    static let shared = LanguageSetting()

    /// 現在の選択。書き込みと同時に UserDefaults へ保存する。
    var selection: AppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: AppLanguage.userDefaultsKey) }
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: 保存先。アプリ本体は standard を使い、テストは専用 suite を渡す。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppLanguage.stored(in: defaults)
    }
}

/// 表示文字列の言語切り替え。英語を base とし、呼び出し箇所に全対応言語の訳文を並記する。
/// LanguageSetting.shared を観測するため、view の body から (直接または表示用 computed
/// property 経由で) 呼ばれた文字列は言語変更で即座に描き直される。
@MainActor
func tr(_ english: String, ja japanese: String) -> String {
    switch LanguageSetting.shared.selection.resolved {
    case .english: english
    case .japanese: japanese
    }
}

/// tr の nonisolated 版。LocalizedError.errorDescription など MainActor 外から呼びうる
/// 文字列用に、UserDefaults の保存値を直読みする。観測されないため、@State 等へ
/// 取り込み済みのエラー文字列は言語切り替えで再翻訳されない (エラー表示は一時的なので許容)。
nonisolated func trStored(_ english: String, ja japanese: String) -> String {
    switch AppLanguage.stored().resolved {
    case .english: english
    case .japanese: japanese
    }
}
