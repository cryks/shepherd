// Verifies the contract that aggregates the ready snapshots of multiple sources
// into a single menu bar state. Without using SSH or Unix sockets, it reproduces
// with plain values the conditions where the same pane ID can exist per endpoint
// and where some sources are disconnected and produce no snapshot.

import Foundation
import XCTest
@testable import Shepherd

final class FleetStoreTests: XCTestCase {
    @MainActor
    func test接続先を横断して人の操作が必要な状態を優先する() {
        let local = snapshot(status: .working, paneID: "w1:p1")
        let remoteDone = snapshot(status: .done, paneID: "w1:p1")
        let remoteBlocked = snapshot(status: .blocked, paneID: "w1:p2")

        XCTAssertEqual(
            FleetStore.aggregateMenuBarState([local, remoteDone]),
            .done
        )
        XCTAssertEqual(
            FleetStore.aggregateMenuBarState([local, remoteDone, remoteBlocked]),
            .blocked
        )
    }

    @MainActor
    func test一部が未接続でもReadyの接続先を表示状態に使う() {
        let readyRemote = snapshot(status: .working, paneID: "w2:p1")

        // Disconnected sources do not enter the snapshot array. If even one is ready, its state is used.
        XCTAssertEqual(FleetStore.aggregateMenuBarState([readyRemote]), .working)
        XCTAssertEqual(FleetStore.aggregateMenuBarState([]), .disconnected)
    }

    @MainActor
    func testReadyだがエージェントがいない接続先はQuietになる() {
        let empty = AgentSnapshot(agents: [], workspaces: [])
        XCTAssertEqual(FleetStore.aggregateMenuBarState([empty]), .quiet)
    }

    @MainActor
    func testローカルと有効な複数Remoteを独立して開始停止する() throws {
        // The expected headerTitle values depend on the display language, so pin it
        // to the base language (English) so the host machine's OS language cannot affect them.
        let originalLanguage = LanguageSetting.shared.selection
        LanguageSetting.shared.selection = .english
        defer { LanguageSetting.shared.selection = originalLanguage }

        // The local headerTitle also depends on the section-title setting, so pin it to standard.
        let originalTitleStyle = LocalSectionTitleSetting.shared.style
        LocalSectionTitleSetting.shared.style = .standard
        defer { LocalSectionTitleSetting.shared.style = originalTitleStyle }

        let first = remoteConfiguration(index: 1, enabled: true)
        let disabled = remoteConfiguration(index: 2, enabled: false)
        let third = remoteConfiguration(index: 3, enabled: true)
        let repository = RemoteSourceRepository(
            load: { [first, disabled, third] },
            save: { _ in }
        )
        let localStore = endpointStore(
            snapshot: snapshot(status: .working, paneID: "local:p1"),
            pollInterval: Store.localPollInterval
        )
        var tunnels: [FleetTestTunnel] = []
        var remoteStores: [Store] = []
        var remotePollIntervals: [Duration] = []
        var remoteSnapshots = [
            snapshot(status: .done, paneID: "same:p1"),
            snapshot(status: .blocked, paneID: "same:p1"),
        ]

        let fleet = FleetStore(
            repository: repository,
            localStore: localStore,
            tunnelFactory: { configuration in
                let socketPath = "/tmp/fleet-\(tunnels.count).sock"
                let tunnel = FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: socketPath,
                    state: .ready(localSocketPath: socketPath)
                )
                tunnels.append(tunnel)
                return tunnel
            },
            remoteStoreFactory: { _, pollInterval in
                remotePollIntervals.append(pollInterval)
                let store = self.endpointStore(
                    snapshot: remoteSnapshots.removeFirst(),
                    pollInterval: pollInterval
                )
                remoteStores.append(store)
                return store
            }
        )

