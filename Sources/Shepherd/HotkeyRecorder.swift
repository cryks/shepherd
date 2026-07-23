// Shortcut recorder control for the Hotkeys settings tab. Clicking the field
// starts capturing: a local key monitor swallows the next key press and stores
// it as a HotkeyCombo through the binding. While recording, held modifiers are
// echoed live, Escape cancels, plain Delete clears the assignment, and any
// modified key commits (subject to HotkeyCombo.isValidGlobalHotkey; invalid
// presses are swallowed and capture continues). HotkeySetting.isSuspended is
// raised for the duration so keys tried out here are not consumed by their
// current system-wide registration.

import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyRecorderField: View {
    @Binding var combo: HotkeyCombo?

    @State private var isRecording = false
    /// Modifiers currently held during recording, echoed as a live preview.
    @State private var heldModifiers: NSEvent.ModifierFlags = []
    /// Non-nil exactly while recording; removing it is what stops capture.
    @State private var keyMonitor: Any?

    /// The four modifiers a hotkey can carry. NSEvent reports more flags
    /// (fn, caps lock, device-dependent bits); everything else is ignored both
    /// for the preview and for the recorded combo.
    private static let consideredModifiers: NSEvent.ModifierFlags =
        [.command, .option, .control, .shift]

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggleRecording) {
                Text(label)
                    .foregroundStyle(labelStyle)
                    .frame(minWidth: 130)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        isRecording
                            ? Color.accentColor
                            : Color(nsColor: .separatorColor)
                    )
            )

            Button {
                combo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(tr("Remove shortcut", ja: "ショートカットを削除"))
            // Hidden instead of conditionally inserted so assigning or
            // clearing does not shift the field's horizontal position.
            .opacity(combo != nil && !isRecording ? 1 : 0)
            .disabled(combo == nil || isRecording)
        }
        // The Settings window can close mid-recording; releasing the monitor
        // here also drops isSuspended so registrations come back.
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording {
            let symbols = HotkeyCombo.modifierSymbols(
                carbonModifiers: HotkeyCombo.carbonModifiers(from: heldModifiers)
            )
            return symbols.isEmpty ? tr("Type shortcut…", ja: "キーを入力…") : symbols
        }
        return combo?.displayString
            ?? tr("Record Shortcut", ja: "ショートカットを記録")
    }

    private var labelStyle: some ShapeStyle {
        if isRecording { return AnyShapeStyle(.secondary) }
        return combo == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        guard keyMonitor == nil else { return }
        isRecording = true
        heldModifiers = []
        HotkeySetting.shared.isSuspended = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged]
        ) { event in
            handle(event)
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        guard isRecording else { return }
        isRecording = false
        heldModifiers = []
        HotkeySetting.shared.isSuspended = false
    }

    /// Consumes every key event while recording (returns nil) so presses do
    /// not fall through to the window — typing into the recorder must not
    /// trigger buttons or field editing behind it.
    private func handle(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .flagsChanged:
            heldModifiers = event.modifierFlags.intersection(Self.consideredModifiers)
            return nil
        case .keyDown:
            let modifiers = event.modifierFlags.intersection(Self.consideredModifiers)
            if modifiers.isEmpty, event.keyCode == UInt16(kVK_Escape) {
                stopRecording()
                return nil
            }
            if modifiers.isEmpty, event.keyCode == UInt16(kVK_Delete) {
                combo = nil
                stopRecording()
                return nil
            }
            let candidate = HotkeyCombo(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: HotkeyCombo.carbonModifiers(from: modifiers),
                keyLabel: HotkeyCombo.keyLabel(
                    keyCode: UInt32(event.keyCode),
                    layoutCharacters: event.charactersIgnoringModifiers
                )
            )
            guard candidate.isValidGlobalHotkey else { return nil }
            combo = candidate
            stopRecording()
            return nil
        default:
            return event
        }
    }
}
