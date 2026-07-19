// Panel opened by clicking the menu bar item (MenuBarExtra's .window style).
// NSMenu cannot render multi-line items, so a SwiftUI view is presented
// directly instead of a native menu. The same AgentRow as the monitor window
// is laid out, separated by endpoint and workspace headers, with action items
// styled after NSMenu items (open/close the monitor window, settings, quit) at
// the bottom. MenuBarExtra manages opening and closing the panel itself; here
// the panel is closed explicitly via dismiss after actions such as a row click.

import AppKit
import SwiftUI

struct MenuPanel: View {
    @Bindable var store: FleetStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var remoteMutationError: String?

    var body: some View {
        VStack(spacing: 0) {
            content
            VStack(spacing: 0) {
                Divider()
                footer
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                chromeHeight = height
            }
        }
        .frame(width: 340)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                SourceList(
                    sections: store.sourceSections,
                    style: .menu,
                    onRemoteEnabledChange: setRemoteEnabled
                ) { pane in
                    store.focus(pane, sourceID: .local)
                    dismiss()
                }

                if let remoteMutationError {
                    Text(remoteMutationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 17)
                        .padding(.bottom, 8)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                listHeight = height
            }
        }
        .frame(height: min(listHeight == 0 ? 56 : listHeight, maxListHeight))
        .background(PanelMaxHeightReader { height in
            panelMaxHeight = height
        })
    }

    /// Measured list height. MenuBarExtra's window sizes the panel from the
    /// view's ideal size, but a ScrollView has no ideal height and collapses to
    /// 0, so the content's actual size is measured and given to the ScrollView
    /// as its height (scrolling once the cap is exceeded). The frame uses a
    /// 56pt bootstrap height only until this becomes nonzero; keeping that
    /// minimum after measurement leaves blank space below short empty states.
    @State private var listHeight: CGFloat = 0

    /// Maximum height the whole panel can take: the distance from the panel's
    /// top edge (just below the menu bar) to the bottom of screen.visibleFrame
    /// (the screen's bottom edge excluding the Dock), measured from the NSWindow
    /// by PanelMaxHeightReader. nil during the first layout before the view is
    /// attached to a window.
    @State private var panelMaxHeight: CGFloat?

    /// Measured height of everything but the list (divider + footer). What
    /// remains after subtracting this from the panel's maximum height is
    /// allocated to the list.
    @State private var chromeHeight: CGFloat = 0

    /// Height cap for the list. The list grows until the panel reaches the
    /// bottom of the screen; whatever still does not fit is left to the
    /// ScrollView's scrolling. Until the panel's maximum height has been
    /// measured, the first layout opens with a conservative fixed value that
    /// stays on screen (replaced by the measured value right after display).
    private var maxListHeight: CGFloat {
        guard let panelMaxHeight else { return 440 }
        return max(panelMaxHeight - chromeHeight, 56)
    }

    private func setRemoteEnabled(_ id: HerdrSourceID, _ isEnabled: Bool) {
        do {
            try store.setRemoteEnabled(id: id, isEnabled: isEnabled)
            remoteMutationError = nil
        } catch {
            remoteMutationError = error.localizedDescription
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuItem(
                store.monitorWindowVisible
                    ? tr("Close Pop-Out Window", ja: "ポップアウトウィンドウを閉じる")
                    : tr("Pop Out as Window", ja: "ウィンドウとしてポップアウト")
            ) {
                if store.monitorWindowVisible {
                    dismissWindow(id: monitorWindowId)
                } else {
                    openWindow(id: monitorWindowId)
                    // An LSUIElement app does not come to the front when it opens a window, so activate explicitly.
                    NSApp.activate()
                }
                dismiss()
            }
            MenuSeparator()
            MenuItem(tr("Settings…", ja: "設定…")) {
                openSettings()
                // An LSUIElement app does not come to the front when it opens a window, so activate explicitly.
                NSApp.activate()
                dismiss()
            }
            MenuItem(tr("Quit Shepherd", ja: "Shepherd を終了")) {
                store.stop()
                NSApp.terminate(nil)
            }
        }
        // Each MenuItem carries its own horizontal padding as the highlight
        // inset (only vertical padding is applied here so the MenuSeparator can
        // span the full panel width).
        .padding(.vertical, 5)
    }
}

/// Button styled after an NSMenu item. The panel uses the .window style and
/// cannot use NSMenu, so the hover appearance is matched to the native menu's
/// selected state (accent-color background + selected foreground color) so it
/// reads as a menu item.
/// Dimensions match measurements of the native NSMenu on macOS 26: the
/// highlight is inset 5pt from the panel edge, the text a further 12pt from
/// the highlight's left edge, and the item is about 24pt tall.
/// The 9pt highlight corner radius is the concentric value: the OS draws the
/// MenuBarExtra window panel with a corner radius of about 14pt in circular
/// terms (larger than NSMenu's roughly 10pt), minus the 5pt inset. Concentric
/// radii keep the distance between the two corner curves at 5pt everywhere, so
/// the panel corner and the highlight corner look parallel. The style is
/// .continuous to match the curve family of the continuous corners (a curve
/// whose tails rise gradually) the OS uses for the panel's corners.
private struct MenuItem: View {
    let title: String
    let action: () -> Void

    @State private var isHighlighted = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isHighlighted
                ? Color(nsColor: .selectedMenuItemTextColor)
                : Color.primary
        )
        .background(
            isHighlighted
                ? Color(nsColor: .selectedContentBackgroundColor)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .padding(.horizontal, 5)
        .onHover { isHighlighted = $0 }
    }
}

/// Equivalent of an NSMenu separator. The native NSMenu separator is drawn
/// across the full menu width without insets, so this has no horizontal padding.
private struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.vertical, 5)
    }
}

/// Measures and reports, from the NSWindow hosting the panel, the maximum
/// height the panel can take when extended to the bottom of the screen. A
/// MenuBarExtra window panel is pinned just below the menu bar at its top edge
/// and grows only downward, so the available height runs from the window's top
/// edge (frame.maxY) to the bottom of screen.visibleFrame (the screen's bottom
/// edge excluding the Dock). SwiftUI cannot touch the window, so this is picked
/// up via NSViewRepresentable.
private struct PanelMaxHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onMaxHeightChange = onChange
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {}
}

/// NSView that watches window attachment and movement and reports the maximum
/// height. At viewDidMoveToWindow the panel's positioning may not be finished
/// yet, so the frame is read one tick later. didMove / didChangeScreen are
/// additionally subscribed because with menu bars on multiple displays the same
/// window moves to another screen and is redisplayed, so the value is
/// recomputed on the destination screen each time the panel is reopened. When
/// the panel grows downward, the origin also moves and didMove fires, but the
/// top edge (maxY) does not change, so the reported value stays the same and no
/// relayout loop occurs.
private final class WindowObservingView: NSView {
    var onMaxHeightChange: ((CGFloat) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.reportMaxHeight()
                }
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.reportMaxHeight()
        }
    }

    private func reportMaxHeight() {
        guard let window, let screen = window.screen else { return }
        onMaxHeightChange?(window.frame.maxY - screen.visibleFrame.minY)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
