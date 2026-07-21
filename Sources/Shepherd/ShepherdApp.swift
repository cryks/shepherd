// Entry point. As an LSUIElement (hidden from the Dock) resident app, it shares
// the FleetStore — which bundles local plus multiple remotes — across three
// scenes: the menu bar item, the monitor window, and settings.
// The monitor window is opened explicitly from the menu; it neither opens
// automatically at launch nor gets restored (suppressed via
// defaultLaunchBehavior / restorationBehavior).
// The settings scene also opens only from MenuPanel's "Settings…" item.

import AppKit
import Observation
import OSLog
import SwiftUI
import UserNotifications

private let applicationLog = Logger(
    subsystem: "io.github.cryks.shepherd",
    category: "application"
)

/// Tells the focus pipeline whether a terminal handoff may continue after the
/// source-application activation phase.
enum ApplicationActivationResult: Equatable {
    /// Shepherd is active and can yield activation through NSWorkspace.
    case active
    /// AppKit did not activate Shepherd within the bound; continue best effort.
    case timedOut
    /// Application teardown started; no new external application may be opened.
    case shutDown

    var allowsTerminalHandoff: Bool {
        self != .shutDown
    }
}

/// Serializes requests to make this accessory app active before it hands
/// activation to another process. NSApplication activation is asynchronous and
/// can be denied, so callers wait for the delegate's did-become-active callback
/// or a bounded timeout. Concurrent notification clicks share one request.
@MainActor
final class ApplicationActivationCoordinator {
    /// NSApplication is process-wide, and ShepherdApplicationDelegate forwards
    /// its matching lifecycle callbacks to this process-wide coordinator.
    static let shared = ApplicationActivationCoordinator()

    private let activationTimeout: Duration
    private let isActive: @MainActor () -> Bool
    private let requestActivation: @MainActor () -> Void
    private let onTimeout: @MainActor () -> Void

    /// Continuations registered after an inactive check and drained by an
    /// activation callback, timeout, or application shutdown.
    private var waiters: [CheckedContinuation<ApplicationActivationResult, Never>] = []
    /// Exists while at least one waiter owns the current activation request.
    private var timeoutTask: Task<Void, Never>?
    /// Set during termination so no new activation request outlives teardown.
    private var isShutDown = false

    init(
        activationTimeout: Duration = .seconds(1),
        isActive: @escaping @MainActor () -> Bool = { NSApp.isActive },
        requestActivation: @escaping @MainActor () -> Void = { NSApp.activate() },
        onTimeout: @escaping @MainActor () -> Void = {
            applicationLog.error("Shepherd activation timed out before terminal handoff")
        }
    ) {
        self.activationTimeout = activationTimeout
        self.isActive = isActive
        self.requestActivation = requestActivation
        self.onTimeout = onTimeout
    }

    /// Returns after Shepherd becomes active, the bounded wait expires, or app
    /// teardown starts. A timeout permits a best-effort terminal request;
    /// shutdown forbids it.
    func activate() async -> ApplicationActivationResult {
        guard !isShutDown else { return .shutDown }
        guard !isActive() else { return .active }

        return await withCheckedContinuation { continuation in
            // Activation can arrive between the outer check and registration.
            guard !isShutDown else {
                continuation.resume(returning: .shutDown)
                return
            }
            guard !isActive() else {
                continuation.resume(returning: .active)
                return
            }

            waiters.append(continuation)
            guard waiters.count == 1 else { return }

            timeoutTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: activationTimeout)
                } catch {
                    return
                }
                if !isActive() {
                    onTimeout()
                    finish(with: .timedOut)
                } else {
                    finish(with: .active)
                }
            }

            // Register the continuation before requesting activation so a
            // synchronous callback cannot leave the caller suspended.
            requestActivation()
            if isActive() {
                finish(with: .active)
            }
        }
    }

    /// Resumes every request coalesced behind the current AppKit activation.
    func didBecomeActive() {
        finish(with: .active)
    }

    /// Prevents termination from leaving checked continuations suspended.
    func shutdown() {
        isShutDown = true
        finish(with: .shutDown)
    }

    private func finish(with result: ApplicationActivationResult) {
        let waiters = self.waiters
        self.waiters.removeAll()
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        timeoutTask?.cancel()
        waiters.forEach { $0.resume(returning: result) }
    }
}

