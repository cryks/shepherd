// Entry point. As an LSUIElement (hidden from the Dock) resident app, it shares
// the FleetStore — which bundles local plus multiple remotes — across three
// scenes: the menu bar item, the monitor window, and settings.
// The monitor window is opened explicitly from the menu; it neither opens
// automatically at launch nor gets restored (suppressed via
// defaultLaunchBehavior / restorationBehavior).
// The settings scene also opens only from MenuPanel's "Settings…" item.

import AppKit
import Observation
import SwiftUI

/// Bridges macOS termination paths (menu, logout, terminate) to FleetStore's
/// stop, and system sleep/wake to poll suspend/resume. On termination, managed
/// SSH processes and temporary Unix sockets are cleaned up before the app exits.
@MainActor
final class ShepherdApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: FleetStore?
    weak var menuBarBlinkClock: MenuBarBlinkClock?

    /// Observation tokens for sleep notifications. Sleep/wake are delivered only
    /// by NSWorkspace.shared.notificationCenter, so registration goes there rather
    /// than NotificationCenter.default.
    /// The delegate lives as long as the app, so the observers are never removed.
    private var sleepObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // queue: .main means main-thread delivery, so assumeIsolated holds.
                MainActor.assumeIsolated {
                    self?.store?.suspendPolling()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.store?.resumePolling()
                }
            },
        ]
    }

    func applicationWillTerminate(_: Notification) {
        menuBarBlinkClock?.stop()
        store?.stop()
    }
}

/// Process entry point. Only --render-screenshots (headless rendering of the
/// README screenshots) branches to ScreenshotRenderer; everything else starts
/// the SwiftUI App lifecycle.
@main
enum ShepherdMain {
    static func main() {
        // static main is called on the main thread but carries no MainActor
        // isolation declaration, so assumeIsolated hands off to
        // ScreenshotRenderer (@MainActor).
        let didRenderScreenshots = MainActor.assumeIsolated {
            ScreenshotRenderer.runIfRequested()
        }
        guard !didRenderScreenshots else { return }
        ShepherdApp.main()
    }
}

struct ShepherdApp: App {
    @NSApplicationDelegateAdaptor(ShepherdApplicationDelegate.self)
    private var applicationDelegate
    @State private var store: FleetStore
    @State private var menuBarBlinkClock: MenuBarBlinkClock

    init() {
        let store = FleetStore()
        let menuBarBlinkClock = MenuBarBlinkClock {
            // The setting is also read each tick. After switching it OFF, the
            // next tick returns to the visible phase.
            MenuBarIconPresentation.blinkEnabled()
                && MenuBarIconPresentation.shouldBlink(store.menuBarState)
        }
        store.start()
        menuBarBlinkClock.start()
        _store = State(initialValue: store)
        _menuBarBlinkClock = State(initialValue: menuBarBlinkClock)
        applicationDelegate.store = store
        applicationDelegate.menuBarBlinkClock = menuBarBlinkClock
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            MenuBarIcon(store: store, blinkClock: menuBarBlinkClock)
        }
        .menuBarExtraStyle(.window)

        // Pop-out window. MonitorView lays a full-surface material via
        // containerBackground and adds a toolbar item (status summary). The
        // title bar stays standard; alignment of the title and traffic lights
        // is left to AppKit.
        Window("Shepherd", id: monitorWindowId) {
            MonitorView(store: store)
        }
        .defaultSize(width: 380, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(store: store)
        }
    }
}

/// Scene ID of the monitor window. Referenced by openWindow / dismissWindow.
let monitorWindowId = "monitor"

/// Outlives the `MenuBarExtra` label and advances the blink phase every 0.8
/// seconds. A `task` attached to the label does not keep running after the
/// conversion to a status item, so the App owns this clock. In non-blinking
/// states, `blinkVisible` is not rewritten, so the menu bar is not periodically
/// redrawn during quiet / working.
@Observable @MainActor
final class MenuBarBlinkClock {
    /// true is the visible phase. Stays true when not a blink target, before
    /// start, and after stop.
    private(set) var blinkVisible = true

    /// Fixed at init; the same interval is used when the task restarts.
    @ObservationIgnored private let phaseDuration: Duration
    /// Reads the latest fleet-aggregate state on each tick. The clock itself
    /// holds no aggregate state.
    @ObservationIgnored private let shouldBlink: @MainActor () -> Bool
    /// nil before start or after stop. While non-nil, exactly one sleep loop is
    /// owned.
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - phaseDuration: How long each visible/hidden phase is held.
    ///   - shouldBlink: Whether the aggregate state at tick time is a blink target.
    init(
        phaseDuration: Duration = MenuBarIconPresentation.blinkPhaseDuration,
        shouldBlink: @escaping @MainActor () -> Bool
    ) {
        self.phaseDuration = phaseDuration
        self.shouldBlink = shouldBlink
    }

    /// Starts the blink tick. Duplicate calls keep the existing task.
    func start() {
        guard task == nil else { return }
        let phaseDuration = phaseDuration
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: phaseDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                if shouldBlink() {
                    blinkVisible.toggle()
                } else if !blinkVisible {
                    blinkVisible = true
                }
            }
        }
    }

    /// Stops the tick and returns to the visible phase. Used for task
    /// cancellation at app termination.
    func stop() {
        task?.cancel()
        task = nil
        blinkVisible = true
    }
}

