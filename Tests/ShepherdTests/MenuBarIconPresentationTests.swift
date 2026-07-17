// Verifies the contract for what blinks in the menu bar (and only there).
// Covers the visibility-phase decision derived from state, blink setting, and phase
// (the hidden phase swaps in a fully transparent image), and additionally checks, on a
// short cycle, that the app-owned clock advances the phase outside the lifecycle of the
// MenuBarExtra label.
// Reading the blink setting uses a test-only UserDefaults suite to avoid polluting standard.

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

    /// Contract: with the blink setting off, blocked / done keep showing the circle in both phases.
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

    /// Contract: the unstored default is on (blinking), and values written by the Toggle read back.
    func testBlinkEnabledDefaultsToTrueAndReadsStoredValue() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(MenuBarIconPresentation.blinkEnabled(in: defaults))

        defaults.set(false, forKey: MenuBarIconPresentation.blinkEnabledKey)
        XCTAssertFalse(MenuBarIconPresentation.blinkEnabled(in: defaults))

        defaults.set(true, forKey: MenuBarIconPresentation.blinkEnabledKey)
        XCTAssertTrue(MenuBarIconPresentation.blinkEnabled(in: defaults))
    }

    /// Contract: the image swapped in during the hidden phase does not change the status item's width.
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
