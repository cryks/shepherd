import AppKit
import Observation
import OSLog
import SwiftUI
import UserNotifications

private let applicationLog = Logger(
    subsystem: "io.github.cryks.shepherd",
    category: "application"
)

enum ApplicationActivationResult: Equatable {
    case active
    case timedOut
    case shutDown

    var allowsTerminalHandoff: Bool {
        self != .shutDown
    }
}

// NSApplication activation is asynchronous and can be denied, so a caller that
// must be frontmost before handing activation to a terminal waits for the
// delegate callback or a bounded timeout. Concurrent requests share one wait.
@MainActor
final class ApplicationActivationCoordinator {
    // NSApplication is process-wide, so the delegate's lifecycle callbacks have
    // a single instance to forward to.
    static let shared = ApplicationActivationCoordinator()

    private let activationTimeout: Duration
    private let isActive: @MainActor () -> Bool
    private let requestActivation: @MainActor () -> Void
    private let onTimeout: @MainActor () -> Void

    private var waiters: [CheckedContinuation<ApplicationActivationResult, Never>] = []
    private var timeoutTask: Task<Void, Never>?
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

    func activate() async -> ApplicationActivationResult {
        guard !isShutDown else { return .shutDown }
        guard !isActive() else { return .active }

        return await withCheckedContinuation { continuation in
            // Activation or shutdown can land between the checks above and
            // registration below.
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

            // Register before requesting, so a synchronous activation callback
            // cannot leave the caller suspended forever.
            requestActivation()
            if isActive() {
                finish(with: .active)
            }
        }
    }

    func didBecomeActive() {
        finish(with: .active)
    }

    // Termination must not leave checked continuations suspended.
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

    // The delegate lives as long as the process, so these are never removed.
    private var sleepObservers: [NSObjectProtocol] = []

    func applicationWillFinishLaunching(_: Notification) {
        // The center holds its delegate weakly; SwiftUI's adaptor keeps this
        // object alive for the process lifetime.
        UNUserNotificationCenter.current().delegate = self
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Sleep and wake are posted only on NSWorkspace's center, never on
        // NotificationCenter.default.
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // queue: .main guarantees main-thread delivery.
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

    // An accessory app can be frontmost when a notification arrives, and macOS
    // then suppresses it unless foreground presentation is requested.
    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler:
            @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // UNNotificationResponse is not Sendable, so only the parsed ID crosses to
    // the MainActor.
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

    // Returning from the async delegate ends the response lifetime, so pane
    // focus and the activation handoff must complete before it returns.
    func performNotificationAction(_ notificationID: AttentionNotificationID) async {
        await notificationActionHandler?(notificationID)
    }
}

@main
enum ShepherdMain {
    static func main() {
        // static main runs on the main thread but carries no MainActor
        // isolation.
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
    private let hotkeyCenter: GlobalHotkeyCenter

    init() {
        let store = FleetStore()
        let monitorNavigation = MonitorWindowNavigation()
        let notificationCenter = AgentNotificationCenter()
        // The stager delays blocked/done deliveries so `{excerpt}` can be
        // rendered from a pane excerpt read after the state change.
        let noticeStager = AttentionNoticeStager(
            excerptState: { [weak store] in store?.agentExcerptState(for: $0) },
            render: { [weak store] notice, excerpt in
                guard let store else { return nil }
                return AttentionFleetObservation.rendered(
                    notice,
                    excerpt: excerpt,
                    store: store
                )
            },
            forward: { notificationCenter.apply($0) }
        )
        let attentionMonitor = AttentionMonitor(store: store) { effects in
            noticeStager.apply(effects)
        }
        let notificationSettings = NotificationSettingsCoordinator(
            notificationCenter: notificationCenter,
            onEnabledChange: { [weak attentionMonitor] enabled in
                attentionMonitor?.setEnabled(enabled)
            }
        )
        let menuBarBlinkClock = MenuBarBlinkClock {
            MenuBarIconPresentation.blinkEnabled()
                && MenuBarIconPresentation.shouldBlink(store.menuBarState)
        }
        // SwiftUI exposes no open/close API for a MenuBarExtra panel, so its
        // hotkey clicks the status item button instead.
        let hotkeyCenter = GlobalHotkeyCenter(setting: HotkeySetting.shared) {
            [weak store, weak monitorNavigation] action in
            switch action {
            case .toggleMenuPanel:
                MenuBarPanelToggler.toggle()
            case .toggleMonitorWindow:
                guard let store, let monitorNavigation else { return }
                if store.monitorWindowVisible {
                    monitorNavigation.requestClose()
                } else {
                    monitorNavigation.open()
                }
            }
        }
        attentionMonitor.start(enabled: notificationSettings.isEnabled)
        Task { await notificationSettings.start() }
        store.start()
        menuBarBlinkClock.start()
        hotkeyCenter.start()
        self.attentionMonitor = attentionMonitor
        self.hotkeyCenter = hotkeyCenter
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
            MenuPanel(store: store, updater: updater)
        } label: {
            MenuBarIcon(store: store, blinkClock: menuBarBlinkClock)
                .background {
                    MonitorWindowRequestReceiver(navigation: monitorNavigation)
                }
        }
        .menuBarExtraStyle(.window)

        // Both extra windows open only from the menu, so launch and state
        // restoration must not bring them up on their own.
        Window("Shepherd", id: monitorWindowId) {
            MonitorView(store: store, navigation: monitorNavigation)
        }
        .defaultSize(width: 380, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window(tr("About Shepherd", ja: "Shepherd について"), id: aboutWindowId) {
            AboutView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(
                store: store,
                notificationSettings: notificationSettings,
                updater: updater
            )
        }
        // SettingsWindowSizer owns each tab's minimum size; contentMinSize
        // leaves the frame draggable past it instead of locking it to the
        // content.
        .windowResizability(.contentMinSize)
    }
}

// Notification responses and hotkeys can arrive while the Monitor scene does
// not exist, so the request is parked in MonitorWindowNavigation and replayed
// here, at the always-mounted menu bar label. A pending close is deliberately
// not replayed on appear: it targeted a window that no longer exists.
private struct MonitorWindowRequestReceiver: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    let navigation: MonitorWindowNavigation
    @State private var handledOpenRevision: UInt64 = 0
    @State private var handledCloseRevision: UInt64 = 0

