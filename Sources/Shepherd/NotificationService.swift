// Owns Shepherd's boundary to macOS UserNotifications and the persisted switch
// that enables that boundary. AttentionMonitor owns agent-state transitions and
// notification identity; this file only translates an AttentionNotice into an
// immediate system notification, removes requests by that identity, and reports
// the operating system's current authorization settings.
//
// Request identifiers and userInfo are namespaced and versioned. Notification
// clicks return only the immutable AttentionNotificationID; current pane aliases
// and source availability are deliberately not persisted in Notification Center
// because AttentionMonitor resolves those against its latest snapshot.
//
// The UserNotificationCenterClient protocol keeps authorization, delivery, and
// removal testable without registering the test runner with Notification Center.
// All operations are MainActor-isolated to preserve ordering with AttentionMonitor.
// The one exception is attentionNotificationID(from:), which is nonisolated so an
// UNUserNotificationCenterDelegate callback can validate a response before hopping
// to the MainActor.

import AppKit
import Foundation
import Observation
import UserNotifications
import os

private let notificationLog = Logger(
    subsystem: "io.github.cryks.shepherd",
    category: "notifications"
)

/// A Sendable projection of the macOS notification settings Shepherd uses.
/// Sound and time-sensitive settings are omitted because agent notifications are
/// silent, use the normal active interruption level, and respect Focus.
struct NotificationSystemSettings: Equatable, Sendable {
    enum AuthorizationStatus: Equatable, Sendable {
        case notDetermined
        case denied
        case authorized
        case provisional
        /// Preserves forward compatibility if macOS adds an authorization state.
        case unknown
    }

    enum Setting: Equatable, Sendable {
        case notSupported
        case disabled
        case enabled
        /// Preserves forward compatibility if macOS adds a per-feature state.
        case unknown
    }

    enum AlertStyle: Equatable, Sendable {
        case none
        case banner
        case alert
        /// Preserves forward compatibility if macOS adds an alert style.
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

    /// Initial display state before the first asynchronous settings read completes.
    static let notDetermined = NotificationSystemSettings(
        authorizationStatus: .notDetermined,
        alertSetting: .notSupported,
        notificationCenterSetting: .notSupported,
        alertStyle: .none
    )

    /// Whether the authorization decision allows Shepherd to submit alerts. This
    /// does not imply that both banner and Notification Center destinations are on;
    /// the settings UI reads the individual fields to report a partially disabled
    /// system configuration.
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

/// Narrow projection of UNUserNotificationCenter used by AgentNotificationCenter.
/// Tests inject a recorder while production uses SystemUserNotificationCenterClient.
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

/// Production UserNotifications client. UNUserNotificationCenter serializes the
/// requests it receives; this wrapper only maps its Objective-C settings objects
/// into Sendable values and extracts identifiers needed for scoped cleanup.
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

/// Delivers AttentionMonitor effects through macOS Notification Center.
///
/// `deliver(_:)` is intentionally transition-agnostic: adding the same request ID
/// replaces and alerts again, so the attention pipeline (AttentionMonitor and
/// the excerpt-holding AttentionNoticeStager between it and this class) decides
/// when a blocked/done transition warrants a call. Removal always targets both
/// pending and delivered collections so an immediate add racing with a state
/// resolution cannot leave a stale notification behind.
@MainActor
final class AgentNotificationCenter {
    /// Prefix scopes startup cleanup to notifications owned by this feature.
    nonisolated static let requestIdentifierPrefix =
        "io.github.cryks.shepherd.agent-attention."

    private nonisolated static let payloadSchema = 1
    private nonisolated static let payloadKind = "agent-attention"
    private nonisolated static let schemaKey = "shepherd.schema"
    private nonisolated static let kindKey = "shepherd.kind"
    private nonisolated static let notificationIDKey = "shepherd.notification-id"

    private let client: any UserNotificationCenterClient

    /// IDs submitted during this process generation. They make termination cleanup
    /// synchronous; the startup removeAll effect recovers requests left by a crash.
    private var knownRequestIdentifiers: Set<String> = []
    /// Tail of the effect queue. Each batch awaits the preceding batch before it
    /// starts, so an asynchronous add can never finish after a later remove.
    private var effectTask: Task<Void, Never>?
    private var effectGeneration = 0
    /// Once application termination begins, no queued transition may submit a
    /// request after synchronous cleanup has removed the process-owned IDs.
    private var isTerminating = false

    convenience init() {
        self.init(client: SystemUserNotificationCenterClient())
    }

    init(client: any UserNotificationCenterClient) {
        self.client = client
    }

