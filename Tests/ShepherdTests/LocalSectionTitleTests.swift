// ローカルセクション見出し設定の解決 (standard / custom / hidden と空白フォールバック) と
// UserDefaults への永続化、FleetSourceSection への配線を検証する。
// UserDefaults は専用 suite を使い、実行マシンの設定を読まず・汚さない。
// 期待値の文字列は表示言語に依存するため、各テストが base 言語 (英語) へ固定する。

import Foundation
import XCTest
@testable import Shepherd

final class LocalSectionTitleTests: XCTestCase {
    @MainActor
    func test既定はStandardで既定名を返す() {
        withEnglish {
            let setting = LocalSectionTitleSetting(defaults: makeDefaults())
            XCTAssertEqual(setting.style, .standard)
            XCTAssertEqual(setting.customTitle, "")
            XCTAssertEqual(setting.localHeaderTitle, "This Mac")
        }
    }

    @MainActor
    func testCustomは入力した表記を返し空白だけなら既定名へ落とす() {
        withEnglish {
            let setting = LocalSectionTitleSetting(defaults: makeDefaults())
            setting.style = .custom

            setting.customTitle = "  MacBook Pro  "
            XCTAssertEqual(setting.localHeaderTitle, "MacBook Pro", "前後の空白が見出しに残る")

            setting.customTitle = "   "
            XCTAssertEqual(setting.localHeaderTitle, "This Mac")
        }
    }

    @MainActor
    func testHiddenは見出しなしを表すNilを返す() {
        let setting = LocalSectionTitleSetting(defaults: makeDefaults())
        setting.style = .hidden
        setting.customTitle = "MacBook Pro"
        XCTAssertNil(setting.localHeaderTitle)
    }

    @MainActor
    func test保存した設定を次回初期化で読み戻す() {
        let defaults = makeDefaults()
        let setting = LocalSectionTitleSetting(defaults: defaults)
        setting.style = .custom
        setting.customTitle = "MacBook Pro"

        let reloaded = LocalSectionTitleSetting(defaults: defaults)
        XCTAssertEqual(reloaded.style, .custom)
        XCTAssertEqual(reloaded.customTitle, "MacBook Pro")
    }

    @MainActor
    func test未知の保存値はStandardへ落とす() {
        let defaults = makeDefaults()
        defaults.set("garbage", forKey: LocalSectionTitleSetting.styleKey)
        let setting = LocalSectionTitleSetting(defaults: defaults)
        XCTAssertEqual(setting.style, .standard)
    }

    @MainActor
    func testローカルSectionのHeaderTitleは共有設定に従う() {
        withEnglish {
            let originalStyle = LocalSectionTitleSetting.shared.style
            let originalCustomTitle = LocalSectionTitleSetting.shared.customTitle
            defer {
                LocalSectionTitleSetting.shared.style = originalStyle
                LocalSectionTitleSetting.shared.customTitle = originalCustomTitle
            }

            let section = FleetSourceSection(
                localSource: MonitoredSource(localStore: Store(initialState: .disconnected))
            )

            LocalSectionTitleSetting.shared.style = .standard
            XCTAssertEqual(section.headerTitle, "This Mac")

            LocalSectionTitleSetting.shared.style = .custom
            LocalSectionTitleSetting.shared.customTitle = "MacBook Pro"
            XCTAssertEqual(section.headerTitle, "MacBook Pro")

            LocalSectionTitleSetting.shared.style = .hidden
            XCTAssertNil(section.headerTitle)
        }
    }

    // MARK: - ヘルパ

    /// テストごとに独立した UserDefaults suite。終了時に domain ごと削除する。
    private func makeDefaults() -> UserDefaults {
        let suiteName = "LocalSectionTitleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // teardown へは Sendable な suiteName だけを渡し、UserDefaults instance を
        // actor 境界越しに送らない (SendingRisksDataRace 回避)。
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// 見出し文字列の期待値を base 言語 (英語) で固定する。
    @MainActor
    private func withEnglish(_ body: () -> Void) {
        let original = LanguageSetting.shared.selection
        LanguageSetting.shared.selection = .english
        defer { LanguageSetting.shared.selection = original }
        body()
    }
}
