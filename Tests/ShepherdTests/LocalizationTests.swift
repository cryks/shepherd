// Verifies the display-language resolution rules and the persistence contract of the setting.
// System resolution is reproduced by injecting the OS preferred-language list, so the tests
// do not depend on the language settings of the machine they run on. UserDefaults uses a
// test-only suite to avoid polluting standard.

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
        // Unsupported languages are skipped; the next matching supported language is used.
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

        // Creating a fresh instance stands in for an app restart; the selection is restored from the stored value.
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
