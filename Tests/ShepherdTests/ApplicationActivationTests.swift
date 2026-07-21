// Verifies the notification-to-terminal activation boundary without asking
// AppKit or UserNotifications to change the foreground application. Injected
// state drives the process-wide activation coordinator, while an explicit gate
// proves that the async notification action does not return early.

import XCTest
@testable import Shepherd

final class ApplicationActivationTests: XCTestCase {
    @MainActor
    func testAlreadyActiveApplicationDoesNotRequestActivation() async {
        var requestCount = 0
        let coordinator = ApplicationActivationCoordinator(
            isActive: { true },
            requestActivation: { requestCount += 1 }
        )

        let result = await coordinator.activate()

        XCTAssertEqual(result, .active)
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testConcurrentWaitersShareActivationUntilDidBecomeActive() async {
        var active = false
        var requestCount = 0
        var returnCount = 0
        let requestStarted = expectation(description: "activation requested")
        let secondStarted = expectation(description: "second activation started")
        let coordinator = ApplicationActivationCoordinator(
            isActive: { active },
            requestActivation: {
                requestCount += 1
                requestStarted.fulfill()
            }
        )
        let first = Task { @MainActor in
            let result = await coordinator.activate()
            returnCount += 1
            return result
        }

        await fulfillment(of: [requestStarted], timeout: 1.0)
        let second = Task { @MainActor in
            secondStarted.fulfill()
            let result = await coordinator.activate()
            returnCount += 1
            return result
        }
        await fulfillment(of: [secondStarted], timeout: 1.0)

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(returnCount, 0)

        active = true
        coordinator.didBecomeActive()
        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertEqual(firstResult, .active)
        XCTAssertEqual(secondResult, .active)
        XCTAssertEqual(returnCount, 2)
    }

    @MainActor
    func testActivationTimeoutReleasesWaiter() async {
        var requestCount = 0
        var timeoutCount = 0
        let coordinator = ApplicationActivationCoordinator(
            activationTimeout: .milliseconds(5),
            isActive: { false },
            requestActivation: { requestCount += 1 },
            onTimeout: { timeoutCount += 1 }
        )

        let result = await coordinator.activate()

        XCTAssertEqual(result, .timedOut)
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(timeoutCount, 1)
    }

    @MainActor
    func testSynchronousActivationReturnsWithoutDelegateCallback() async {
        var active = false
        var requestCount = 0
        let coordinator = ApplicationActivationCoordinator(
            isActive: { active },
            requestActivation: {
                requestCount += 1
                active = true
            }
        )

        let result = await coordinator.activate()

        XCTAssertEqual(result, .active)
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testShutdownReleasesWaiterAndRejectsLaterActivation() async {
        var requestCount = 0
        let requestStarted = expectation(description: "activation requested")
        let coordinator = ApplicationActivationCoordinator(
            isActive: { false },
            requestActivation: {
                requestCount += 1
                requestStarted.fulfill()
            }
        )
        let pending = Task { @MainActor in
            await coordinator.activate()
        }

        await fulfillment(of: [requestStarted], timeout: 1.0)
        coordinator.shutdown()
        let pendingResult = await pending.value
        let laterResult = await coordinator.activate()

        XCTAssertEqual(pendingResult, .shutDown)
        XCTAssertEqual(laterResult, .shutDown)
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testNotificationActionWaitsForHandlerToFinish() async {
        var events: [String] = []
        let handlerStarted = expectation(description: "notification handler started")
        let gate = NotificationActionGate()
        let delegate = ShepherdApplicationDelegate()
        let notificationID = AttentionNotificationID(rawValue: "attention.v1.local")
        delegate.notificationActionHandler = { receivedID in
            XCTAssertEqual(receivedID, notificationID)
            events.append("handler-start")
            handlerStarted.fulfill()
            await gate.wait()
            events.append("handler-finish")
        }
        let action = Task { @MainActor in
            await delegate.performNotificationAction(notificationID)
            events.append("return")
        }

        await fulfillment(of: [handlerStarted], timeout: 1.0)
        XCTAssertEqual(events, ["handler-start"])

        gate.open()
        await action.value

        XCTAssertEqual(events, ["handler-start", "handler-finish", "return"])
    }
}

@MainActor
private final class NotificationActionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            precondition(self.continuation == nil)
            self.continuation = continuation
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume()
    }
}