/// Bridges macOS termination paths (menu, logout, terminate) to FleetStore's
/// stop, system sleep/wake to poll suspend/resume, and UserNotifications delegate
/// callbacks to app-owned attention routing. On termination, managed SSH
/// processes, temporary Unix sockets, and live agent notifications are cleaned up
/// before the app exits.
@MainActor
final class ShepherdApplicationDelegate: NSObject, NSApplicationDelegate,
    UNUserNotificationCenterDelegate
{
    weak var store: FleetStore?
    weak var menuBarBlinkClock: MenuBarBlinkClock?
    var notificationActionHandler:
        (@MainActor (AttentionNotificationID) async -> Void)?
    var notificationTerminationHandler: (@MainActor () -> Void)?
    var notificationAuthorizationRefreshHandler: (@MainActor () -> Void)?

    /// Observation tokens for sleep notifications. Sleep/wake are delivered only
    /// by NSWorkspace.shared.notificationCenter, so registration goes there rather
    /// than NotificationCenter.default.
    /// The delegate lives as long as the app, so the observers are never removed.
    private var sleepObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_: Notification) {
        // The center retains its delegate weakly. This application delegate is
        // retained by SwiftUI's adaptor for the process lifetime.
        UNUserNotificationCenter.current().delegate = self
    }

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

    func applicationDidBecomeActive(_: Notification) {
        ApplicationActivationCoordinator.shared.didBecomeActive()
        notificationAuthorizationRefreshHandler?()
    }

    func applicationWillTerminate(_: Notification) {
        ApplicationActivationCoordinator.shared.shutdown()
        notificationTerminationHandler?()
        menuBarBlinkClock?.stop()
        store?.stop()
    }

    /// Shepherd is an accessory app, so a notification can arrive while one of
    /// its windows is active. Explicit foreground presentation preserves the
    /// same banner/list behavior without adding sound.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Routes only the system's default notification click. The async delegate
    /// return is UserNotifications' completion boundary, so local pane focus and
    /// the terminal activation request remain inside the response lifetime.
    /// The response is not Sendable; only its parsed opaque ID crosses to the
    /// MainActor.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let notificationID = AgentNotificationCenter.attentionNotificationID(
                  from: response.notification.request
              ) else {
            return
        }

        await performNotificationAction(notificationID)
    }

    /// Awaits the app-owned action so returning from the async delegate cannot
    /// precede Herdr pane selection or the AppKit activation handoff request.
    func performNotificationAction(_ notificationID: AttentionNotificationID) async {
        await notificationActionHandler?(notificationID)
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
    @State private var monitorNavigation: MonitorWindowNavigation
    @State private var notificationSettings: NotificationSettingsCoordinator
    @State private var updater: UpdaterModel
    private let attentionMonitor: AttentionMonitor

    init() {
        let store = FleetStore()
        let monitorNavigation = MonitorWindowNavigation()
        let notificationCenter = AgentNotificationCenter()
        let attentionMonitor = AttentionMonitor(store: store) { effects in
            notificationCenter.apply(effects)
        }
        let notificationSettings = NotificationSettingsCoordinator(
            notificationCenter: notificationCenter,
            onEnabledChange: { [weak attentionMonitor] enabled in
                attentionMonitor?.setEnabled(enabled)
            }
        )
        let menuBarBlinkClock = MenuBarBlinkClock {
            // The setting is also read each tick. After switching it OFF, the
            // next tick returns to the visible phase.
            MenuBarIconPresentation.blinkEnabled()
                && MenuBarIconPresentation.shouldBlink(store.menuBarState)
        }
        attentionMonitor.start(enabled: notificationSettings.isEnabled)
        store.start()
        menuBarBlinkClock.start()
        self.attentionMonitor = attentionMonitor
        _store = State(initialValue: store)
        _menuBarBlinkClock = State(initialValue: menuBarBlinkClock)
        _monitorNavigation = State(initialValue: monitorNavigation)
        _notificationSettings = State(initialValue: notificationSettings)
        _updater = State(initialValue: UpdaterModel())
        applicationDelegate.store = store
        applicationDelegate.menuBarBlinkClock = menuBarBlinkClock
        applicationDelegate.notificationActionHandler = {
            [weak attentionMonitor, weak store, weak monitorNavigation] notificationID in
            guard let destination = attentionMonitor?.destination(for: notificationID) else {
                monitorNavigation?.open()
                return
            }
            if destination.isRemote {
                monitorNavigation?.open(revealing: SourcePaneID(
                    sourceID: destination.sourceID,
                    paneID: destination.pane.paneId
                ))
            } else {
                await store?.focus(destination.pane, sourceID: destination.sourceID)
            }
        }
        applicationDelegate.notificationTerminationHandler = {
            [weak attentionMonitor, weak notificationCenter] in
            attentionMonitor?.stop()
            notificationCenter?.terminate()
        }
        applicationDelegate.notificationAuthorizationRefreshHandler = {
            [weak notificationSettings] in
            Task { @MainActor in
                await notificationSettings?.refresh()
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            MenuBarIcon(store: store, blinkClock: menuBarBlinkClock)
                .background {
                    MonitorWindowOpenReceiver(navigation: monitorNavigation)
                }
        }
        .menuBarExtraStyle(.window)

        // Pop-out window. MonitorView lays a full-surface material via
        // containerBackground and adds a toolbar item (status summary). The
        // title bar stays standard; alignment of the title and traffic lights
        // is left to AppKit.
        Window("Shepherd", id: monitorWindowId) {
            MonitorView(store: store, navigation: monitorNavigation)
        }
        .defaultSize(width: 380, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(
                store: store,
                notificationSettings: notificationSettings,
                updater: updater
            )
        }
    }
}

/// Installs the SwiftUI OpenWindowAction at the always-mounted menu bar label.
/// Notification responses can arrive while the Monitor scene does not exist, so
/// MonitorWindowNavigation retains the request and this receiver opens the
/// singleton scene once its environment is available. `openRevision` also makes
/// repeated clicks bring an already-open window forward.
private struct MonitorWindowOpenReceiver: View {
    @Environment(\.openWindow) private var openWindow
    let navigation: MonitorWindowNavigation
    @State private var handledRevision: UInt64 = 0

    var body: some View {
        Color.clear
            .onAppear { openIfNeeded() }
            .onChange(of: navigation.openRevision) {
                openIfNeeded()
            }
    }

    private func openIfNeeded() {
        let revision = navigation.openRevision
        guard revision != 0, revision != handledRevision else { return }
        handledRevision = revision
        openWindow(id: monitorWindowId)
        // LSUIElement apps are not activated when a SwiftUI window opens.
        NSApp.activate()
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
