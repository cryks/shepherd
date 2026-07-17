// Verifies the Store's poll-only synchronization without depending on a real socket
// or production intervals. The tests control session.snapshot completion, failure,
// protocol mismatch, poll ticks, stop, and suspend/resume during sleep, covering the
// contract that the first response is published exactly once and the boundary that a
// slow RPC is never executed concurrently with another.

import Foundation
import XCTest
@testable import Shepherd

final class StartupSynchronizationTests: XCTestCase {
    @MainActor
    func test最初のSnapshot一回でReadyになる() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 1, name: "session.snapshot")
        let pane = makePane(id: "w1:p1", title: "Initial")
        let store = makeStore(snapshots: snapshots)
        defer { snapshots.finish() }

        store.start()
        assertSynchronizing(store)
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)

        snapshots.succeed(makeSnapshot(panes: [pane]), call: 0)

        guard let published = await readySnapshot(from: store) else {
            return XCTFail("最初のsession.snapshotが公開されなかった")
        }
        XCTAssertEqual(snapshots.callCount, 1)
        XCTAssertEqual(published.panes, [pane.paneId: pane])
    }

    @MainActor
    func testPollでSnapshotを更新する() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 2, name: "session.snapshot")
        let first = makePane(id: "w1:p1", title: "First")
        let refreshed = makePane(id: "w1:p1", title: "Refreshed")
        let store = makeStore(snapshots: snapshots, pollInterval: .milliseconds(10))
        defer { snapshots.finish() }

        store.start()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        snapshots.succeed(makeSnapshot(panes: [first]), call: 0)
        guard await readySnapshot(from: store) != nil else {
            return XCTFail("初回snapshotが公開されなかった")
        }

        await fulfillment(of: [snapshots.started(1)], timeout: 1.0)
        snapshots.succeed(makeSnapshot(panes: [refreshed]), call: 1)

        let updated = await waitUntil {
            guard case let .ready(snapshot) = store.state else { return false }
            return snapshot.panes[first.paneId]?.terminalTitleStripped == "Refreshed"
        }
        XCTAssertTrue(updated)
    }

    @MainActor
    func test失敗した初回取得を次のPollで再試行する() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 2, name: "session.snapshot")
        let pane = makePane(id: "w1:p1", title: "Retried")
        let store = makeStore(snapshots: snapshots, pollInterval: .milliseconds(20))
        defer { snapshots.finish() }

        store.start()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        snapshots.fail(StubError.transientSnapshot, call: 0)
        await fulfillment(of: [snapshots.returned(0)], timeout: 1.0)

        let becameDisconnected = await waitUntil { isDisconnected(store) }
        XCTAssertTrue(becameDisconnected)

        await fulfillment(of: [snapshots.started(1)], timeout: 1.0)
        snapshots.succeed(makeSnapshot(panes: [pane]), call: 1)

        guard let published = await readySnapshot(from: store) else {
            return XCTFail("pollの再試行後もreadyにならなかった")
        }
        XCTAssertEqual(published.panes, [pane.paneId: pane])
    }

    @MainActor
    func test遅いSnapshotへPollTickを重ねない() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 2, name: "session.snapshot")
        let pane = makePane(id: "w1:p1", title: "Slow")
        let store = makeStore(snapshots: snapshots, pollInterval: .milliseconds(2))
        defer { snapshots.finish() }

        store.start()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        try? await Task.sleep(for: .milliseconds(15))
        XCTAssertEqual(snapshots.callCount, 1, "進行中のsnapshotへpollが重複した")

        snapshots.succeed(makeSnapshot(panes: [pane]), call: 0)
        guard await readySnapshot(from: store) != nil else {
            return XCTFail("遅いsnapshotが公開されなかった")
        }

        await fulfillment(of: [snapshots.started(1)], timeout: 1.0)
        XCTAssertEqual(snapshots.callCount, 2, "完了後のpollが次のsnapshotを開始しなかった")
    }

    @MainActor
    func testSnapshotのProtocol不一致を公開しない() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 1, name: "session.snapshot")
        let pane = makePane(id: "w1:p1", title: "Unsupported")
        let store = makeStore(snapshots: snapshots)
        defer { snapshots.finish() }

        store.start()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        snapshots.succeed(
            makeSnapshot(
                panes: [pane],
                protocolVersion: Herdr.supportedProtocol + 1
            ),
            call: 0
        )

        let becameMismatch = await waitUntil {
            guard case .protocolMismatch(Herdr.supportedProtocol + 1) = store.state else {
                return false
            }
            return true
        }
        XCTAssertTrue(becameMismatch)
        XCTAssertTrue(store.panes.isEmpty)
    }

    @MainActor
    func testStop後に完了したSnapshotを公開せず再開もしない() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 1, name: "session.snapshot")
        let pane = makePane(id: "w1:p1", title: "Stopped")
        let store = makeStore(snapshots: snapshots)
        defer { snapshots.finish() }

        store.start()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        store.stop()
        snapshots.succeed(makeSnapshot(panes: [pane]), call: 0)
        await fulfillment(of: [snapshots.returned(0)], timeout: 1.0)
        await drainMainActor()

        XCTAssertTrue(isDisconnected(store))
        XCTAssertTrue(store.panes.isEmpty)

        store.start()
        XCTAssertEqual(snapshots.callCount, 1, "stop後のStoreがpollを再開した")
    }

    @MainActor
    func testSuspend中はPollを止めResumeで直ちに再取得する() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 2, name: "session.snapshot")
        let stale = makePane(id: "w1:p1", title: "Stale")
        let fresh = makePane(id: "w1:p1", title: "Fresh")
        let store = makeStore(snapshots: snapshots, pollInterval: .milliseconds(2))
        defer {
            store.stop()
            snapshots.finish()
        }

        store.start()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        store.suspendPolling()

        // The result of an in-flight RPC cancelled by suspend is not reflected into state.
        snapshots.succeed(makeSnapshot(panes: [stale]), call: 0)
        await fulfillment(of: [snapshots.returned(0)], timeout: 1.0)
        await drainMainActor()
        assertSynchronizing(store)

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(snapshots.callCount, 1, "suspend中にpollが次の取得を始めた")

        store.resumePolling()
        await fulfillment(of: [snapshots.started(1)], timeout: 1.0)
        snapshots.succeed(makeSnapshot(panes: [fresh]), call: 1)
        guard let published = await readySnapshot(from: store) else {
            return XCTFail("resume後のsnapshotが公開されなかった")
        }
        XCTAssertEqual(published.panes[fresh.paneId]?.terminalTitleStripped, "Fresh")
    }

    @MainActor
    func testStart前にSuspendしたStoreはResumeまで取得しない() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 1, name: "session.snapshot")
        let pane = makePane(id: "w1:p1", title: "Deferred")
        let store = makeStore(snapshots: snapshots, pollInterval: .milliseconds(5))
        defer {
            store.stop()
            snapshots.finish()
        }

        // Path where a remote tunnel becomes ready while entering sleep: suspend first, start after.
        store.suspendPolling()
        store.start()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(snapshots.callCount, 0, "suspend中のstartが取得を始めた")

        store.resumePolling()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        snapshots.succeed(makeSnapshot(panes: [pane]), call: 0)
        guard await readySnapshot(from: store) != nil else {
            return XCTFail("resume後もreadyにならなかった")
        }
    }

    @MainActor
    func testPollIntervalを実行中に差し替える() async {
        let snapshots = ControlledCalls<HerdrSessionSnapshot>(count: 2, name: "session.snapshot")
        let store = makeStore(snapshots: snapshots, pollInterval: .seconds(60))
        defer {
            store.stop()
            snapshots.finish()
        }

        store.start()
        await fulfillment(of: [snapshots.started(0)], timeout: 1.0)
        snapshots.succeed(makeSnapshot(panes: []), call: 0)
        guard await readySnapshot(from: store) != nil else {
            return XCTFail("初回snapshotが公開されなかった")
        }

        store.setPollInterval(.milliseconds(10))

        XCTAssertEqual(store.pollInterval, .milliseconds(10))
        await fulfillment(of: [snapshots.started(1)], timeout: 1.0)
    }

    @MainActor
    private func makeStore(
        snapshots: ControlledCalls<HerdrSessionSnapshot>,
        pollInterval: Duration = .milliseconds(200)
    ) -> Store {
        Store(
            dataSource: StoreDataSource(
                snapshot: { try await snapshots.invoke() },
                worktrees: { _ in WorktreeListResult(worktrees: []) }
            ),
            pollInterval: pollInterval
        )
    }

    private func makeSnapshot(
        panes: [Pane],
        protocolVersion: Int = Herdr.supportedProtocol
    ) -> HerdrSessionSnapshot {
        HerdrSessionSnapshot(
            version: "test",
            protocolVersion: protocolVersion,
            agents: panes,
            workspaces: panes.isEmpty ? [] : [
                Workspace(workspaceId: "w1", label: "Workspace", number: 1),
            ]
        )
    }

    private func makePane(id: String, title: String) -> Pane {
        Pane(
            agent: "codex",
            agentStatus: .working,
            paneId: id,
            workspaceId: "w1",
            terminalId: "terminal-\(id)",
            terminalTitleStripped: title,
            tokens: PaneTokens(agentKind: "primary")
        )
    }

    @MainActor
    private func assertSynchronizing(
        _ store: Store,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .synchronizing = store.state else {
            return XCTFail(
                "同期中のstateが\(String(describing: store.state))だった",
                file: file,
                line: line
            )
        }
    }

    @MainActor
    private func isDisconnected(_ store: Store) -> Bool {
        guard case .disconnected = store.state else { return false }
        return true
    }

    @MainActor
    private func readySnapshot(from store: Store) async -> AgentSnapshot? {
        let becameReady = await waitUntil {
            if case .ready = store.state { return true }
            return false
        }
        guard becameReady, case let .ready(snapshot) = store.state else { return nil }
        return snapshot
    }

    /// XCTestExpectation pins the RPC start points; this wait only observes state changes that have returned to the MainActor.
    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    /// Yields the executor to already-enqueued MainActor tasks so fixed-duration sleeps do not race against shutdown.
    @MainActor
    private func drainMainActor() async {
        for _ in 0..<20 {
            await Task<Never, Never>.yield()
        }
    }
}

