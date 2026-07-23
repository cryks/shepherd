// Verifies the UserNotifications adapter without registering the XCTest process
// for notifications. The fake client records the exact UNNotificationRequest and
// removal calls while authorization and persisted settings are controlled with
// plain values and an isolated UserDefaults suite.

import Foundation
import UserNotifications
import XCTest
@testable import Shepherd

final class NotificationServiceTests: XCTestCase {
    @MainActor
    func testDeliveryBuildsImmediateSilentActiveRequestAndRoundTripsID() async throws {
        let client = RecordingNotificationCenterClient()
        let center = AgentNotificationCenter(client: client)
        let notice = makeNotice(id: "attention.v1.remote:alpha/terminal:7")

        try await center.deliver(notice)

        let request = try XCTUnwrap(client.addedRequests.only)
        XCTAssertTrue(request.identifier.hasPrefix(AgentNotificationCenter.requestIdentifierPrefix))
        XCTAssertEqual(request.content.title, "🔴 Fix authentication")
        XCTAssertEqual(request.content.subtitle, "Build Mac · shepherd")
        XCTAssertEqual(request.content.body, "codex · feature/login")
        XCTAssertEqual(request.content.threadIdentifier, "source:remote-alpha")
        XCTAssertNil(request.content.sound)
        XCTAssertEqual(request.content.interruptionLevel, .active)
        XCTAssertNil(request.trigger)
        XCTAssertEqual(
            AgentNotificationCenter.attentionNotificationID(from: request),
            notice.id
        )

        center.terminate()
        XCTAssertEqual(client.pendingRemovalCalls, [[request.identifier]])
        XCTAssertEqual(client.deliveredRemovalCalls, [[request.identifier]])

        center.apply([.deliver(makeNotice(id: "attention.v1.after-termination"))])
        await center.waitForPendingEffects()
        XCTAssertEqual(client.addedRequests.count, 1)
    }

    @MainActor
    func testParserRejectsForeignMalformedAndMismatchedRequests() async throws {
        let client = RecordingNotificationCenterClient()
        let center = AgentNotificationCenter(client: client)
        let notice = makeNotice(id: "attention.v1.local-terminal")
        try await center.deliver(notice)
        let valid = try XCTUnwrap(client.addedRequests.only)

        XCTAssertNil(AgentNotificationCenter.attentionNotificationID(
            from: request(identifier: "another-feature", userInfo: valid.content.userInfo)
        ))

        var wrongKind = valid.content.userInfo
        wrongKind["shepherd.kind"] = "something-else"
        XCTAssertNil(AgentNotificationCenter.attentionNotificationID(
            from: request(identifier: valid.identifier, userInfo: wrongKind)
        ))

        var wrongSchema = valid.content.userInfo
        wrongSchema["shepherd.schema"] = 2
        XCTAssertNil(AgentNotificationCenter.attentionNotificationID(
            from: request(identifier: valid.identifier, userInfo: wrongSchema)
        ))

        var mismatchedID = valid.content.userInfo
        mismatchedID["shepherd.notification-id"] = "attention.v1.different"
        XCTAssertNil(AgentNotificationCenter.attentionNotificationID(
            from: request(identifier: valid.identifier, userInfo: mismatchedID)
        ))
    }

    @MainActor
    func testRemoveTargetsPendingAndDeliveredCollections() {
        let client = RecordingNotificationCenterClient()
        let center = AgentNotificationCenter(client: client)
        let id = AttentionNotificationID(rawValue: "attention.v1.agent-1")
        let identifier = AgentNotificationCenter.requestIdentifier(for: id)

        center.remove(id)

        XCTAssertEqual(client.pendingRemovalCalls, [[identifier]])
        XCTAssertEqual(client.deliveredRemovalCalls, [[identifier]])
    }

    @MainActor
    func testEffectBatchesWaitForEarlierDeliveryBeforeRemoving() async {
        let client = RecordingNotificationCenterClient()
        let center = AgentNotificationCenter(client: client)
        let notice = makeNotice(id: "attention.v1.serial-agent")

        center.apply([.deliver(notice)])
        center.apply([.remove(notice.id)])
        await center.waitForPendingEffects()

        XCTAssertEqual(
            client.events,
            ["add-start", "add-finish", "remove-pending", "remove-delivered"]
        )
    }

