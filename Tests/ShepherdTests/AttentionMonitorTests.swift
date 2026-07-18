// Exercises the platform-neutral attention reducer and its FleetStore Observation
// adapter. Notification Center behavior is covered by the delivery-layer tests;
// these tests pin which value effects are emitted and when a current click target
// remains resolvable.

import Foundation
import XCTest
@testable import Shepherd

final class AttentionMonitorTests: XCTestCase {
    private let localGeneration = AttentionSourceGenerationID(
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    private let replacementGeneration = AttentionSourceGenerationID(
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )

    func testStartupAndFirstReadySnapshotsBecomeBaselines() {
        var machine = AttentionStateMachine()
        let blocked = source(status: .blocked)
        let waitingRemote = unavailableSource(
            id: remoteID(1),
            generation: replacementGeneration,
            title: "Remote"
        )

        XCTAssertEqual(
            machine.start(
                enabled: true,
                fleet: fleet(blocked, waitingRemote)
            ),
            [.removeAll]
        )
        XCTAssertTrue(machine.ingest(fleet(blocked, waitingRemote)).isEmpty)

        let readyRemote = source(
            id: remoteID(1),
            generation: replacementGeneration,
            title: "Remote",
            status: .done
        )
        XCTAssertTrue(machine.ingest(fleet(blocked, readyRemote)).isEmpty)
    }

    func testAttentionTransitionsDeliverStableNoticeAndCurrentDestination() throws {
        var machine = AttentionStateMachine()
        let working = source(
            title: "Laptop",
            status: .working,
            paneID: "w1:p1",
            terminalID: "terminal-1",
            taskTitle: "Implement alerts",
            branch: "feature/alerts",
            workspaceTitle: "Shepherd"
        )
        _ = machine.start(enabled: true, fleet: fleet(working))

        let blocked = source(
            title: "Laptop",
            status: .blocked,
            paneID: "w1:p1",
            terminalID: "terminal-1",
            taskTitle: "Implement alerts",
            branch: "feature/alerts",
            workspaceTitle: "Shepherd"
        )
        let blockedNotice = try deliveredNotice(machine.ingest(fleet(blocked)))
        XCTAssertEqual(blockedNotice.title, "🔴 Implement alerts")
        XCTAssertEqual(blockedNotice.subtitle, "Laptop · Shepherd")
        XCTAssertEqual(blockedNotice.body, "codex · feature/alerts")
        XCTAssertTrue(blockedNotice.id.rawValue.hasPrefix(AttentionNotificationID.managedPrefix))

        let done = source(
            title: "Laptop",
            status: .done,
            paneID: "w1:p1",
            terminalID: "terminal-1",
            taskTitle: "Implement alerts",
            branch: "feature/alerts",
            workspaceTitle: "Shepherd"
        )
        let doneNotice = try deliveredNotice(machine.ingest(fleet(done)))
        XCTAssertEqual(doneNotice.id, blockedNotice.id)
        XCTAssertEqual(doneNotice.title, "🟢 Implement alerts")

        let renamed = source(
            title: "Laptop",
            status: .done,
            paneID: "w1:p1",
            terminalID: "terminal-1",
            taskTitle: "A newer title",
            branch: "feature/alerts",
            workspaceTitle: "Shepherd"
        )
        XCTAssertTrue(machine.ingest(fleet(renamed)).isEmpty)
        XCTAssertEqual(
            machine.destination(for: doneNotice.id)?.pane.displayTitle,
            "A newer title"
        )
    }

    func testResolutionAndDisappearanceRemoveOnlyAnIssuedNotice() throws {
        var machine = AttentionStateMachine()
        _ = machine.start(enabled: true, fleet: fleet(source(status: .blocked)))

        // Baseline attention did not issue a notice, so resolving it has nothing to remove.
        XCTAssertTrue(machine.ingest(fleet(source(status: .working))).isEmpty)

        let delivered = try deliveredNotice(
            machine.ingest(fleet(source(status: .blocked)))
        )
        XCTAssertEqual(
            machine.ingest(fleet(source(status: .unknown))),
            [.remove(delivered.id)]
        )
        XCTAssertNil(machine.destination(for: delivered.id))

        let deliveredAgain = try deliveredNotice(
            machine.ingest(fleet(source(status: .done)))
        )
        XCTAssertEqual(
            machine.ingest(fleet(emptySource())),
            [.remove(deliveredAgain.id)]
        )
        XCTAssertNil(machine.destination(for: deliveredAgain.id))
    }

    func testNewAttentionAgentsUseSeparateRequestsInOneSourceThread() throws {
        var machine = AttentionStateMachine()
        _ = machine.start(enabled: true, fleet: fleet(emptySource()))

        let current = source(
            agents: [
                agent(status: .blocked, paneID: "w1:p1", terminalID: "terminal-1"),
                agent(status: .done, paneID: "w1:p2", terminalID: "terminal-2"),
            ]
        )
        let notices = machine.ingest(fleet(current)).compactMap { effect -> AttentionNotice? in
            guard case .deliver(let notice) = effect else { return nil }
            return notice
        }
        XCTAssertEqual(notices.count, 2)
        XCTAssertNotEqual(notices[0].id, notices[1].id)
        XCTAssertEqual(Set(notices.map(\.threadIdentifier)).count, 1)
    }

    func testDisconnectRetainsStateAndReconnectReconcilesIt() throws {
        var machine = AttentionStateMachine()
        _ = machine.start(enabled: true, fleet: fleet(source(status: .working)))
        let notice = try deliveredNotice(
            machine.ingest(fleet(source(status: .blocked)))
        )

        XCTAssertTrue(machine.ingest(fleet(unavailableSource())).isEmpty)
        XCTAssertNil(machine.destination(for: notice.id))
        XCTAssertTrue(machine.ingest(fleet(source(status: .blocked))).isEmpty)
        XCTAssertNotNil(machine.destination(for: notice.id))

        XCTAssertTrue(machine.ingest(fleet(unavailableSource())).isEmpty)
        XCTAssertEqual(
            machine.ingest(fleet(source(status: .idle))),
            [.remove(notice.id)]
        )

        XCTAssertTrue(machine.ingest(fleet(unavailableSource())).isEmpty)
        let reconnectedNotice = try deliveredNotice(
            machine.ingest(fleet(source(status: .done)))
        )
        XCTAssertEqual(reconnectedNotice.id, notice.id)
    }

    func testIntentionalRemovalAndRuntimeReplacementRemoveThenBaseline() throws {
        var machine = AttentionStateMachine()
        _ = machine.start(enabled: true, fleet: fleet(source(status: .working)))
        let first = try deliveredNotice(
            machine.ingest(fleet(source(status: .blocked)))
        )

        XCTAssertEqual(machine.ingest(fleet()), [.remove(first.id)])

        let restored = source(status: .working)
        XCTAssertTrue(machine.ingest(fleet(restored)).isEmpty)
        let second = try deliveredNotice(
            machine.ingest(fleet(source(status: .done)))
        )

        let replacement = source(
            generation: replacementGeneration,
            status: .blocked
        )
        XCTAssertEqual(
            machine.ingest(fleet(replacement)),
            [.remove(second.id)]
        )
        XCTAssertTrue(machine.ingest(fleet(replacement)).isEmpty)
        XCTAssertNil(machine.destination(for: second.id))
    }

    func testTerminalIdentitySurvivesPaneMovesAndPromotesPaneFallback() throws {
        var terminalMachine = AttentionStateMachine()
        _ = terminalMachine.start(
            enabled: true,
            fleet: fleet(source(
                status: .working,
                paneID: "w1:p1",
                terminalID: "terminal-1"
            ))
        )
        let moved = try deliveredNotice(
            terminalMachine.ingest(fleet(source(
                status: .blocked,
                paneID: "w2:p4",
                terminalID: "terminal-1"
            )))
        )
        XCTAssertEqual(
            terminalMachine.destination(for: moved.id)?.pane.paneId,
            "w2:p4"
        )

        var fallbackMachine = AttentionStateMachine()
        _ = fallbackMachine.start(
            enabled: true,
            fleet: fleet(source(
                status: .working,
                paneID: "w1:p1",
                terminalID: nil
            ))
        )
        let promoted = try deliveredNotice(
            fallbackMachine.ingest(fleet(source(
                status: .blocked,
                paneID: "w1:p1",
                terminalID: "terminal-late"
            )))
        )
        XCTAssertTrue(promoted.id.rawValue.contains(".pane."))

        let promotedAndMoved = try deliveredNotice(
            fallbackMachine.ingest(fleet(source(
                status: .done,
                paneID: "w3:p2",
                terminalID: "terminal-late"
            )))
        )
        XCTAssertEqual(promotedAndMoved.id, promoted.id)
        XCTAssertEqual(
            fallbackMachine.destination(for: promoted.id)?.pane.paneId,
            "w3:p2"
        )
    }

    func testConflictingTerminalOnSamePaneIsANewAgent() throws {
        var machine = AttentionStateMachine()
        _ = machine.start(
            enabled: true,
            fleet: fleet(source(
                status: .working,
                terminalID: "terminal-old"
            ))
        )

        let notice = try deliveredNotice(
            machine.ingest(fleet(source(
                status: .blocked,
                terminalID: "terminal-new"
            )))
        )
        XCTAssertTrue(notice.id.rawValue.contains(".terminal."))
    }

    func testToggleCycleAndTerminationClearThenRebaseline() throws {
        var machine = AttentionStateMachine()
        _ = machine.start(enabled: true, fleet: fleet(source(status: .working)))
        _ = try deliveredNotice(machine.ingest(fleet(source(status: .blocked))))

        XCTAssertEqual(
            machine.setEnabled(false, fleet: fleet(source(status: .blocked))),
            [.removeAll]
        )
        XCTAssertTrue(machine.ingest(fleet(source(status: .done))).isEmpty)
        XCTAssertTrue(
            machine.setEnabled(true, fleet: fleet(source(status: .done))).isEmpty
        )
        XCTAssertTrue(machine.ingest(fleet(source(status: .done))).isEmpty)
        _ = try deliveredNotice(machine.ingest(fleet(source(status: .blocked))))

        XCTAssertEqual(machine.stop(), [.removeAll])
        XCTAssertTrue(machine.ingest(fleet(source(status: .done))).isEmpty)
    }

    func testSourceRenameWaitsForNextTransitionAndHiddenLocalOmitsSource() throws {
        var machine = AttentionStateMachine()
        _ = machine.start(
            enabled: true,
            fleet: fleet(source(title: "Old", status: .working))
        )
        let oldNotice = try deliveredNotice(
            machine.ingest(fleet(source(title: "Old", status: .blocked)))
        )
        XCTAssertEqual(oldNotice.subtitle, "Old · Workspace")

        XCTAssertTrue(
            machine.ingest(fleet(source(title: "New", status: .blocked))).isEmpty
        )
        let renamedNotice = try deliveredNotice(
            machine.ingest(fleet(source(title: "New", status: .done)))
        )
        XCTAssertEqual(renamedNotice.subtitle, "New · Workspace")

        var hiddenMachine = AttentionStateMachine()
        _ = hiddenMachine.start(
            enabled: true,
            fleet: fleet(source(title: nil, status: .working))
        )
        let hiddenNotice = try deliveredNotice(
            hiddenMachine.ingest(fleet(source(title: nil, status: .blocked)))
        )
        XCTAssertEqual(hiddenNotice.subtitle, "Workspace")
    }

    func testSameAgentIDsOnDifferentSourcesDoNotCollide() throws {
        let remote = remoteID(9)
        let remoteGeneration = AttentionSourceGenerationID(
            UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        )
        var machine = AttentionStateMachine()
        _ = machine.start(
            enabled: true,
            fleet: fleet(
                source(status: .working),
                source(
                    id: remote,
                    generation: remoteGeneration,
                    title: "Remote",
                    status: .working
                )
            )
        )

        let effects = machine.ingest(fleet(
            source(status: .blocked),
            source(
                id: remote,
                generation: remoteGeneration,
                title: "Remote",
                status: .blocked
            )
        ))
        let notices = effects.compactMap { effect -> AttentionNotice? in
            guard case .deliver(let notice) = effect else { return nil }
            return notice
        }
        XCTAssertEqual(notices.count, 2)
        XCTAssertNotEqual(notices[0].id, notices[1].id)
        XCTAssertNotEqual(notices[0].threadIdentifier, notices[1].threadIdentifier)
    }

    @MainActor
    func testCoordinatorObservesFleetStoreSnapshotTransitions() async {
        let initialPane = pane(status: .working)
        let initial = AgentSnapshot(
            agents: [initialPane],
            workspaces: [workspace()]
        )
        let feed = AttentionSnapshotFeed(
            snapshot: serverSnapshot(status: .blocked)
        )
        let endpointStore = Store(
            dataSource: StoreDataSource(
                snapshot: { await feed.next() },
                worktrees: { _ in WorktreeListResult(worktrees: []) }
            ),
            pollInterval: .seconds(60),
            initialState: .ready(initial)
        )
        let fleetStore = FleetStore(
            repository: RemoteSourceRepository(load: { [] }, save: { _ in }),
            localStore: endpointStore,
            tunnelFactory: { _ in throw AttentionTestError.unexpectedTunnel }
        )
        var received: [AttentionEffect] = []
        let delivered = expectation(description: "blocked transition delivered")
        let monitor = AttentionMonitor(store: fleetStore) { effects in
            received.append(contentsOf: effects)
            if effects.contains(where: {
                if case .deliver = $0 { return true }
                return false
            }) {
                delivered.fulfill()
            }
        }

        monitor.start(enabled: true)
        XCTAssertEqual(received, [.removeAll])
        fleetStore.start()
        await fulfillment(of: [delivered], timeout: 1.0)

        XCTAssertTrue(received.contains(where: {
            guard case .deliver(let notice) = $0 else { return false }
            return notice.title == "🔴 Task"
        }))
        monitor.stop()
        fleetStore.stop()
    }

    private func fleet(_ sources: AttentionSourceObservation...) -> AttentionFleetObservation {
        AttentionFleetObservation(sources: sources)
    }

    private func source(
        id: HerdrSourceID = .local,
        generation: AttentionSourceGenerationID? = nil,
        title: String? = "This Mac",
        status: AgentStatus,
        paneID: String = "w1:p1",
        terminalID: String? = "terminal-1",
        taskTitle: String = "Task",
        branch: String? = nil,
        workspaceTitle: String = "Workspace"
    ) -> AttentionSourceObservation {
        source(
            id: id,
            generation: generation,
            title: title,
            agents: [agent(
                status: status,
                paneID: paneID,
                terminalID: terminalID,
                taskTitle: taskTitle,
                branch: branch,
                workspaceTitle: workspaceTitle
            )]
        )
    }

    private func source(
        id: HerdrSourceID = .local,
        generation: AttentionSourceGenerationID? = nil,
        title: String? = "This Mac",
        agents: [AttentionAgentObservation]
    ) -> AttentionSourceObservation {
        AttentionSourceObservation(
            sourceID: id,
            generationID: generation ?? (id == .local ? localGeneration : replacementGeneration),
            sourceTitle: title,
            isRemote: id != .local,
            availability: .ready(agents)
        )
    }

    private func emptySource(
        id: HerdrSourceID = .local,
        generation: AttentionSourceGenerationID? = nil,
        title: String? = "This Mac"
    ) -> AttentionSourceObservation {
        source(id: id, generation: generation, title: title, agents: [])
    }

    private func unavailableSource(
        id: HerdrSourceID = .local,
        generation: AttentionSourceGenerationID? = nil,
        title: String? = "This Mac"
    ) -> AttentionSourceObservation {
        AttentionSourceObservation(
            sourceID: id,
            generationID: generation ?? (id == .local ? localGeneration : replacementGeneration),
            sourceTitle: title,
            isRemote: id != .local,
            availability: .unavailable
        )
    }

    private func agent(
        status: AgentStatus,
        paneID: String,
        terminalID: String?,
        taskTitle: String = "Task",
        branch: String? = nil,
        workspaceTitle: String = "Workspace"
    ) -> AttentionAgentObservation {
        AttentionAgentObservation(
            pane: pane(
                status: status,
                paneID: paneID,
                terminalID: terminalID,
                taskTitle: taskTitle,
                branch: branch
            ),
            workspaceTitle: workspaceTitle
        )
    }

    private func pane(
        status: AgentStatus,
        paneID: String = "w1:p1",
        terminalID: String? = "terminal-1",
        taskTitle: String = "Task",
        branch: String? = nil
    ) -> Pane {
        Pane(
            agent: "codex",
            agentStatus: status,
            paneId: paneID,
            workspaceId: "w1",
            terminalId: terminalID,
            terminalTitleStripped: taskTitle,
            tokens: PaneTokens(agentKind: "primary"),
            branch: branch
        )
    }

    private func workspace() -> Workspace {
        Workspace(workspaceId: "w1", label: "Workspace", number: 1)
    }

    private func serverSnapshot(status: AgentStatus) -> HerdrSessionSnapshot {
        HerdrSessionSnapshot(
            version: "test",
            protocolVersion: Herdr.supportedProtocol,
            agents: [pane(status: status)],
            workspaces: [workspace()]
        )
    }

    private func remoteID(_ value: Int) -> HerdrSourceID {
        HerdrSourceID.remote(
            uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
        )
    }

    private func deliveredNotice(
        _ effects: [AttentionEffect],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> AttentionNotice {
        guard effects.count == 1,
              case .deliver(let notice) = effects[0] else {
            XCTFail("Expected one deliver effect, got \(effects)", file: file, line: line)
            throw AttentionTestError.missingDelivery
        }
        return notice
    }
}

private actor AttentionSnapshotFeed {
    let snapshot: HerdrSessionSnapshot

    init(snapshot: HerdrSessionSnapshot) {
        self.snapshot = snapshot
    }

    func next() -> HerdrSessionSnapshot {
        snapshot
    }
}

private enum AttentionTestError: Error {
    case missingDelivery
    case unexpectedTunnel
}