/// The icon resident in the menu bar. This is Shepherd's primary display,
/// representing the agents' state as a single circle:
///   - blinking red ●: has blocked (awaiting input)
///   - blinking green ●: has done (unviewed completion)
///   - yellow ○: has working            - colorless ○: everyone idle
///   - dashed ○: zero ready watch targets (including disconnected / protocol mismatch)
/// All 5 states are custom-drawn on the same geometry (18pt canvas, 14pt outer
/// diameter) so the circle's size never appears to change with state. SF Symbols
/// are not used: in the menu bar they become template-rendered and lose their
/// color, and their glyphs' visual size does not match the custom drawing
/// either. Only the two colorless states use isTemplate = true so they follow
/// the menu bar's light/dark appearance.
/// Blinking is expressed by swapping in the fully transparent blinkHidden NSImage
/// during the hidden phase. The MenuBarExtra label is converted into an
/// NSStatusItem button, and changes to the view's opacity are not reflected in
/// the status item's rendering, so blinking rides the same path — swapping the
/// image content — that already demonstrably works for switching the state color.
/// The per-state NSImages themselves are never rewritten, so AgentRow in the
/// menu and monitor window stays static.
struct MenuBarIcon: View {
    var store: FleetStore
    var blinkClock: MenuBarBlinkClock
    /// Blink-enabled setting. Observes the same key as the Settings Toggle, so
    /// switching it OFF returns to the circle display immediately without
    /// waiting for the next tick.
    @AppStorage(MenuBarIconPresentation.blinkEnabledKey) private var blinkEnabled = true

    var body: some View {
        Image(nsImage: image)
    }

    private var image: NSImage {
        if !MenuBarIconPresentation.showsStatusShape(
            for: store.menuBarState,
            blinkEnabled: blinkEnabled,
            blinkVisible: blinkClock.blinkVisible
        ) {
            // Even fully transparent, the canvas is identical, so the status
            // item's width and click area remain.
            StatusIcons.blinkHidden
        } else {
            switch store.menuBarState {
            case .disconnected:
                StatusIcons.disconnected
            case .quiet:
                StatusIcons.quiet
            case .working:
                StatusIcons.working
            case .done:
                StatusIcons.done
            case .blocked:
                StatusIcons.blocked
            }
        }
    }
}

/// Blink rules used only by the menu bar status item.
/// Visible and hidden alternate at 0.8 seconds per phase.
/// Whether blinking itself is enabled is a user setting (blinkEnabledKey).
enum MenuBarIconPresentation {
    static let blinkPhaseDuration: Duration = .milliseconds(800)

    /// UserDefaults key for the blink setting. Written by SettingsView's Toggle
    /// and read by MenuBarIcon (@AppStorage) and ShepherdApp's clock closure
    /// (blinkEnabled(in:)).
    static let blinkEnabledKey = "MenuBarBlinkEnabled"

    /// The saved blink setting. Unsaved (missing key) defaults to true
    /// (blinking). Direct read for non-View contexts (the clock closure) where
    /// @AppStorage is unavailable.
    nonisolated static func blinkEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: blinkEnabledKey) as? Bool ?? true
    }

    static func shouldBlink(_ state: MenuBarState) -> Bool {
        switch state {
        case .done, .blocked:
            return true
        case .disconnected, .quiet, .working:
            return false
        }
    }

    /// true if this is a phase that draws the state circle, false if it is the
    /// blink's hidden phase (swapping in the fully transparent image). When
    /// blinkEnabled is false, and in non-blinking states, the shape shows
    /// regardless of blinkVisible; only done / blocked with blinking enabled
    /// follow the phase the timer rewrites.
    static func showsStatusShape(
        for state: MenuBarState,
        blinkEnabled: Bool,
        blinkVisible: Bool
    ) -> Bool {
        !blinkEnabled || !shouldBlink(state) || blinkVisible
    }
}

/// Circle icons shared by the menu bar itself and the agent rows inside the
/// menu. All states share the same geometry, so sizes line up wherever they are
/// placed. The images are static; menu bar blinking is done by MenuBarIcon
/// swapping in blinkHidden.
enum StatusIcons {
    static let disconnected = circleImage(filled: false, dashed: true, template: true)
    static let quiet = circleImage(filled: false, template: true)
    static let working = circleImage(color: .systemYellow, filled: false)
    static let done = circleImage(color: .systemGreen, filled: true)
    static let blocked = circleImage(color: .systemRed, filled: true)

    /// Fully transparent image dedicated to the blink's hidden phase. Same 18pt
    /// canvas as the other states, so swapping it in does not change the status
    /// item's width or click area.
    static let blinkHidden = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }

    /// Per-agent status display. idle maps to the colorless ○, unknown to the
    /// dashed ○.
    static func icon(for status: AgentStatus) -> NSImage {
        switch status {
        case .working: working
        case .blocked: blocked
        case .done: done
        case .idle: quiet
        case .unknown: disconnected
        }
    }

    /// Draws a 14pt-outer-diameter circle centered on an 18pt canvas. Every
    /// state first draws the same ring (line width 1.5, inset by half the line
    /// width so the outer diameter matches); when filled, a filled dot with a
    /// 1.5pt gap inside the ring is layered on top, forming a double circle
    /// (equivalent to SF Symbols' circle.inset.filled).
    private static func circleImage(
        color: NSColor = .black,
        filled: Bool,
        dashed: Bool = false,
        template: Bool = false
    ) -> NSImage {
        let lineWidth: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2 + lineWidth / 2, dy: 2 + lineWidth / 2))
            if dashed {
                var pattern: [CGFloat] = [2.5, 2.0]
                ring.setLineDash(&pattern, count: pattern.count, phase: 0)
            }
            color.setStroke()
            ring.lineWidth = lineWidth
            ring.stroke()
            if filled {
                // Filled dot 1.5pt inside the ring's inner edge (outer diameter
                // 14 - line width 1.5×2 = 11).
                let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
                color.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}
