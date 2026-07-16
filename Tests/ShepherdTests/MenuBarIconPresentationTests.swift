// メニューバーだけに適用する点滅対象の契約を検証する。
// 状態・点滅設定・フェーズからの表示フェーズ判定 (非表示フェーズは全透明画像への
// 差し替え) に加え、App が所有するクロックが MenuBarExtra ラベルのライフサイクル外で
// フェーズを進めることを短い周期で検証する。
// 点滅設定の読み出しはテスト専用 suite の UserDefaults を使い、standard を汚さない。

import XCTest
@testable import Shepherd

final class MenuBarIconPresentationTests: XCTestCase {
    func testOnlyDoneAndBlockedBlink() {
        XCTAssertFalse(MenuBarIconPresentation.shouldBlink(.disconnected))
        XCTAssertFalse(MenuBarIconPresentation.shouldBlink(.quiet))
        XCTAssertFalse(MenuBarIconPresentation.shouldBlink(.working))
        XCTAssertTrue(MenuBarIconPresentation.shouldBlink(.done))
        XCTAssertTrue(MenuBarIconPresentation.shouldBlink(.blocked))
    }

    func testDoneAndBlockedAlternateBetweenVisibleAndHiddenPhases() {
        for state in [MenuBarState.done, .blocked] {
            XCTAssertTrue(
                MenuBarIconPresentation.showsStatusShape(
                    for: state, blinkEnabled: true, blinkVisible: true
                )
            )
            XCTAssertFalse(
                MenuBarIconPresentation.showsStatusShape(
                    for: state, blinkEnabled: true, blinkVisible: false
                )
            )
        }
    }

    func testOtherStatesRemainVisibleInBothPhases() {
        for state in [MenuBarState.disconnected, .quiet, .working] {
            XCTAssertTrue(
                MenuBarIconPresentation.showsStatusShape(
                    for: state, blinkEnabled: true, blinkVisible: true
                )
            )
            XCTAssertTrue(
                MenuBarIconPresentation.showsStatusShape(
                    for: state, blinkEnabled: true, blinkVisible: false
                )
            )
        }
    }

    /// 点滅設定 OFF では blocked / done も両フェーズで丸を表示し続ける契約。
    func testBlinkSettingOffKeepsStatusShapeInBothPhases() {
        for state in [MenuBarState.done, .blocked] {
            XCTAssertTrue(
                MenuBarIconPresentation.showsStatusShape(
                    for: state, blinkEnabled: false, blinkVisible: true
                )
            )
            XCTAssertTrue(
                MenuBarIconPresentation.showsStatusShape(
                    for: state, blinkEnabled: false, blinkVisible: false
                )
            )
        }
    }

    /// 未保存のデフォルトが ON (点滅する) で、Toggle の書き込みを読み戻せる契約。
    func testBlinkEnabledDefaultsToTrueAndReadsStoredValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MenuBarIconPresentation.blinkEnabled(in: defaults))

        defaults.set(false, forKey: MenuBarIconPresentation.blinkEnabledKey)
        XCTAssertFalse(MenuBarIconPresentation.blinkEnabled(in: defaults))

        defaults.set(true, forKey: MenuBarIconPresentation.blinkEnabledKey)
        XCTAssertTrue(MenuBarIconPresentation.blinkEnabled(in: defaults))
    }

    /// 非表示フェーズの差し替え先がステータス項目の幅を変えない契約。
    @MainActor
    func testBlinkHiddenSharesCanvasWithStatusShapes() {
        XCTAssertEqual(StatusIcons.blinkHidden.size, StatusIcons.blocked.size)
    }

    @MainActor
    func testAppOwnedClockAdvancesWhileBlinking() async {
        let clock = MenuBarBlinkClock(phaseDuration: .milliseconds(10)) { true }
        clock.start()
        defer { clock.stop() }

        let reachedHiddenPhase = await waitUntil { !clock.blinkVisible }

        XCTAssertTrue(reachedHiddenPhase)
    }

    @MainActor
    func testAppOwnedClockRestoresVisiblePhaseOutsideBlinkingState() async {
        var shouldBlink = true
        let clock = MenuBarBlinkClock(phaseDuration: .milliseconds(10)) { shouldBlink }
        clock.start()
        defer { clock.stop() }

        let reachedHiddenPhase = await waitUntil { !clock.blinkVisible }
        XCTAssertTrue(reachedHiddenPhase)
        shouldBlink = false

        let returnedToVisiblePhase = await waitUntil { clock.blinkVisible }
        XCTAssertTrue(returnedToVisiblePhase)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "MenuBarIconPresentationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}
