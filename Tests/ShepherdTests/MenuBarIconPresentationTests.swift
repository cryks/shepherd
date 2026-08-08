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

    func testBlinkEnabledDefaultsToTrueAndReadsStoredValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MenuBarIconPresentation.blinkEnabled(in: defaults))

        defaults.set(false, forKey: MenuBarIconPresentation.blinkEnabledKey)
        XCTAssertFalse(MenuBarIconPresentation.blinkEnabled(in: defaults))

        defaults.set(true, forKey: MenuBarIconPresentation.blinkEnabledKey)
        XCTAssertTrue(MenuBarIconPresentation.blinkEnabled(in: defaults))
    }

    // A hidden phase of a different size would shift the whole menu bar on every blink.
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
