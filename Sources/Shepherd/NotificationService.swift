// The only place Shepherd talks to macOS UserNotifications. Nothing here decides
// when a notification is warranted; that stays in AttentionMonitor.
//
// Everything is MainActor-isolated to keep ordering with AttentionMonitor. The
// exception is attentionNotificationID(from:), which must be nonisolated so a
// UNUserNotificationCenterDelegate callback can validate a response before it
// hops to the MainActor.

import AppKit
import Foundation
import Observation
import UserNotifications
import os

private let notificationLog = Logger(
    subsystem: "io.github.cryks.shepherd",
    category: "notifications"
)

// Sendable mirror of UNNotificationSettings, reduced to the fields the settings
// UI reads. Each `unknown` case absorbs a state macOS may add.
struct NotificationSystemSettings: Equatable, Sendable {
    enum AuthorizationStatus: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
        case provisional
        case unknown
    }

    enum Setting: Equatable, Sendable {
        case notSupported
        case disabled
        case enabled
        case unknown
    }

    enum AlertStyle: Equatable, Sendable {
        case none
        case banner
        case alert
        case unknown
    }

    let authorizationStatus: AuthorizationStatus
    let alertSetting: Setting
    let notificationCenterSetting: Setting
    let alertStyle: AlertStyle

    init(
        authorizationStatus: AuthorizationStatus,
        alertSetting: Setting,
        notificationCenterSetting: Setting,
        alertStyle: AlertStyle
    ) {
        self.authorizationStatus = authorizationStatus
        self.alertSetting = alertSetting
        self.notificationCenterSetting = notificationCenterSetting
        self.alertStyle = alertStyle
    }

    // Shown until the first asynchronous settings read returns.
    static let notDetermined = NotificationSystemSettings(
        authorizationStatus: .notDetermined,
        alertSetting: .notSupported,
        notificationCenterSetting: .notSupported,
        alertStyle: .none
    )

    // Says only that alerts may be submitted. Banner and Notification Center can
    // still be off, which is why the settings UI reads the fields separately.
    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    fileprivate init(_ settings: UNNotificationSettings) {
        authorizationStatus = Self.map(settings.authorizationStatus)
        alertSetting = Self.map(settings.alertSetting)
        notificationCenterSetting = Self.map(settings.notificationCenterSetting)
        alertStyle = Self.map(settings.alertStyle)
    }

    private static func map(_ status: UNAuthorizationStatus) -> AuthorizationStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        @unknown default: .unknown
        }
    }

    private static func map(_ setting: UNNotificationSetting) -> Setting {
        switch setting {
        case .notSupported: .notSupported
        case .disabled: .disabled
        case .enabled: .enabled
        @unknown default: .unknown
        }
    }

    private static func map(_ style: UNAlertStyle) -> AlertStyle {
        switch style {
        case .none: .none
        case .banner: .banner
        case .alert: .alert
        @unknown default: .unknown
        }
    }
}

// Exists so authorization, delivery, and removal can be tested without
// registering the test runner with Notification Center.
@MainActor
protocol UserNotificationCenterClient: AnyObject {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func notificationSettings() async -> NotificationSystemSettings
    func add(_ request: UNNotificationRequest) async throws
    func pendingRequestIdentifiers() async -> [String]
    func deliveredRequestIdentifiers() async -> [String]
    func removePendingRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

// Adds no behavior: UNUserNotificationCenter already serializes its requests, so
// this only turns its Objective-C objects into Sendable values.
@MainActor
final class SystemUserNotificationCenterClient: UserNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func notificationSettings() async -> NotificationSystemSettings {
        NotificationSystemSettings(await center.notificationSettings())
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func pendingRequestIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredRequestIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

// deliver(_:) knows nothing about transitions on purpose: re-adding a request ID
// replaces it and alerts again, so what deserves a banner stays a decision of
// AttentionMonitor and AttentionNoticeStager. Removal always covers both pending
// and delivered requests, so an add racing a resolution leaves nothing behind.
@MainActor
final class AgentNotificationCenter {
    // Scopes startup cleanup to requests owned by this feature.
    nonisolated static let requestIdentifierPrefix =
        "io.github.cryks.shepherd.agent-attention."

    private nonisolated static let payloadSchema = 1
    private nonisolated static let payloadKind = "agent-attention"
    private nonisolated static let schemaKey = "shepherd.schema"
    private nonisolated static let kindKey = "shepherd.kind"
    private nonisolated static let notificationIDKey = "shepherd.notification-id"

    private let client: any UserNotificationCenterClient
    // Read at delivery time, not at staging, so a banner held for its excerpt
    // still plays the sound the user has selected by then.
    private let sound: @MainActor (AttentionNoticeKind) -> UNNotificationSound?