/// One-shot gate that the test releases explicitly for a single async call.
/// Retains a result even when it is set before the call arrives, and resumes any unreleased continuation when the test finishes.
private final class Deferred<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<UncheckedTransfer<Value>, Error>?
    private var continuation: CheckedContinuation<UncheckedTransfer<Value>, Error>?

    func value() async throws -> Value {
        let transfer = try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                precondition(self.continuation == nil, "Deferred.value()は1回だけ呼べる")
                self.continuation = continuation
                lock.unlock()
            }
        }
        return transfer.value
    }

    func resolve(_ result: Result<Value, Error>) {
        let transferResult = result.map { UncheckedTransfer(value: $0) }
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = transferResult
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: transferResult)
    }
}

/// Avoids making production types retroactively Sendable for test convenience; only the ownership transfer across the gate is unchecked.
private struct UncheckedTransfer<Value>: @unchecked Sendable {
    let value: Value
}

/// Assigns each invocation of the same RPC its own gate and started/returned notifications.
private final class ControlledCalls<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private let gates: [Deferred<Value>]
    private let startedExpectations: [XCTestExpectation]
    private let returnedExpectations: [XCTestExpectation]
    private var nextCall = 0

    init(count: Int, name: String) {
        gates = (0..<count).map { _ in Deferred<Value>() }
        startedExpectations = (0..<count).map {
            XCTestExpectation(description: "\(name) call \($0) started")
        }
        returnedExpectations = (0..<count).map {
            XCTestExpectation(description: "\(name) call \($0) returned")
        }
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return nextCall
    }

    func started(_ call: Int) -> XCTestExpectation {
        startedExpectations[call]
    }

    func returned(_ call: Int) -> XCTestExpectation {
        returnedExpectations[call]
    }

    func invoke() async throws -> Value {
        let call = reserveCall()
        guard gates.indices.contains(call) else {
            throw StubError.unexpectedCall(call)
        }
        startedExpectations[call].fulfill()
        defer { returnedExpectations[call].fulfill() }
        return try await gates[call].value()
    }

    private func reserveCall() -> Int {
        lock.lock()
        let call = nextCall
        nextCall += 1
        lock.unlock()
        return call
    }

    func succeed(_ value: Value, call: Int) {
        gates[call].resolve(.success(value))
    }

    func fail(_ error: Error, call: Int) {
        gates[call].resolve(.failure(error))
    }

    func finish() {
        for gate in gates {
            gate.resolve(.failure(StubError.testFinished))
        }
    }
}

private enum StubError: Error {
    case unexpectedCall(Int)
    case transientSnapshot
    case testFinished
}