    @MainActor
    func testStartupRemoveAllRemovesOnlyManagedIdentifiers() async {
        let first = AgentNotificationCenter.requestIdentifier(
            for: AttentionNotificationID(rawValue: "attention.v1.first")
        )
        let second = AgentNotificationCenter.requestIdentifier(
            for: AttentionNotificationID(rawValue: "attention.v1.second")
        )
        let client = RecordingNotificationCenterClient()
        client.pendingIdentifiers = ["foreign.pending", first]
        client.deliveredIdentifiers = [second, first, "foreign.delivered"]
        let center = AgentNotificationCenter(client: client)

        center.apply([.removeAll])
        await center.waitForPendingEffects()

        XCTAssertEqual(client.pendingRemovalCalls, [[first, second].sorted()])
        XCTAssertEqual(client.deliveredRemovalCalls, [[first, second].sorted()])
    }

    @MainActor
    func testAuthorizationRequestsOnlyAlertsAndReturnsLatestSettings() async throws {
        let client = RecordingNotificationCenterClient()
        client.settings = .authorized
        let center = AgentNotificationCenter(client: client)

        let settings = try await center.requestAuthorization()

        XCTAssertEqual(client.authorizationOptions, [[.alert]])
        XCTAssertEqual(settings, .authorized)
    }

    @MainActor
    func testTerminationRemovesAnAddThatFinishesAfterTheFence() async throws {
        let client = RecordingNotificationCenterClient()
        client.suspendsAdds = true
        let addStarted = expectation(description: "notification add started")
        client.onAddStarted = { addStarted.fulfill() }
        let center = AgentNotificationCenter(client: client)
        let notice = makeNotice(id: "attention.v1.in-flight")
        let identifier = AgentNotificationCenter.requestIdentifier(for: notice.id)
        let delivery = Task { @MainActor in
            try await center.deliver(notice)
        }

        await fulfillment(of: [addStarted], timeout: 1.0)
        center.terminate()
        client.resumeSuspendedAdd()
        try await delivery.value

        XCTAssertEqual(client.pendingRemovalCalls, [[identifier], [identifier]])
        XCTAssertEqual(client.deliveredRemovalCalls, [[identifier], [identifier]])
    }

    @MainActor
    func testCoordinatorDefaultsOffAndDenialKeepsPersistedSwitchOn() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = RecordingNotificationCenterClient()
        client.settings = .denied
        let center = AgentNotificationCenter(client: client)
        var enabledChanges: [Bool] = []
        let coordinator = NotificationSettingsCoordinator(
            defaults: defaults,
            notificationCenter: center,
            onEnabledChange: { enabledChanges.append($0) }
        )

        XCTAssertFalse(coordinator.isEnabled)