    // IDs submitted by this process, kept so termination cleanup needs no
    // asynchronous query; a crash instead leaves them to the startup removeAll.
    private var knownRequestIdentifiers: Set<String> = []
    // Queue tail. Each batch awaits the previous one, so an asynchronous add can
    // never land after a remove that was issued later.
    private var effectTask: Task<Void, Never>?
    private var effectGeneration = 0
    // Blocks queued work once cleanup has run, so nothing re-adds a request after
    // termination removed it.
    private var isTerminating = false

    convenience init() {
        self.init(client: SystemUserNotificationCenterClient()) {
            NotificationSoundSetting.shared.choice(for: $0).notificationSound
        }
    }

    init(
        client: any UserNotificationCenterClient,
        sound: @escaping @MainActor (AttentionNoticeKind) -> UNNotificationSound? = { _ in nil }
    ) {
        self.client = client
        self.sound = sound
    }

    // Alerts and sound only: agent notifications never use badge, time-sensitive,
    // or critical capabilities. Settings are re-read afterwards so a denial and a
    // later system change arrive through the same value.
    func requestAuthorization() async throws -> NotificationSystemSettings {
        _ = try await client.requestAuthorization(options: [.alert, .sound])
        return await systemSettings()
    }

    func systemSettings() async -> NotificationSystemSettings {
        await client.notificationSettings()
    }

    // Delivery failures are logged, not reported back to the state machine: the
    // machine must keep the transition it recorded, or every poll would retry the
    // failed add, and authorization can change without any transition at all.
    func apply(_ effects: [AttentionEffect]) {
        guard !effects.isEmpty, !isTerminating else { return }
        let precedingTask = effectTask
        effectGeneration += 1
        let generation = effectGeneration
        effectTask = Task { @MainActor [weak self] in
            await precedingTask?.value
            guard let self, !Task.isCancelled, !isTerminating else { return }
            for effect in effects {
                guard !Task.isCancelled, !isTerminating else { return }
                await applyEffect(effect)
            }
            if effectGeneration == generation {
                effectTask = nil
            }
        }
    }

    // Waits for whatever was the queue tail at call time. Tests use it to assert
    // effect order; setEnabled(false) uses it to see removeAll finish.
    func waitForPendingEffects() async {
        await effectTask?.value
    }

    private func applyEffect(_ effect: AttentionEffect) async {
        switch effect {
        case .deliver(let notice):
            do {
                try await deliver(notice)
            } catch {
                notificationLog.error(
                    "notification delivery failed: \(String(describing: error), privacy: .public)"
                )
            }
        case .remove(let id):
            remove(id)
        case .removeAll:
            await removeAllAgentNotifications()
        }
    }

    // A nil trigger is what makes macOS present the banner at once.
    func deliver(_ notice: AttentionNotice) async throws {
        let identifier = Self.requestIdentifier(for: notice.id)
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = notice.threadIdentifier
        content.userInfo = [
            Self.schemaKey: Self.payloadSchema,
            Self.kindKey: Self.payloadKind,
            Self.notificationIDKey: notice.id.rawValue,
        ]
        content.sound = sound(notice.kind)
        content.interruptionLevel = .active

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        let wasAlreadyKnown = knownRequestIdentifiers.contains(identifier)
        knownRequestIdentifiers.insert(identifier)
        do {
            try await client.add(request)
            // terminate() can run while add is suspended, so the request must be
            // removed again once macOS has accepted it.
            if isTerminating {
                knownRequestIdentifiers.remove(identifier)
                removeRequestIdentifiers([identifier])
            }
        } catch {
            // A failed replacement must not drop the identifier of a banner an
            // earlier transition already delivered under the same ID.
            if !wasAlreadyKnown {
                knownRequestIdentifiers.remove(identifier)
            }
            throw error
        }
    }

    func remove(_ id: AttentionNotificationID) {
        let identifier = Self.requestIdentifier(for: id)
        knownRequestIdentifiers.remove(identifier)
        removeRequestIdentifiers([identifier])
    }

    // Unions both sets: Notification Center no longer lists a request the user
    // dismissed by hand, while the known set still does.
    func removeAllAgentNotifications() async {
        let persisted = await managedRequestIdentifiers()
        let identifiers = Array(Set(persisted).union(knownRequestIdentifiers)).sorted()
        knownRequestIdentifiers.removeAll()
        removeRequestIdentifiers(identifiers)
    }

    // Cleanup must stay synchronous because the process may not live long enough
    // to await Notification Center. An add already suspended in the system API
    // removes itself when it returns.
    func terminate() {
        guard !isTerminating else { return }
        isTerminating = true
        effectGeneration += 1
        effectTask?.cancel()
        effectTask = nil
        let identifiers = knownRequestIdentifiers.sorted()
        knownRequestIdentifiers.removeAll()
        removeRequestIdentifiers(identifiers)
    }

