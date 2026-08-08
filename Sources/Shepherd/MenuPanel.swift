// NSMenu cannot render multi-line items, so the menu bar item presents this
// SwiftUI view through MenuBarExtra's .window style instead of a native menu.

import AppKit
import SwiftUI

struct MenuPanel: View {
    @Bindable var store: FleetStore
    // nil only under headless screenshot rendering, which never starts Sparkle.
    let updater: UpdaterModel?
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
                    showsSourceLabels: store.showsSourceLabels,
                    rowContext: store.rowContext(for:),
                    excerptState: store.agentExcerptState(for:),
                    onRemoteEnabledChange: setRemoteEnabled
                ) { pane in
                    Task { @MainActor in
                        await store.focus(pane, sourceID: .local)
                    }
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

    // MenuBarExtra sizes its panel from the view's ideal size, but a ScrollView
    // has none and collapses to 0, so the content is measured and fed back as
    // an explicit height. The 56pt fallback applies only before the first
    // measurement; keeping it afterwards would pad short empty states.
    @State private var listHeight: CGFloat = 0

    // nil during the first layout, before the view is attached to a window.
    @State private var panelMaxHeight: CGFloat?

    @State private var chromeHeight: CGFloat = 0

    // 440 is a conservative on-screen guess used for the single layout pass
    // before the window is measured.
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
                    // An LSUIElement app does not come to the front by itself.
                    NSApp.activate()
                }
                dismiss()
            }
            MenuSeparator()
            MenuItem(tr("Settings…", ja: "設定…")) {
                openSettings()
                // An LSUIElement app does not come to the front by itself.
                NSApp.activate()
                dismiss()
            }
            MenuItem(
                tr("Check for Updates…", ja: "アップデートをチェック…"),
                isEnabled: updater?.canCheckForUpdates ?? true
            ) {
                updater?.checkForUpdates()
                // Sparkle's own window needs the same explicit activation.
                NSApp.activate()
                dismiss()
            }
            MenuSeparator()
            MenuItem(tr("About Shepherd", ja: "Shepherd について")) {
                openWindow(id: aboutWindowId)
                // An LSUIElement app does not come to the front by itself.
                NSApp.activate()
                dismiss()
            }
            MenuItem(tr("Quit", ja: "終了")) {
                store.stop()
                NSApp.terminate(nil)
            }
        }
        // Horizontal padding belongs to each MenuItem as its highlight inset,
        // so that MenuSeparator can still span the full panel width.
        .padding(.vertical, 5)
    }
}

// SwiftUI has no programmatic MenuBarExtra presentation API (as of macOS 26),
// so the hotkey clicks the status item button. performClick on an open panel
// closes it, which makes this one path a toggle.
@MainActor
enum MenuBarPanelToggler {
    static func toggle() {
        for window in NSApp.windows {
            guard let button = statusBarButton(under: window.contentView) else {
                continue
            }
            button.performClick(nil)
            return
        }
    }

    // NSApp.windows holds only this process's windows and Shepherd has a single
    // MenuBarExtra, so the first hit is the right button.
    private static func statusBarButton(under view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = statusBarButton(under: subview) { return button }
        }
        return nil
    }
}

// Imitates an NSMenu item, which the .window panel style cannot use. The
// dimensions come from measuring the native menu on macOS 26: 5pt highlight
// inset, 12pt text inset inside the highlight, about 24pt item height.
// The 9pt corner radius is concentric with the panel's roughly 14pt continuous
// corner minus the 5pt inset, which keeps the two curves parallel.
private struct MenuItem: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHighlighted = false

    init(_ title: String, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.isEnabled = isEnabled
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
        .disabled(!isEnabled)
        .foregroundStyle(
            !isEnabled
                ? Color(nsColor: .disabledControlTextColor)
                : showsHighlight
                    ? Color(nsColor: .selectedMenuItemTextColor)
                    : Color.primary
        )
        .background(
            showsHighlight
                ? Color(nsColor: .selectedContentBackgroundColor)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .padding(.horizontal, 5)
        .onHover { isHighlighted = $0 }
    }

    // onHover keeps firing on a disabled button, so the NSMenu behavior of no
    // highlight while disabled is enforced here rather than at event delivery.
    private var showsHighlight: Bool {
        isHighlighted && isEnabled
    }
}

// The native NSMenu separator spans the full menu width, hence no horizontal
// padding.
private struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.vertical, 5)
    }
}

// A MenuBarExtra panel is pinned below the menu bar and grows only downward, so
// its height limit is the distance from the window's top edge to the bottom of
// the screen's visibleFrame. SwiftUI cannot reach the window, so AppKit does it.
private struct PanelMaxHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onMaxHeightChange = onChange
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {}
}

// didMove and didChangeScreen matter because with menu bars on several displays
// the same window is repositioned onto the screen where the panel reopens.
// Growing downward moves the origin but not maxY, so the reported value is
// unchanged and no relayout loop occurs.
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
        // The panel is not positioned yet at this point, so read the frame one
        // runloop tick later.
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
