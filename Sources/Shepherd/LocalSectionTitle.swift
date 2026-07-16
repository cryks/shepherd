// ローカルセクション (この Mac) の見出し表示設定を所有する。保存するのは
// UserDefaults の 2 キー (表示方法とカスタム表記) だけで、見出し文字列の解決
// (custom の空白フォールバック、hidden の nil) もここに集約する。
// 変えるのは見出し行の表示だけで、ローカルの監視 runtime・メニューバーの状態集約・
// agent 行の表示には関与しない。

import Foundation
import Observation

/// ローカルセクション見出しの表示方法。設定 (一般タブ) の Picker で選ぶ。
enum LocalSectionTitleStyle: String, CaseIterable, Identifiable, Sendable {
    /// 既定名 (This Mac / この Mac) を見出しに使う。
    case standard
    /// LocalSectionTitleSetting.customTitle を見出しに使う。
    case custom
    /// リモートセクションが並んでいても、ローカルの見出し行を描画しない。
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

/// ローカルセクション見出し設定の唯一の書き込み元。@Observable なので、body 評価中に
/// style や localHeaderTitle を読んだ view (SourceList、Settings) は設定変更で再描画される。
@Observable @MainActor
final class LocalSectionTitleSetting {
    static let shared = LocalSectionTitleSetting()

    /// UserDefaults の保存キー。表示方法は rawValue、カスタム表記は文字列をそのまま保存する。
    static let styleKey = "LocalSectionTitleStyle"
    static let customTitleKey = "LocalSectionCustomTitle"

    /// 見出しの表示方法。書き込みと同時に UserDefaults へ保存する。
    var style: LocalSectionTitleStyle {
        didSet { defaults.set(style.rawValue, forKey: Self.styleKey) }
    }

    /// custom スタイルで使う表記。style と独立して保存し、他のスタイルへ切り替えても
    /// 入力済みの表記が消えない。
    var customTitle: String {
        didSet { defaults.set(customTitle, forKey: Self.customTitleKey) }
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: 保存先。アプリ本体は standard を使い、テストは専用 suite を渡す。
    /// 未保存または未知の rawValue は standard として扱い、手編集された defaults や
    /// 将来の保存形式変更で起動を壊さない。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        style = defaults.string(forKey: Self.styleKey)
            .flatMap(LocalSectionTitleStyle.init(rawValue:)) ?? .standard
        customTitle = defaults.string(forKey: Self.customTitleKey) ?? ""
    }

    /// ローカルセクションの見出し文字列。nil は見出し行を描画しない指示 (hidden)。
    /// custom で空白だけの表記は既定名へ落とし、空の見出し行が残らないようにする。
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

    /// 既定の見出し。custom の空白フォールバックと設定画面の placeholder が共有する。
    static var defaultTitle: String { tr("This Mac", ja: "この Mac") }
}
