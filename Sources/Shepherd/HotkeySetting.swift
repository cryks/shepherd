// Global hotkey preferences and their system-wide registration. Two app-wide
// shortcuts exist: one toggles the menu bar panel, one toggles the pop-out
// monitor window. HotkeySetting owns persistence (one JSON blob per action in
// UserDefaults) and observability for the settings UI; GlobalHotkeyCenter owns
// the Carbon side (RegisterEventHotKey) and maps incoming hot-key events back
// to HotkeyAction for the closure installed by ShepherdApp. Carbon is used
// instead of an NSEvent global monitor because RegisterEventHotKey needs no
// Accessibility permission and consumes the keystroke, so a registered combo
// does not also reach the frontmost app.

import AppKit
import Carbon.HIToolbox
import Foundation
import Observation
import OSLog

private let hotkeyLog = Logger(
    subsystem: "io.github.cryks.shepherd",
    category: "hotkeys"
)

/// App-wide actions a global hotkey can trigger. The rawValue doubles as the
/// Carbon EventHotKeyID.id, so values must stay unique and stable.
enum HotkeyAction: UInt32, CaseIterable {
    case toggleMenuPanel = 1
    case toggleMonitorWindow = 2

    /// UserDefaults key holding this action's combo as a JSON blob.
    var defaultsKey: String {
        switch self {
        case .toggleMenuPanel: "GlobalHotkeyMenuPanel"
        case .toggleMonitorWindow: "GlobalHotkeyMonitorWindow"
        }
    }
}

/// One recorded keyboard shortcut. keyCode is the layout-independent virtual
/// key code and carbonModifiers the Carbon modifier mask — exactly the pair
/// RegisterEventHotKey takes. keyLabel is the user-visible key name captured
/// at record time from the then-active keyboard layout; storing it means
/// display never needs a layout lookup, at the cost of going stale if the user
/// later switches layouts (acceptable: the hotkey stays on the same physical
/// key either way).
struct HotkeyCombo: Equatable, Codable {
    let keyCode: UInt32
    let carbonModifiers: UInt32
    let keyLabel: String

    /// Modifier symbols followed by the key label, e.g. "⌃⌥⇧⌘M".
    var displayString: String {
        Self.modifierSymbols(carbonModifiers: carbonModifiers) + keyLabel
    }

    /// Whether the combo is safe to claim system-wide. Plain keys and
    /// shift-only combos would shadow ordinary typing in every app, so a
    /// command, control, or option modifier is required — except for function
    /// keys, which macOS treats as standalone shortcut keys.
    var isValidGlobalHotkey: Bool {
        if Self.functionKeyCodes.contains(keyCode) { return true }
        let required = UInt32(cmdKey) | UInt32(controlKey) | UInt32(optionKey)
        return carbonModifiers & required != 0
    }

    /// Modifier symbols in the fixed macOS display order ⌃⌥⇧⌘.
    static func modifierSymbols(carbonModifiers: UInt32) -> String {
        var symbols = ""
        if carbonModifiers & UInt32(controlKey) != 0 { symbols += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { symbols += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { symbols += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { symbols += "⌘" }
        return symbols
    }

    /// Maps the four hotkey-relevant NSEvent modifiers to the Carbon mask.
    /// Other NSEvent flags (fn, caps lock, device-dependent bits) have no
    /// RegisterEventHotKey equivalent and are dropped.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        return mask
    }

    /// Display label for a key. Keys whose layout characters are control or
    /// private-use codepoints (arrows, function keys, delete, …) come from the
    /// fixed symbol map; everything else uses the layout-resolved characters
    /// the recorder captured, uppercased (letters record as their unshifted
    /// lowercase form).
    static func keyLabel(keyCode: UInt32, layoutCharacters: String?) -> String {
        if let special = specialKeyLabels[keyCode] { return special }
        guard let layoutCharacters, !layoutCharacters.isEmpty else { return "?" }
        return layoutCharacters.uppercased()
    }

    /// Keys allowed as a hotkey without any modifier.
    static let functionKeyCodes: Set<UInt32> = Set(
        [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
            kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15,
            kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ].map(UInt32.init)
    )

    /// Labels for keys that produce no printable characters. NSEvent reports
    /// them as control characters or Private Use Area codepoints (0xF700–),
    /// which would render as blanks or tofu if displayed directly.
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

/// The sole writer of the hotkey preferences. Being @Observable, the settings
/// tab redraws when a combo changes; GlobalHotkeyCenter is notified through
/// onChange instead, because registration must also react to isSuspended,
/// which flips while no view is observing.
@Observable @MainActor
final class HotkeySetting {
    static let shared = HotkeySetting()

    /// Combo that toggles the menu bar panel. nil means unassigned.
    /// Persisted to UserDefaults on every write.
    var menuPanelCombo: HotkeyCombo? {
        didSet {
            persist(menuPanelCombo, for: .toggleMenuPanel)
            onChange?()
        }
    }

    /// Combo that toggles the pop-out monitor window. nil means unassigned.
    /// Persisted to UserDefaults on every write.
    var monitorWindowCombo: HotkeyCombo? {
        didSet {
            persist(monitorWindowCombo, for: .toggleMonitorWindow)
            onChange?()
        }
    }

    /// True while the settings recorder is capturing a new combo. Not
    /// persisted. The center unregisters everything for the duration so keys
    /// tried out in the recorder are not swallowed by their current assignment.
    var isSuspended = false {
        didSet { onChange?() }
    }

    /// Installed by GlobalHotkeyCenter.start and called after every mutation
    /// above, so Carbon registrations always match the stored combos.
    @ObservationIgnored var onChange: (() -> Void)?

    private let defaults: UserDefaults

    /// - Parameter defaults: Storage destination. The app proper uses
    ///   standard; tests pass a dedicated suite. A missing or undecodable
    ///   stored blob reads as nil (unassigned), so hand-edited defaults or a
    ///   future format change cannot break launch.
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

/// Owns the Carbon hot-key registrations for the app's lifetime. start()
/// installs one dispatcher-target event handler and re-registers combos
/// whenever HotkeySetting changes. Events arrive on the main thread because
/// the handler is installed on GetEventDispatcherTarget of the main event
/// loop.
@MainActor
final class GlobalHotkeyCenter {
    /// Four-char code "SHEP" tagging this app's EventHotKeyIDs. The handler
    /// checks it before mapping the ID, so a stray hot-key event with another
    /// signature is not misread as ours.
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

    /// Installs the Carbon event handler, hooks setting changes, and registers
    /// the stored combos. Duplicate calls keep the existing handler.
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
                // The C callback carries no actor isolation, but dispatcher-
                // target handlers run on the main thread.
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

    /// Rebuilds every registration from the stored combos. Unregistering and
    /// re-registering everything keeps a single code path for assign, clear,
    /// suspend, and resume; with two hotkeys the cost is irrelevant.
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
                // Typically the combo is already claimed system-wide (for
                // example by a system shortcut). The assignment stays stored
                // and is retried on the next refresh.
                hotkeyLog.error(
                    "RegisterEventHotKey \(combo.displayString, privacy: .public) failed: \(status)"
                )
            }
        }
    }
}
