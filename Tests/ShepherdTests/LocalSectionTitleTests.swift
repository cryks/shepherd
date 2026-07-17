// Verifies resolution of the local-section title setting (standard / custom / hidden plus
// the whitespace fallback), its persistence to UserDefaults, and the wiring into
// FleetSourceSection. UserDefaults uses a dedicated suite so the tests neither read nor
// pollute the settings of the machine they run on. Expected strings depend on the display
// language, so each test pins it to the base language (English).

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

    // MARK: - Helpers

    /// An isolated UserDefaults suite per test. The whole domain is removed at teardown.
    private func makeDefaults() -> UserDefaults {
        let suiteName = "LocalSectionTitleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Pass only the Sendable suiteName to teardown; do not send the UserDefaults
        // instance across the actor boundary (avoids SendingRisksDataRace).
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    /// Pins the expected title strings to the base language (English).
    @MainActor
    private func withEnglish(_ body: () -> Void) {
        let original = LanguageSetting.shared.selection
        LanguageSetting.shared.selection = .english
        defer { LanguageSetting.shared.selection = original }
        body()
    }
}