        await coordinator.setEnabled(true)

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertTrue(defaults.bool(forKey: NotificationSettingsCoordinator.enabledKey))
        XCTAssertEqual(enabledChanges, [true])
        XCTAssertEqual(client.authorizationOptions, [[.alert]])
        XCTAssertEqual(coordinator.systemSettings.authorizationStatus, .denied)
        XCTAssertNil(coordinator.authorizationError)
    }

    @MainActor
    func testCoordinatorOffStopsEffectsAndRemovesManagedNotifications() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: NotificationSettingsCoordinator.enabledKey)
        let managed = AgentNotificationCenter.requestIdentifier(
            for: AttentionNotificationID(rawValue: "attention.v1.still-blocked")
        )
        let client = RecordingNotificationCenterClient()
        client.deliveredIdentifiers = [managed, "foreign"]
        let center = AgentNotificationCenter(client: client)
        var enabledChanges: [Bool] = []
        let coordinator = NotificationSettingsCoordinator(
            defaults: defaults,
            notificationCenter: center,
            onEnabledChange: { enabled in
                enabledChanges.append(enabled)
                if !enabled {
                    center.apply([.removeAll])
                }
            }
        )

        await coordinator.setEnabled(false)

        XCTAssertFalse(coordinator.isEnabled)
        XCTAssertFalse(defaults.bool(forKey: NotificationSettingsCoordinator.enabledKey))
        XCTAssertEqual(enabledChanges, [false])
        XCTAssertEqual(client.pendingRemovalCalls, [[managed]])
        XCTAssertEqual(client.deliveredRemovalCalls, [[managed]])
    }

    @MainActor
    func testOlderOffCompletionCannotClearNewerOnFailure() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: NotificationSettingsCoordinator.enabledKey)

        let client = RecordingNotificationCenterClient()
        client.suspendsAdds = true
        client.authorizationFailure = NotificationTestError.authorizationFailed
        let addStarted = expectation(description: "preceding notification add started")
        client.onAddStarted = { addStarted.fulfill() }
        let center = AgentNotificationCenter(client: client)
        center.apply([.deliver(makeNotice(id: "attention.v1.before-toggle"))])
        await fulfillment(of: [addStarted], timeout: 1.0)

        let disablingStarted = expectation(description: "disable effect enqueued")
        var enabledChanges: [Bool] = []
        let coordinator = NotificationSettingsCoordinator(
            defaults: defaults,
            notificationCenter: center,
            onEnabledChange: { enabled in
                enabledChanges.append(enabled)
                if enabled {
                    return
                }
                center.apply([.removeAll])
                disablingStarted.fulfill()
            }
        )
        let disabling = Task { @MainActor in
            await coordinator.setEnabled(false)
        }
        await fulfillment(of: [disablingStarted], timeout: 1.0)

        await coordinator.setEnabled(true)
        XCTAssertNotNil(coordinator.authorizationError)

        client.resumeSuspendedAdd()
        await disabling.value

        XCTAssertTrue(coordinator.isEnabled)
        XCTAssertEqual(enabledChanges, [false, true])
        XCTAssertNotNil(coordinator.authorizationError)
    }

    @MainActor
    func testCoordinatorRefreshesSettingsAndOpensNotificationsPane() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let client = RecordingNotificationCenterClient()
        client.settings = .authorized
        let center = AgentNotificationCenter(client: client)
        var openedURLs: [URL] = []
        let coordinator = NotificationSettingsCoordinator(
            defaults: defaults,
            notificationCenter: center,
            onEnabledChange: { _ in },
            systemSettingsOpener: {
                openedURLs.append($0)
                return true
            }
        )

        await coordinator.refresh()
        let didOpen = coordinator.openSystemNotificationSettings()

        XCTAssertEqual(coordinator.systemSettings, .authorized)
        XCTAssertTrue(didOpen)
        XCTAssertEqual(openedURLs, [NotificationSettingsCoordinator.systemSettingsURL])
    }

    @MainActor
    private func makeNotice(id: String) -> AttentionNotice {
        AttentionNotice(
            id: AttentionNotificationID(rawValue: id),
            sourcePaneID: SourcePaneID(sourceID: .local, paneID: "w1:p1"),
            threadIdentifier: "source:remote-alpha",
            title: "🔴 Fix authentication",
            subtitle: "Build Mac · shepherd",
            body: "codex · feature/login"
        )
    }

    private func request(
        identifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.userInfo = userInfo
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "NotificationServiceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@MainActor
private final class RecordingNotificationCenterClient: UserNotificationCenterClient {
    var authorizationOptions: [UNAuthorizationOptions] = []
    var authorizationGranted = false
    var authorizationFailure: Error?
    var settings: NotificationSystemSettings = .notDetermined
    var addedRequests: [UNNotificationRequest] = []
    var pendingIdentifiers: [String] = []
    var deliveredIdentifiers: [String] = []
    var pendingRemovalCalls: [[String]] = []
    var deliveredRemovalCalls: [[String]] = []
    var events: [String] = []
    var suspendsAdds = false
    var onAddStarted: (() -> Void)?
    private var suspendedAddContinuation: CheckedContinuation<Void, Never>?

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        authorizationOptions.append(options)
        if let authorizationFailure {
            throw authorizationFailure
        }
        return authorizationGranted
    }

    func notificationSettings() async -> NotificationSystemSettings {
        settings
    }

    func add(_ request: UNNotificationRequest) async throws {
        events.append("add-start")
        addedRequests.append(request)
        onAddStarted?()
        if suspendsAdds {
            await withCheckedContinuation { continuation in
                suspendedAddContinuation = continuation
            }
        } else {
            await Task.yield()
        }
        events.append("add-finish")
    }

    func resumeSuspendedAdd() {
        suspendedAddContinuation?.resume()
        suspendedAddContinuation = nil
    }

    func pendingRequestIdentifiers() async -> [String] {
        pendingIdentifiers
    }

    func deliveredRequestIdentifiers() async -> [String] {
        deliveredIdentifiers
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        events.append("remove-pending")
        pendingRemovalCalls.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        events.append("remove-delivered")
        deliveredRemovalCalls.append(identifiers)
    }
}

private enum NotificationTestError: LocalizedError {
    case authorizationFailed

    var errorDescription: String? {
        "Authorization failed"
    }
}

private extension NotificationSystemSettings {
    static let authorized = NotificationSystemSettings(
        authorizationStatus: .authorized,
        alertSetting: .enabled,
        notificationCenterSetting: .enabled,
        alertStyle: .banner
    )

    static let denied = NotificationSystemSettings(
        authorizationStatus: .denied,
        alertSetting: .disabled,
        notificationCenterSetting: .disabled,
        alertStyle: .none
    )
}

private extension Array {
    var only: Element? {
        count == 1 ? self[0] : nil
    }
}
