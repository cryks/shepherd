// 表示言語の解決規則と設定の永続契約を検証する。
// system の解決は OS の優先言語リストを注入して再現し、実行マシンの言語設定に
// 依存しない。UserDefaults はテスト専用 suite を使い、standard を汚さない。

import Foundation
import XCTest
@testable import Shepherd

final class LocalizationTests: XCTestCase {
    func testSystemは優先言語リストの先頭一致で解決する() {
        XCTAssertEqual(
            ResolvedLanguage.systemPreferred(preferences: ["ja-JP", "en-US"]),
            .japanese
        )
        XCTAssertEqual(
            ResolvedLanguage.systemPreferred(preferences: ["en-GB", "ja-JP"]),
            .english
        )
        // 非対応言語は飛ばして、次に一致した対応言語を使う。
        XCTAssertEqual(
            ResolvedLanguage.systemPreferred(preferences: ["fr-FR", "ja"]),
            .japanese
        )
    }

    func testSystemは対応言語が無ければ英語に落ちる() {
        XCTAssertEqual(
            ResolvedLanguage.systemPreferred(preferences: ["fr-FR", "de-DE"]),
            .english
        )
        XCTAssertEqual(ResolvedLanguage.systemPreferred(preferences: []), .english)
    }

    func test明示選択はOSの優先言語に関係なく固定される() {
        XCTAssertEqual(AppLanguage.english.resolved, .english)
        XCTAssertEqual(AppLanguage.japanese.resolved, .japanese)
    }

    func test保存値の読み出しは未知の値と未保存をSystemへ落とす() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguage.stored(in: defaults), .system)

        defaults.set("ja", forKey: AppLanguage.userDefaultsKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .japanese)

        defaults.set("klingon", forKey: AppLanguage.userDefaultsKey)
        XCTAssertEqual(AppLanguage.stored(in: defaults), .system)
    }

    @MainActor
    func test選択の変更をUserDefaultsへ保存し再起動後も読み戻す() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let setting = LanguageSetting(defaults: defaults)
        XCTAssertEqual(setting.selection, .system)

        setting.selection = .english
        XCTAssertEqual(defaults.string(forKey: AppLanguage.userDefaultsKey), "en")

        // 別インスタンスの生成をアプリ再起動と見立て、保存値から選択を復元する。
        let restarted = LanguageSetting(defaults: defaults)
        XCTAssertEqual(restarted.selection, .english)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "LocalizationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