    // A response can carry any payload macOS still has on disk, including one
    // written by an older schema, so nothing is trusted until the identifier and
    // the versioned userInfo agree.
    nonisolated static func attentionNotificationID(
        from request: UNNotificationRequest
    ) -> AttentionNotificationID? {
        guard request.identifier.hasPrefix(requestIdentifierPrefix),
              let schema = request.content.userInfo[schemaKey] as? Int,
              schema == payloadSchema,
              request.content.userInfo[kindKey] as? String == payloadKind,
              let rawValue = request.content.userInfo[notificationIDKey] as? String,
              rawValue.hasPrefix(AttentionNotificationID.managedPrefix) else {
            return nil
        }

        let id = AttentionNotificationID(rawValue: rawValue)
        guard request.identifier == requestIdentifier(for: id) else { return nil }
        return id
    }

    nonisolated static func requestIdentifier(for id: AttentionNotificationID) -> String {
        requestIdentifierPrefix + base64URLEncoded(id.rawValue)
    }

    private func managedRequestIdentifiers() async -> [String] {
        let pending = await client.pendingRequestIdentifiers()
        let delivered = await client.deliveredRequestIdentifiers()
        return Array(Set(pending + delivered).filter {
            $0.hasPrefix(Self.requestIdentifierPrefix)
        }).sorted()
    }

    private func removeRequestIdentifiers(_ identifiers: [String]) {
        guard !identifiers.isEmpty else { return }
        client.removePendingRequests(withIdentifiers: identifiers)
        client.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    private nonisolated static func base64URLEncoded(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// Two separate answers: isEnabled is the user's intent, systemSettings is what
// macOS currently permits. The switch therefore stays ON after a denial.
@Observable @MainActor
final class NotificationSettingsCoordinator {
    static let enabledKey = "AgentNotificationsEnabled"
    nonisolated static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!

    private(set) var isEnabled: Bool
    private(set) var systemSettings: NotificationSystemSettings = .notDetermined
    private(set) var authorizationError: String?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notificationCenter: AgentNotificationCenter
    @ObservationIgnored private let onEnabledChange: @MainActor (Bool) -> Void
    @ObservationIgnored private let systemSettingsOpener: @MainActor (URL) -> Bool
    // The Toggle can be flipped again while setEnabled is awaiting, so only the
    // newest call may publish a result after its await.
    @ObservationIgnored private var enablementGeneration: UInt64 = 0

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: AgentNotificationCenter,
        onEnabledChange: @escaping @MainActor (Bool) -> Void,
        systemSettingsOpener: @escaping @MainActor (URL) -> Bool = {
            NSWorkspace.shared.open($0)
        }
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.onEnabledChange = onEnabledChange
        self.systemSettingsOpener = systemSettingsOpener
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? false
    }

    // Sound joined the requested authorization options after installs were
    // already authorized for alerts alone, and such a grant never shows the
    // sound toggle in System Settings until it is requested once more. macOS
    // extends a determined authorization without prompting again, so this is
    // safe on every launch.
    func start() async {
        guard isEnabled else { return }
        enablementGeneration &+= 1
        await authorize(generation: enablementGeneration)
    }

    // The choice is persisted before any system call so a denial cannot rewrite
    // it. Turning OFF then waits for the removeAll that onEnabledChange caused
    // AttentionMonitor to emit, which is what makes the switch settle silently.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        enablementGeneration &+= 1
        let generation = enablementGeneration
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        onEnabledChange(enabled)

        if enabled {
            await authorize(generation: generation)
        } else {
            await notificationCenter.waitForPendingEffects()
            guard generation == enablementGeneration else { return }
            authorizationError = nil
        }
    }

    private func authorize(generation: UInt64) async {
        do {
            let settings = try await notificationCenter.requestAuthorization()
            guard generation == enablementGeneration else { return }
            systemSettings = settings
            authorizationError = nil
        } catch {
            let settings = await notificationCenter.systemSettings()
            guard generation == enablementGeneration else { return }
            authorizationError = error.localizedDescription
            systemSettings = settings
        }
    }

    // macOS reports no change when the user edits notification settings, so the
    // Settings scene and app activation re-read them instead.
    func refresh() async {
        let settings = await notificationCenter.systemSettings()
        systemSettings = settings
        if settings.authorizationStatus != .notDetermined {
            authorizationError = nil
        }
    }

    // macOS offers no way to open Shepherd's own row, only the Notifications
    // pane, and the open can fail, which is why the caller gets a Bool.
    @discardableResult
    func openSystemNotificationSettings() -> Bool {
        systemSettingsOpener(Self.systemSettingsURL)
    }
}