    var body: some View {
        Color.clear
            .onAppear { openIfNeeded() }
            .onChange(of: navigation.openRevision) {
                openIfNeeded()
            }
            .onChange(of: navigation.closeRevision) {
                closeIfNeeded()
            }
    }

    private func openIfNeeded() {
        let revision = navigation.openRevision
        guard revision != 0, revision != handledOpenRevision else { return }
        handledOpenRevision = revision
        openWindow(id: monitorWindowId)
        // LSUIElement apps are not activated when a SwiftUI window opens.
        NSApp.activate()
    }

    private func closeIfNeeded() {
        let revision = navigation.closeRevision
        guard revision != 0, revision != handledCloseRevision else { return }
        handledCloseRevision = revision
        dismissWindow(id: monitorWindowId)
    }
}

let monitorWindowId = "monitor"

// A `task` on the MenuBarExtra label stops running once the label is converted
// into a status item, so the App owns the blink clock instead. Non-blinking
// states leave blinkVisible untouched to avoid redrawing the menu bar.
@Observable @MainActor
final class MenuBarBlinkClock {
    private(set) var blinkVisible = true

    @ObservationIgnored private let phaseDuration: Duration
    @ObservationIgnored private let shouldBlink: @MainActor () -> Bool
    @ObservationIgnored private var task: Task<Void, Never>?

    init(
        phaseDuration: Duration = MenuBarIconPresentation.blinkPhaseDuration,
        shouldBlink: @escaping @MainActor () -> Bool
    ) {
        self.phaseDuration = phaseDuration
        self.shouldBlink = shouldBlink
    }

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

    func stop() {
        task?.cancel()
        task = nil
        blinkVisible = true
    }
}

// SF Symbols are template-rendered in the menu bar and lose their color, so all
// five states are custom-drawn on one shared geometry. Only the colorless
// states set isTemplate, so they alone follow the menu bar appearance.
// The status item ignores changes to the view's opacity, so the hidden blink
// phase swaps in a transparent image over the same path that already works for
// switching color.
struct MenuBarIcon: View {
    var store: FleetStore
    var blinkClock: MenuBarBlinkClock
    // Observing the setting here, not just in the clock closure, makes turning
    // blinking off restore the circle without waiting for the next tick.
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

enum MenuBarIconPresentation {
    static let blinkPhaseDuration: Duration = .milliseconds(800)

    static let blinkEnabledKey = "MenuBarBlinkEnabled"

    // Direct read for non-View contexts, where @AppStorage is unavailable.
    // A missing key means blinking, matching the @AppStorage default.
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

    static func showsStatusShape(
        for state: MenuBarState,
        blinkEnabled: Bool,
        blinkVisible: Bool
    ) -> Bool {
        !blinkEnabled || !shouldBlink(state) || blinkVisible
    }
}

enum StatusIcons {
    static let disconnected = circleImage(filled: false, dashed: true, template: true)
    static let quiet = circleImage(filled: false, template: true)
    static let working = circleImage(color: .statusWorking, filled: false)
    static let done = circleImage(color: .systemGreen, filled: true)
    static let blocked = circleImage(color: .systemRed, filled: true)

    // Transparent rather than absent, and on the same canvas, so the hidden
    // blink phase keeps the status item's width and click area.
    static let blinkHidden = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }

    static func icon(for status: AgentStatus) -> NSImage {
        switch status {
        case .working: working
        case .blocked: blocked
        case .done: done
        case .idle: quiet
        case .unknown: disconnected
        }
    }

    // 14pt outer diameter on an 18pt canvas. The ring is inset by half the line
    // width because NSBezierPath strokes centered on the path.
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
                // Leaves a 1.5pt gap inside the ring, giving the double circle
                // of SF Symbols' circle.inset.filled.
                let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
                color.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = template
        // statusWorking is appearance-dependent, and a cached bitmap would keep
        // the color it was first drawn with across a light/dark switch.
        image.cacheMode = .never
        return image
    }
}

extension NSColor {
    // systemYellow reads at about 1.5:1 on the light menu background, too low
    // for caption-sized text, so light appearance deepens it to about 2.6:1.
    static let statusWorking = NSColor(name: "statusWorking") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemYellow
            : NSColor(srgbRed: 0.85, green: 0.58, blue: 0.0, alpha: 1)
    }
}
