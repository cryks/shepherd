// Verifies the HotkeyCombo contract (global-hotkey validity, display order,
// modifier mapping, key labels) and HotkeySetting persistence. UserDefaults
// uses a dedicated suite so the tests neither read nor pollute the settings of
// the machine they run on. Carbon registration itself is not exercised here:
// GlobalHotkeyCenter talks to the window server, which a test host cannot
// observe.

import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Shepherd

final class HotkeySettingTests: XCTestCase {
    // MARK: - HotkeyCombo validity

    func test修飾なしの文字キーはグローバルホットキーにできない() {
        let combo = HotkeyCombo(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: 0,
            keyLabel: "M"
        )
        XCTAssertFalse(combo.isValidGlobalHotkey)
    }

    func testShift単独もグローバルホットキーにできない() {
        let combo = HotkeyCombo(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(shiftKey),
            keyLabel: "M"
        )
        XCTAssertFalse(combo.isValidGlobalHotkey)
    }

    func testCommandControlOptionのいずれかがあれば有効() {
        for modifier in [cmdKey, controlKey, optionKey] {
            let combo = HotkeyCombo(
                keyCode: UInt32(kVK_ANSI_M),
                carbonModifiers: UInt32(modifier),
                keyLabel: "M"
            )
            XCTAssertTrue(combo.isValidGlobalHotkey, "modifier \(modifier)")
        }
    }

    func testファンクションキーは単独でも有効() {
        let combo = HotkeyCombo(
            keyCode: UInt32(kVK_F6),
            carbonModifiers: 0,
            keyLabel: "F6"
        )
        XCTAssertTrue(combo.isValidGlobalHotkey)
    }

    // MARK: - Display

    func test表示は固定順の修飾記号にキーラベルが続く() {
        let combo = HotkeyCombo(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey)
                | UInt32(optionKey) | UInt32(controlKey),
            keyLabel: "M"
        )
        XCTAssertEqual(combo.displayString, "⌃⌥⇧⌘M")
    }

    func testNSEvent修飾フラグはCarbonマスクへ対応する4種だけ写す() {
        XCTAssertEqual(
            HotkeyCombo.carbonModifiers(from: [.command, .shift]),
            UInt32(cmdKey) | UInt32(shiftKey)
        )
        // fn has no RegisterEventHotKey equivalent and must be dropped.
        XCTAssertEqual(HotkeyCombo.carbonModifiers(from: [.function]), 0)
        XCTAssertEqual(HotkeyCombo.carbonModifiers(from: []), 0)
    }

    func testキーラベルは特殊キーを記号にしそれ以外はレイアウト文字を大文字化する() {
        XCTAssertEqual(
            HotkeyCombo.keyLabel(keyCode: UInt32(kVK_Space), layoutCharacters: " "),
            "Space"
        )
        XCTAssertEqual(
            HotkeyCombo.keyLabel(keyCode: UInt32(kVK_UpArrow), layoutCharacters: "\u{F700}"),
            "↑"
        )
        XCTAssertEqual(
            HotkeyCombo.keyLabel(keyCode: UInt32(kVK_F1), layoutCharacters: "\u{F704}"),
            "F1"
        )
        XCTAssertEqual(
            HotkeyCombo.keyLabel(keyCode: UInt32(kVK_ANSI_M), layoutCharacters: "m"),
            "M"
        )
        XCTAssertEqual(
            HotkeyCombo.keyLabel(keyCode: 0xFFFF, layoutCharacters: nil),
            "?"
        )
    }

    // MARK: - Persistence

    @MainActor
    func test保存したComboは別インスタンスから読み戻せる() {
        let defaults = makeDefaults()
        let combo = HotkeyCombo(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(cmdKey) | UInt32(shiftKey),
            keyLabel: "M"
        )

        let setting = HotkeySetting(defaults: defaults)
        setting.menuPanelCombo = combo

        let reloaded = HotkeySetting(defaults: defaults)
        XCTAssertEqual(reloaded.menuPanelCombo, combo)
        XCTAssertNil(reloaded.monitorWindowCombo)
    }

    @MainActor
    func testNil代入で保存値が消える() {
        let defaults = makeDefaults()
        let setting = HotkeySetting(defaults: defaults)
        setting.monitorWindowCombo = HotkeyCombo(
            keyCode: UInt32(kVK_ANSI_P),
            carbonModifiers: UInt32(optionKey),
            keyLabel: "P"
        )

        setting.monitorWindowCombo = nil

        XCTAssertNil(defaults.data(forKey: HotkeyAction.toggleMonitorWindow.defaultsKey))
        XCTAssertNil(HotkeySetting(defaults: defaults).monitorWindowCombo)
    }

    @MainActor
    func test壊れた保存値は未割り当てとして読む() {
        let defaults = makeDefaults()
        defaults.set(
            Data("not json".utf8),
            forKey: HotkeyAction.toggleMenuPanel.defaultsKey
        )

        XCTAssertNil(HotkeySetting(defaults: defaults).menuPanelCombo)
    }

    @MainActor
    func testCombo変更とSuspend切り替えはOnChangeを発火する() {
        let setting = HotkeySetting(defaults: makeDefaults())
        var changeCount = 0
        setting.onChange = { changeCount += 1 }

        setting.menuPanelCombo = HotkeyCombo(
            keyCode: UInt32(kVK_ANSI_M),
            carbonModifiers: UInt32(cmdKey),
            keyLabel: "M"
        )
        setting.isSuspended = true
        setting.isSuspended = false

        XCTAssertEqual(changeCount, 3)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "HotkeySettingTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Pass only the Sendable suiteName to teardown; do not send the UserDefaults
        // instance across the actor boundary (avoids SendingRisksDataRace).
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}
