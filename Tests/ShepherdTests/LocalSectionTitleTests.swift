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
            XCTAssertEqual(setting.localTitleWithRemotes, "This Mac")
        }
    }

    @MainActor
    func testCustomは入力した表記を返し空白だけなら既定名へ落とす() {
        withEnglish {
            let setting = LocalSectionTitleSetting(defaults: makeDefaults())
            setting.style = .custom

            setting.customTitle = "  MacBook Pro  "
            XCTAssertEqual(setting.localTitleWithRemotes, "MacBook Pro", "前後の空白が見出しに残る")

            setting.customTitle = "   "
            XCTAssertEqual(setting.localTitleWithRemotes, "This Mac")
        }
    }

    @MainActor
    func testHiddenは見出しなしを表すNilを返す() {
        let setting = LocalSectionTitleSetting(defaults: makeDefaults())
        setting.style = .hidden
        setting.customTitle = "MacBook Pro"
        XCTAssertNil(setting.localTitleWithRemotes)
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

    // MARK: - Helpers

    // A per-test suite keeps the machine's own settings out of the results.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "LocalSectionTitleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Rebuild from the Sendable suiteName instead of capturing `defaults`, which
        // would cross an actor boundary and trip SendingRisksDataRace.
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    // The expected titles are the base-language strings, so pin the language.
    @MainActor
    private func withEnglish(_ body: () -> Void) {
        let original = LanguageSetting.shared.selection
        LanguageSetting.shared.selection = .english
        defer { LanguageSetting.shared.selection = original }
        body()
    }
}