    /// Requests only alert authorization. Agent notifications never request or set
    /// a sound, badge, time-sensitive, or critical capability. The returned value is
    /// read after the request completes so a denial and later system-level changes
    /// use the same settings representation.
    func requestAuthorization() async throws -> NotificationSystemSettings {
        _ = try await client.requestAuthorization(options: [.alert])
        return await systemSettings()
    }

    func systemSettings() async -> NotificationSystemSettings {
        await client.notificationSettings()
    }

    /// Serial effect sink passed directly to AttentionMonitor.effectHandler. A new
    /// batch waits for the previous batch, and effects within a batch are awaited in
    /// array order. Delivery failures are logged rather than fed back into the state
    /// machine: authorization and OS delivery can change independently, while the
    /// monitor must retain the transition so a failed add is not retried per poll.
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

    /// Waits for the batch that was the queue tail at call time. Production does
    /// not need to block polling on delivery; tests use this to assert effect order.
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

    /// Immediately displays a silent normal-priority notification. The content is
    /// already composed by AttentionMonitor, keeping source/workspace presentation
    /// out of this operating-system adapter.
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
        content.sound = nil
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
            // terminate() may run while add is suspended. Removing once more
            // after the request is accepted closes the add-after-remove race.
            if isTerminating {
                knownRequestIdentifiers.remove(identifier)
                removeRequestIdentifiers([identifier])
            }
        } catch {
            // A failed replacement must not forget the notification delivered by
            // an earlier successful transition with the same stable identifier.
            if !wasAlreadyKnown {
                knownRequestIdentifiers.remove(identifier)
            }
            throw error
        }
    }

    /// Removes a resolved attention state without waiting for Notification Center.
    func remove(_ id: AttentionNotificationID) {
        let identifier = Self.requestIdentifier(for: id)
        knownRequestIdentifiers.remove(identifier)
        removeRequestIdentifiers([identifier])
    }

    /// Removes every managed request, including requests manually dismissed from
    /// Notification Center that remain in the process-local known set.
    func removeAllAgentNotifications() async {
        let persisted = await managedRequestIdentifiers()
        let identifiers = Array(Set(persisted).union(knownRequestIdentifiers)).sorted()
        knownRequestIdentifiers.removeAll()
        removeRequestIdentifiers(identifiers)
    }

    /// Fences the effect queue and synchronously removes requests submitted by this
    /// process. An add already suspended in the system API removes itself again on
    /// return; the next startup removeAll handles requests left by a process crash.
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

    /// Validates that a response belongs to this feature and that its versioned
    /// payload agrees with the request identifier before returning the opaque ID.
    /// The app delegate can call this from its nonisolated UserNotifications callback.
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

/// Persisted user intent plus the current macOS authorization state.
/// Shepherd's switch remains ON after denial: isEnabled answers whether Shepherd
/// should attempt future transitions, while systemSettings answers whether macOS
/// currently permits their presentation.
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
    /// Distinguishes overlapping async Toggle operations. Only the newest call may
    /// publish authorization results or clear an error after an await.
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

    /// Persists the user's choice before performing operating-system work. Turning
    /// ON resets AttentionMonitor's baseline through onEnabledChange, then requests
    /// permission; denial updates systemSettings but does not rewrite isEnabled.
    /// Turning OFF first stops transition delivery, then waits for the removeAll
    /// effect emitted by AttentionMonitor through the serialized delivery queue.
    func setEnabled(_ enabled: Bool) async {
        guard enabled != isEnabled else { return }
        enablementGeneration &+= 1
        let generation = enablementGeneration
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.enabledKey)
        onEnabledChange(enabled)

        if enabled {
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
        } else {
            await notificationCenter.waitForPendingEffects()
            guard generation == enablementGeneration else { return }
            authorizationError = nil
        }
    }

    /// Re-reads settings after the Settings scene appears or Shepherd becomes active.
    /// This is also how notifications resume after the user changes macOS settings;
    /// the persisted Shepherd switch is not rewritten.
    func refresh() async {
        let settings = await notificationCenter.systemSettings()
        systemSettings = settings
        if settings.authorizationStatus != .notDetermined {
            authorizationError = nil
        }
    }

    /// Opens the Notifications pane identifier understood by System Settings.
    /// macOS exposes no API for opening Shepherd's app-specific detail row, so this
    /// operation is best-effort and its Bool result is left to the caller to surface.
    @discardableResult
    func openSystemNotificationSettings() -> Bool {
        systemSettingsOpener(Self.systemSettingsURL)
    }
}