        XCTAssertEqual(fleet.activeSources.map(\.id), [.local, first.id, third.id])
        XCTAssertEqual(
            fleet.sourceSections.map(\.id),
            [.local, first.id, disabled.id, third.id]
        )
        XCTAssertEqual(
            fleet.sourceSections.map(\.headerTitle),
            ["This Mac", "Remote 1", "Remote 2", "Remote 3"]
        )
        let disabledSection = try XCTUnwrap(
            fleet.sourceSections.first { $0.id == disabled.id }
        )
        XCTAssertNil(disabledSection.source, "監視オフの remote が runtime を所有している")
        XCTAssertEqual(disabledSection.state, .disabled)
        XCTAssertNil(disabledSection.statusMessage, "監視オフの section が本文文言を持っている")
        XCTAssertEqual(tunnels.count, 2, "無効な remote の tunnel を作った")
        XCTAssertEqual(localStore.pollInterval, .milliseconds(500))
        XCTAssertEqual(remotePollIntervals, [.seconds(2), .seconds(2)])
        XCTAssertEqual(fleet.menuBarState, .blocked)

        fleet.start()
        XCTAssertEqual(tunnels.map(\.startCallCount), [1, 1])

        fleet.stop()
        XCTAssertEqual(tunnels.map(\.stopCallCount), [1, 1])
        XCTAssertTrue(isDisconnected(localStore))
        XCTAssertTrue(remoteStores.allSatisfy(isDisconnected))
    }

    @MainActor
    func testRemoteの監視OnOffでSectionを残してRuntimeだけ開始停止する() throws {
        let remote = remoteConfiguration(index: 6, enabled: false)
        var persisted = [remote]
        var tunnels: [FleetTestTunnel] = []
        var remoteStores: [Store] = []
        let repository = RemoteSourceRepository(
            load: { persisted },
            save: { persisted = $0 }
        )
        let localStore = endpointStore(
            snapshot: snapshot(status: .working, paneID: "local:p1")
        )
        let fleet = FleetStore(
            repository: repository,
            localStore: localStore,
            tunnelFactory: { configuration in
                let tunnel = FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: "/tmp/fleet-toggle.sock",
                    state: .ready(localSocketPath: "/tmp/fleet-toggle.sock")
                )
                tunnels.append(tunnel)
                return tunnel
            },
            remoteStoreFactory: { _, pollInterval in
                let store = self.endpointStore(
                    snapshot: self.snapshot(status: .blocked, paneID: "remote:p1"),
                    pollInterval: pollInterval
                )
                remoteStores.append(store)
                return store
            }
        )

        fleet.start()
        XCTAssertEqual(fleet.sourceSections.map(\.id), [.local, remote.id])
        XCTAssertEqual(fleet.sourceSections.last?.state, .disabled)
        XCTAssertTrue(tunnels.isEmpty)
        XCTAssertEqual(fleet.menuBarState, .working)

        try fleet.setRemoteEnabled(id: remote.id, isEnabled: true)
        XCTAssertEqual(persisted.first?.isEnabled, true)
        XCTAssertEqual(fleet.sourceSections.map(\.id), [.local, remote.id])
        XCTAssertNotNil(fleet.sourceSections.last?.source)
        XCTAssertEqual(tunnels.count, 1)
        XCTAssertEqual(tunnels.first?.startCallCount, 1)
        XCTAssertEqual(fleet.menuBarState, .blocked)

        try fleet.setRemoteEnabled(id: remote.id, isEnabled: false)
        XCTAssertEqual(persisted.first?.isEnabled, false)
        XCTAssertEqual(fleet.activeSources.map(\.id), [.local])
        XCTAssertEqual(fleet.sourceSections.map(\.id), [.local, remote.id])
        XCTAssertNil(fleet.sourceSections.last?.source)
        XCTAssertEqual(fleet.sourceSections.last?.state, .disabled)
        XCTAssertEqual(tunnels.first?.stopCallCount, 1)
        XCTAssertTrue(remoteStores.first.map(isDisconnected) ?? false)
        XCTAssertEqual(fleet.menuBarState, .working)

        let reconstructed = FleetStore(
            repository: repository,
            localStore: Store(initialState: .disconnected),
            tunnelFactory: { _ in throw FleetTestError.unexpectedCall }
        )
        XCTAssertEqual(reconstructed.sourceSections.map(\.id), [.local, remote.id])
        XCTAssertEqual(reconstructed.sourceSections.last?.state, .disabled)
    }

    @MainActor
    func test表示OFFのRemoteはSectionを出さず監視ONでもRuntimeを作らない() throws {
        let remote = remoteConfiguration(index: 11, enabled: true, visible: false)
        var persisted = [remote]
        var tunnels: [FleetTestTunnel] = []
        let repository = RemoteSourceRepository(
            load: { persisted },
            save: { persisted = $0 }
        )
        let fleet = FleetStore(
            repository: repository,
            localStore: Store(initialState: .disconnected),
            tunnelFactory: { configuration in
                let socketPath = "/tmp/fleet-visible-\(tunnels.count).sock"
                let tunnel = FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: socketPath,
                    state: .ready(localSocketPath: socketPath)
                )
                tunnels.append(tunnel)
                return tunnel
            },
            remoteStoreFactory: { _, pollInterval in
                self.endpointStore(
                    snapshot: self.snapshot(status: .blocked, paneID: "remote:p1"),
                    pollInterval: pollInterval
                )
            }
        )

        fleet.start()
        XCTAssertEqual(fleet.sourceSections.map(\.id), [.local], "表示 OFF の remote が section を出した")
        XCTAssertEqual(fleet.activeSources.map(\.id), [.local])
        XCTAssertTrue(tunnels.isEmpty, "表示 OFF の remote が tunnel を作った")
        XCTAssertEqual(fleet.menuBarState, .disconnected)

        // Turning visibility back on resumes monitoring using the preserved isEnabled == true as-is.
        try fleet.setRemoteVisible(id: remote.id, isVisible: true)
        XCTAssertEqual(persisted.first?.isVisible, true)
        XCTAssertEqual(persisted.first?.isEnabled, true)
        XCTAssertEqual(fleet.sourceSections.map(\.id), [.local, remote.id])
        XCTAssertNotNil(fleet.sourceSections.last?.source)
        XCTAssertEqual(tunnels.count, 1)
        XCTAssertEqual(tunnels.first?.startCallCount, 1)
        XCTAssertEqual(fleet.menuBarState, .blocked)

        // Turning visibility off also stops a monitoring-enabled remote, but does not rewrite isEnabled.
        try fleet.setRemoteVisible(id: remote.id, isVisible: false)
        XCTAssertEqual(persisted.first?.isVisible, false)
        XCTAssertEqual(persisted.first?.isEnabled, true)
        XCTAssertEqual(fleet.sourceSections.map(\.id), [.local])
        XCTAssertEqual(fleet.activeSources.map(\.id), [.local])
        XCTAssertEqual(tunnels.first?.stopCallCount, 1)
        XCTAssertEqual(fleet.menuBarState, .disconnected)
    }

    @MainActor
    func test切断中Remoteの古いSnapshotは集約状態へ混ぜない() {
        let configuration = remoteConfiguration(index: 4, enabled: true)
        let localStore = endpointStore(
            snapshot: snapshot(status: .working, paneID: "local:p1")
        )
        var tunnel: FleetTestTunnel!
        let fleet = FleetStore(
            repository: RemoteSourceRepository(
                load: { [configuration] },
                save: { _ in }
            ),
            localStore: localStore,
            tunnelFactory: { configuration in
                tunnel = FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: "/tmp/fleet-retry.sock",
                    state: .ready(localSocketPath: "/tmp/fleet-retry.sock")
                )
                return tunnel
            },
            remoteStoreFactory: { _, pollInterval in
                self.endpointStore(
                    snapshot: self.snapshot(status: .blocked, paneID: "remote:p1"),
                    pollInterval: pollInterval
                )
            }
        )

        fleet.start()
        XCTAssertEqual(fleet.menuBarState, .blocked)
        tunnel.transition(
            to: .retrying(
                failure: RemoteTunnelFailure(
                    phase: .forwarding,
                    kind: .unreachable,
                    exitStatus: 255,
                    diagnostic: "connection lost"
                ),
                delay: .seconds(1)
            )
        )
        XCTAssertEqual(fleet.menuBarState, .working)

        tunnel.transition(to: .ready(localSocketPath: tunnel.localSocketPath))
        XCTAssertEqual(fleet.menuBarState, .blocked)
    }

    @MainActor
    func testRemote行からLocalFocusを呼べない() async {
        var focusedPaneIDs: [String] = []
        let fleet = FleetStore(
            repository: RemoteSourceRepository(load: { [] }, save: { _ in }),
            localStore: Store(initialState: .disconnected),
            tunnelFactory: { _ in throw FleetTestError.unexpectedCall },
            localAgentFocus: LocalAgentFocus { pane in
                focusedPaneIDs.append(pane.paneId)
            }
        )
        let pane = makePane(status: .done, paneID: "w1:p1")

        await fleet.focus(pane, sourceID: .remote())
        XCTAssertTrue(focusedPaneIDs.isEmpty)

        await fleet.focus(pane, sourceID: .local)
        XCTAssertEqual(focusedPaneIDs, [pane.paneId])
    }

    @MainActor
    func testLocalFocusAwaitsRequestAppActivationAndTerminalHandoff() async {
        var events: [String] = []
        let requestStarted = expectation(description: "focus request started")
        let appActivationStarted = expectation(description: "app activation started")
        let terminalActivationStarted = expectation(
            description: "terminal activation started"
        )
        let requestGate = FleetFocusGate()
        let appActivationGate = FleetFocusGate()
        let terminalActivationGate = FleetFocusGate()
        let pane = makePane(status: .done, paneID: "w1:p1")
        let focus = LocalAgentFocus(
            request: { receivedPane in
                events.append("request-start")
                XCTAssertEqual(receivedPane.paneId, pane.paneId)
                requestStarted.fulfill()
                await requestGate.wait()
                events.append("request-finish")
            },
            applicationActivation: {
                events.append("app-activation-start")
                appActivationStarted.fulfill()
                await appActivationGate.wait()
                events.append("app-activation-finish")
                return .active
            },
            terminalActivation: {
                TerminalApplicationActivation(
                    activate: {
                        events.append("terminal-activation-start")
                        terminalActivationStarted.fulfill()
                        await terminalActivationGate.wait()
                        events.append("terminal-activation-finish")
                    }
                )
            }
        )
        let operation = Task { @MainActor in
            await focus.focus(pane)
            events.append("return")
        }

        await fulfillment(of: [requestStarted], timeout: 1.0)
        XCTAssertEqual(events, ["request-start"])

        requestGate.open()
        await fulfillment(of: [appActivationStarted], timeout: 1.0)
        XCTAssertEqual(
            events,
            ["request-start", "request-finish", "app-activation-start"]
        )

        appActivationGate.open()
        await fulfillment(of: [terminalActivationStarted], timeout: 1.0)
        XCTAssertEqual(
            events,
            [
                "request-start",
                "request-finish",
                "app-activation-start",
                "app-activation-finish",
                "terminal-activation-start",
            ]
        )

        terminalActivationGate.open()
        await operation.value

        XCTAssertEqual(
            events,
            [
                "request-start",
                "request-finish",
                "app-activation-start",
                "app-activation-finish",
                "terminal-activation-start",
                "terminal-activation-finish",
                "return",
            ]
        )
    }

    @MainActor
    func testLocalFocusStillHandsOffWhenRequestFails() async {
        var events: [String] = []
        let pane = makePane(status: .done, paneID: "w1:p1")
        let focus = LocalAgentFocus(
            request: { _ in
                throw FleetTestError.unexpectedCall
            },
            applicationActivation: {
                events.append("app-activation")
                return .active
            },
            terminalActivation: {
                TerminalApplicationActivation(
                    activate: {
                        events.append("terminal-activation")
                    }
                )
            }
        )

        await focus.focus(pane)

        XCTAssertEqual(events, ["app-activation", "terminal-activation"])
    }

    @MainActor
    func testLocalFocusSkipsTerminalHandoffDuringShutdown() async {
        var terminalActivationCount = 0
        let pane = makePane(status: .done, paneID: "w1:p1")
        let focus = LocalAgentFocus(
            request: { _ in },
            applicationActivation: { .shutDown },
            terminalActivation: {
                TerminalApplicationActivation(
                    activate: { terminalActivationCount += 1 }
                )
            }
        )

        await focus.focus(pane)

        XCTAssertEqual(terminalActivationCount, 0)
    }

    @MainActor
    func test表示名とPoll周期の編集はTunnelとStoreを再利用する() throws {
        let original = remoteConfiguration(index: 5, enabled: true)
        var saved: [RemoteSourceConfiguration] = []
        var tunnels: [FleetTestTunnel] = []
        let fleet = FleetStore(
            repository: RemoteSourceRepository(
                load: { [original] },
                save: { saved = $0 }
            ),
            localStore: Store(initialState: .disconnected),
            tunnelFactory: { configuration in
                let tunnel = FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: "/tmp/fleet-label-\(tunnels.count).sock",
                    state: .stopped
                )
                tunnels.append(tunnel)
                return tunnel
            }
        )
        let originalSource = try XCTUnwrap(fleet.monitoredSource(id: original.id))

        var renamed = original
        renamed.label = "Renamed"
        renamed.pollInterval = .halfSecond
        try fleet.updateRemote(renamed)

        let renamedSource = try XCTUnwrap(fleet.monitoredSource(id: original.id))
        XCTAssertTrue(originalSource === renamedSource)
        XCTAssertEqual(tunnels.count, 1)
        XCTAssertEqual(renamedSource.store.pollInterval, .milliseconds(500))
        XCTAssertEqual(saved, [renamed])

        var moved = renamed
        moved.sshAlias = "another-host"
        try fleet.updateRemote(moved)

        let movedSource = try XCTUnwrap(fleet.monitoredSource(id: original.id))
        XCTAssertFalse(renamedSource === movedSource)
        XCTAssertEqual(tunnels.count, 2)
        XCTAssertEqual(tunnels[0].stopCallCount, 1)
    }

    @MainActor
    func test接続情報Editorは現在の表示と監視状態を上書きしない() throws {
        let original = remoteConfiguration(index: 7, enabled: false)
        var saved: [RemoteSourceConfiguration] = []
        let fleet = FleetStore(
            repository: RemoteSourceRepository(
                load: { [original] },
                save: { saved = $0 }
            ),
            localStore: Store(initialState: .disconnected),
            tunnelFactory: { _ in throw FleetTestError.unexpectedCall }
        )

        var staleEditorValue = original
        staleEditorValue.label = "Renamed"
        staleEditorValue.isVisible = false
        staleEditorValue.isEnabled = true
        try fleet.updateRemote(staleEditorValue)

        XCTAssertEqual(saved.first?.label, "Renamed")
        XCTAssertEqual(saved.first?.isVisible, true)
        XCTAssertEqual(saved.first?.isEnabled, false)
        XCTAssertEqual(fleet.sourceSections.last?.state, .disabled)
    }

    @MainActor
    func test監視Toggleの保存失敗ではRuntimeとSection状態を変えない() throws {
        let remote = remoteConfiguration(index: 8, enabled: true)
        var tunnel: FleetTestTunnel!
        let fleet = FleetStore(
            repository: RemoteSourceRepository(
                load: { [remote] },
                save: { _ in throw FleetTestError.saveFailed }
            ),
            localStore: Store(initialState: .disconnected),
            tunnelFactory: { configuration in
                tunnel = FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: "/tmp/fleet-save-failure.sock",
                    state: .stopped
                )
                return tunnel
            }
        )
        let sourceBeforeFailure = try XCTUnwrap(fleet.monitoredSource(id: remote.id))

        XCTAssertThrowsError(
            try fleet.setRemoteEnabled(id: remote.id, isEnabled: false)
        ) { error in
            XCTAssertEqual(error as? FleetTestError, .saveFailed)
        }

        XCTAssertTrue(fleet.monitoredSource(id: remote.id) === sourceBeforeFailure)
        XCTAssertEqual(fleet.sourceSections.last?.isEnabled, true)
        XCTAssertEqual(tunnel.stopCallCount, 0)
    }

    @MainActor
    func testRemoteの並び替えを保存してSection順とRuntimeの再利用を保つ() throws {
        let first = remoteConfiguration(index: 1, enabled: true)
        let disabled = remoteConfiguration(index: 2, enabled: false)
        let third = remoteConfiguration(index: 3, enabled: true)
        var saved: [RemoteSourceConfiguration] = []
        var tunnels: [FleetTestTunnel] = []
        let fleet = FleetStore(
            repository: RemoteSourceRepository(
                load: { [first, disabled, third] },
                save: { saved = $0 }
            ),
            localStore: Store(initialState: .disconnected),
            tunnelFactory: { configuration in
                let tunnel = FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: "/tmp/fleet-move-\(tunnels.count).sock",
                    state: .stopped
                )
                tunnels.append(tunnel)
                return tunnel
            }
        )
        let firstSource = try XCTUnwrap(fleet.monitoredSource(id: first.id))
        let thirdSource = try XCTUnwrap(fleet.monitoredSource(id: third.id))

        // Move the last item (index 2) to the front, using the (IndexSet, Int) that onMove passes as-is.
        try fleet.moveRemote(fromOffsets: IndexSet(integer: 2), toOffset: 0)

        XCTAssertEqual(saved.map(\.id), [third.id, first.id, disabled.id])
        XCTAssertEqual(
            fleet.sourceSections.map(\.id),
            [.local, third.id, first.id, disabled.id]
        )
        XCTAssertTrue(fleet.monitoredSource(id: first.id) === firstSource)
        XCTAssertTrue(fleet.monitoredSource(id: third.id) === thirdSource)
        XCTAssertEqual(tunnels.count, 2, "並び替えで tunnel を作り直した")
        XCTAssertEqual(tunnels.map(\.stopCallCount), [0, 0])
    }

    @MainActor
    func testスリープ中は全SourceのPollを止め復帰で再開する() async throws {
        let active = remoteConfiguration(index: 9, enabled: true)
        let dormant = remoteConfiguration(index: 10, enabled: false)
        var persisted = [active, dormant]
        let localCounter = CallCounter()
        var remoteCounters: [CallCounter] = []
        let fleet = FleetStore(
            repository: RemoteSourceRepository(
                load: { persisted },
                save: { persisted = $0 }
            ),
            localStore: countingStore(counter: localCounter, pollInterval: .milliseconds(5)),
            tunnelFactory: { configuration in
                let socketPath = "/tmp/fleet-sleep-\(remoteCounters.count).sock"
                return FleetTestTunnel(
                    configuration: configuration,
                    localSocketPath: socketPath,
                    state: .ready(localSocketPath: socketPath)
                )
            },
            remoteStoreFactory: { _, _ in
                let counter = CallCounter()
                remoteCounters.append(counter)
                return self.countingStore(counter: counter, pollInterval: .milliseconds(5))
            }
        )
        defer { fleet.stop() }

        fleet.start()
        let polled = await waitUntil {
            localCounter.count > 0 && remoteCounters.first.map { $0.count > 0 } ?? false
        }
        XCTAssertTrue(polled, "開始後にpollが走らなかった")

        fleet.suspendPolling()
        await drainMainActor()
        let localBefore = localCounter.count
        let remoteBefore = remoteCounters[0].count

        // A source whose monitoring is enabled during the sleep transition also does not start polling until resume.
        try fleet.setRemoteEnabled(id: dormant.id, isEnabled: true)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(localCounter.count, localBefore, "suspend中にlocalがpollした")
        XCTAssertEqual(remoteCounters[0].count, remoteBefore, "suspend中にremoteがpollした")
        XCTAssertEqual(remoteCounters[1].count, 0, "suspend中に作られたsourceがpollした")

        fleet.resumePolling()
        let resumed = await waitUntil {
            localCounter.count > localBefore
                && remoteCounters[0].count > remoteBefore
                && remoteCounters[1].count > 0
        }
        XCTAssertTrue(resumed, "復帰後にpollが再開しなかった")
    }

    private func snapshot(status: AgentStatus, paneID: String) -> AgentSnapshot {
        AgentSnapshot(
            agents: [makePane(status: status, paneID: paneID)],
            workspaces: [
                Workspace(workspaceId: "w1", label: "Workspace", number: 1),
            ]
        )
    }

    private func makePane(status: AgentStatus, paneID: String) -> Pane {
        Pane(
            agent: "codex",
            agentStatus: status,
            paneId: paneID,
            workspaceId: "w1",
            terminalId: "terminal-\(paneID)",
            terminalTitleStripped: "Task",
            tokens: PaneTokens(agentKind: "primary")
        )
    }

    @MainActor
    private func endpointStore(
        snapshot: AgentSnapshot,
        pollInterval: Duration = .seconds(60)
    ) -> Store {
        let serverSnapshot = HerdrSessionSnapshot(
            version: "test",
            protocolVersion: Herdr.supportedProtocol,
            agents: Array(snapshot.panes.values),
            workspaces: Array(snapshot.workspaces.values)
        )
        return Store(
            dataSource: StoreDataSource(
                snapshot: { serverSnapshot },
                worktrees: { _ in WorktreeListResult(worktrees: []) }
            ),
            pollInterval: pollInterval,
            initialState: .ready(snapshot)
        )
    }

    /// An immediately responding Store that only counts poll calls. Observes the
    /// boundary where polling stops during sleep without a real socket.
    @MainActor
    private func countingStore(
        counter: CallCounter,
        pollInterval: Duration
    ) -> Store {
        let serverSnapshot = HerdrSessionSnapshot(
            version: "test",
            protocolVersion: Herdr.supportedProtocol,
            agents: [],
            workspaces: []
        )
        return Store(
            dataSource: StoreDataSource(
                snapshot: {
                    counter.increment()
                    return serverSnapshot
                },
                worktrees: { _ in WorktreeListResult(worktrees: []) }
            ),
            pollInterval: pollInterval
        )
    }

    @MainActor
    private func isDisconnected(_ store: Store) -> Bool {
        guard case .disconnected = store.state else { return false }
        return true
    }

    /// Waits for an increase in poll count, which cannot be pinned to an XCTestExpectation, as a state change observed back on the MainActor.
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

    /// Yields the executor to already-enqueued MainActor tasks, fully waiting out RPC completions in flight just before suspend.
    @MainActor
    private func drainMainActor() async {
        for _ in 0..<20 {
            await Task<Never, Never>.yield()
        }
    }

    private func remoteConfiguration(
        index: Int,
        enabled: Bool,
        visible: Bool = true
    ) -> RemoteSourceConfiguration {
        RemoteSourceConfiguration(
            id: .remote(
                uuid: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
            ),
            label: "Remote \(index)",
            sshAlias: "remote-\(index)",
            isVisible: visible,
            isEnabled: enabled
        )
    }
}

private enum FleetTestError: Error, Equatable {
    case unexpectedCall
    case saveFailed
}

/// One-shot MainActor gate used to prove that each focus phase keeps its caller
/// suspended until the next phase is allowed to start.
@MainActor
private final class FleetFocusGate {
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

/// A lock-guarded counter for counting RPC calls from the dataSource's @Sendable closures.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}

@MainActor
private final class FleetTestTunnel: RemoteTunnelManaging {
    let configuration: RemoteSourceConfiguration
    let localSocketPath: String
    private(set) var state: RemoteTunnelState
    var onStateChange: ((RemoteTunnelState) -> Void)?

    private(set) var startCallCount = 0
    private(set) var stopCallCount = 0

    init(
        configuration: RemoteSourceConfiguration,
        localSocketPath: String,
        state: RemoteTunnelState
    ) {
        self.configuration = configuration
        self.localSocketPath = localSocketPath
        self.state = state
    }

    func start() {
        startCallCount += 1
        onStateChange?(state)
    }

    func stop() {
        stopCallCount += 1
        state = .stopped
        onStateChange?(.stopped)
    }

    func transition(to state: RemoteTunnelState) {
        self.state = state
        onStateChange?(state)
    }
}
