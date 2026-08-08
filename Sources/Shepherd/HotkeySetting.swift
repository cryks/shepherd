// The registrations go through Carbon rather than an NSEvent global monitor
// because RegisterEventHotKey needs no Accessibility permission and consumes
// the keystroke, so a registered combo does not also reach the frontmost app.

import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import OSLog

private let hotkeyLog = Logger(
    subsystem: "io.github.cryks.shepherd",
    category: "hotkeys"
)

// The rawValue doubles as the Carbon EventHotKeyID.id, so the values must stay
// unique and stable.
enum HotkeyAction: UInt32, CaseIterable {
    case toggleMenuPanel = 1
    case toggleMonitorWindow = 2

    var defaultsKey: String {
        switch self {
        case .toggleMenuPanel: "GlobalHotkeyMenuPanel"
        case .toggleMonitorWindow: "GlobalHotkeyMonitorWindow"
        }
    }
}

// keyCode and carbonModifiers are exactly the pair RegisterEventHotKey takes.
// keyLabel is resolved once, at record time, from the keyboard layout then
// active, so display needs no layout lookup; it goes stale if the user later
// switches layouts, but the hotkey stays on the same physical key.
struct HotkeyCombo: Equatable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    var displayString: String {
        Self.modifierSymbols(carbonModifiers: carbonModifiers) + keyLabel
    }

    // Plain keys and shift-only combos would shadow ordinary typing in every
    // app. Function keys are exempt because macOS treats them as standalone
    // shortcut keys.
    var isValidGlobalHotkey: Bool {
        if Self.functionKeyCodes.contains(keyCode) { return true }
        let required = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
        return carbonModifiers & required != 0
    }

    // ⌃⌥⇧⌘ is the fixed macOS display order.
    static func modifierSymbols(carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    // The remaining NSEvent flags (fn, caps lock, device-dependent bits) have
    // no RegisterEventHotKey equivalent, so they are dropped.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    // The uppercasing matters because letters record as their unshifted
    // lowercase form.
    static func keyLabel(keyCode: UInt32, layoutCharacters: String?) -> String {
        if let special = specialKeyLabels[keyCode] { return special }
        guard let layoutCharacters, !layoutCharacters.isEmpty else { return "?" }
        return layoutCharacters.uppercased()
    }

    static let functionKeyCodes: Set<UInt32> = Set(
        [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ].map(UInt32.init)
    )

    // NSEvent reports these keys as control characters or Private Use Area
    // codepoints (0xF700–), which draw as blanks or tofu.
    private static let specialKeyLabels: [UInt32: String] = {
        var labels: [UInt32: String] = [
            UInt32(kVK_Return): "↩",
            UInt32(kVK_ANSI_KeypadEnter): "⌤",
            UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Space): "Space",
            UInt32(kVK_Delete): "⌫",
            UInt32(kVK_ForwardDelete): "⌦",
            UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Home): "↖",
            UInt32(kVK_End): "↘",
            UInt32(kVK_PageUp): "⇞",
            UInt32(kVK_PageDown): "⇟",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_DownArrow): "↓",
            UInt32(kVK_UpArrow): "↑",
        ]
        let functionKeys = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]
        for (index, keyCode) in functionKeys.enumerated() {
            labels[UInt32(keyCode)] = "F\(index + 1)"
        }
        return labels
    }()
}

// @Observable redraws the settings tab, but GlobalHotkeyCenter is notified
// through onChange instead, because registration must also react to
// isSuspended, which flips while no view observes it.
@Observable @MainActor
final class HotkeySetting {
    static let shared = HotkeySetting()

    var menuPanelCombo: HotkeyCombo? {
        didSet {
            persist(menuPanelCombo, for: .toggleMenuPanel)
            onChange?()
        }
    }

    var monitorWindowCombo: HotkeyCombo? {
        didSet {
            persist(monitorWindowCombo, for: .toggleMonitorWindow)
            onChange?()
        }
    }

    // Raised while the settings recorder captures a combo: the center
    // unregisters everything so a key tried out there is not swallowed by its
    // current assignment. Not persisted.
    var isSuspended = false {
        didSet { onChange?() }
    }

    // Installed by GlobalHotkeyCenter.start, so the Carbon registrations
    // follow every mutation above.
    @ObservationIgnored var onChange: (() -> Void)?

    private let defaults: UserDefaults

    // The parameter exists for tests, which pass a dedicated suite. A missing
    // or undecodable blob loads as nil, so hand-edited defaults or a later
    // format change cannot break launch.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuPanelCombo = Self.load(.toggleMenuPanel, from: defaults)
        monitorWindowCombo = Self.load(.toggleMonitorWindow, from: defaults)
    }

    func combo(for action: HotkeyAction) -> HotkeyCombo? {
        switch action {
        case .toggleMenuPanel: menuPanelCombo
        case .toggleMonitorWindow: monitorWindowCombo
        }
    }

    private func persist(_ combo: HotkeyCombo?, for action: HotkeyAction) {
        guard let combo, let data = try? JSONEncoder().encode(combo) else {
            defaults.removeObject(forKey: action.defaultsKey)
            return
        }
        defaults.set(data, forKey: action.defaultsKey)
    }

    private static func load(
        _ action: HotkeyAction,
        from defaults: UserDefaults
    ) -> HotkeyCombo? {
        guard let data = defaults.data(forKey: action.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(HotkeyCombo.self, from: data)
    }
}

// The handler sits on GetEventDispatcherTarget of the main event loop, so its
// events arrive on the main thread.
@MainActor
final class GlobalHotkeyCenter {
    // Four-char code "SHEP". The handler checks it before mapping an ID, so a
    // stray hot-key event from elsewhere is not misread as ours.
    private static let signature: FourCharCode = 0x5348_4550

    private let setting: HotkeySetting
    private let perform: @MainActor (HotkeyAction) -> Void
    private var registrations: [HotkeyAction: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?

    init(
        setting: HotkeySetting,
        perform: @escaping @MainActor (HotkeyAction) -> Void
    ) {
        self.setting = setting
        self.perform = perform
    }

    // A second call keeps the handler already installed.
    func start() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                // The C callback carries no actor isolation, but a
                // dispatcher-target handler runs on the main thread.
                return MainActor.assumeIsolated {
                    Unmanaged<GlobalHotkeyCenter>.fromOpaque(userData)
                        .takeUnretainedValue()
                        .dispatch(hotKeyID)
                }
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else {
            hotkeyLog.error("InstallEventHandler failed: \(status)")
            return
        }
        setting.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    private func dispatch(_ id: EventHotKeyID) -> OSStatus {
        guard id.signature == Self.signature,
              let action = HotkeyAction(rawValue: id.id) else {
            return OSStatus(eventNotHandledErr)
        }
        perform(action)
        return noErr
    }

    // Rebuilding every registration keeps one code path for assign, clear,
    // suspend, and resume; with two hotkeys the cost does not matter.
    private func refresh() {
        for reference in registrations.values {
            UnregisterEventHotKey(reference)
        }
        registrations.removeAll()
        guard !setting.isSuspended else { return }
        for action in HotkeyAction.allCases {
            guard let combo = setting.combo(for: action) else { continue }
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                combo.keyCode,
                combo.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: action.rawValue),
                GetEventDispatcherTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                registrations[action] = reference
            } else {
                // Usually the combo is already claimed system-wide, for
                // example by a system shortcut. The assignment stays stored
                // and gets another try on the next refresh.
                hotkeyLog.error(
                    "RegisterEventHotKey \(combo.displayString, privacy: .public) failed: \(status)"
                )
            }
        }
    }
}
