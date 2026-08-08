// Polling, not events.subscribe: herdr events do not replay history and
// pane.updated cannot be filtered per field, so a subscription would stream far
// more than the watch set. Overlapping polls are coalesced instead of queued so
// RPCs cannot pile up on a slow endpoint.
//
// No read/unread tracking: blocked and done are herdr-side states, and viewing
// the pane in herdr turns done back to idle on its own.

import Foundation
import Observation
import os

private let log = Logger(subsystem: "io.github.cryks.shepherd", category: "store")

struct AgentSnapshot: Equatable {
    var panes: [String: Pane]
    var workspaces: [String: Workspace]
    // Verbatim herdr records for the row and notification templates, which
    // address fields the typed models above do not carry. Equality therefore
    // covers every herdr field, not only the typed ones.
    var raw: HerdrRawSnapshot

    // branches comes from worktree.list: session.snapshot carries no branch
    // name, so it is grafted onto the raw workspace records under `branch`,
    // where `{herdr.workspace.branch}` reads it.
    init(
        agents: [Pane],
        workspaces: [Workspace],
        branches: [String: String] = [:],
        raw: HerdrRawSnapshot = .empty
    ) {
        let tracked = agents.filter(Store.shouldTrack)
        panes = Dictionary(uniqueKeysWithValues: tracked.map { ($0.paneId, $0) })
        self.workspaces = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceId, $0) })

        let trackedPaneIDs = Set(tracked.map(\.paneId))
        var raw = raw
        raw.agents = raw.agents.filter { trackedPaneIDs.contains($0.key) }
        for (workspaceId, branch) in branches {
            // A workspace herdr did not report, or reported as something other
            // than an object, still gets a record so the branch is addressable.
            var members: [String: JSONValue] = [:]
            if case .object(let existing)? = raw.workspaces[workspaceId] { members = existing }
            members["branch"] = .string(branch)
            raw.workspaces[workspaceId] = .object(members)
        }
        self.raw = raw
    }
}

enum StoreState: Equatable {
    case disconnected
    case synchronizing
    case ready(AgentSnapshot)
    // A failure on a server whose protocol differs from Herdr.supportedProtocol
    // is most likely caused by that difference, so it is reported instead of a
    // plain disconnect.
    case protocolMismatch(Int)
}

struct SnapshotFetch {
    var session: HerdrSessionSnapshot
    var raw: HerdrRawSnapshot

    init(session: HerdrSessionSnapshot, raw: HerdrRawSnapshot = .empty) {
        self.session = session
        self.raw = raw
    }
}

// session.snapshot answered but its body no longer decodes into the typed
// models. The protocol is read through the lenient raw pass so the failure can
// name an unsupported protocol instead of looking like a dropped connection.
struct SnapshotSchemaError: Error {
    var serverProtocol: Int?
    var underlying: Error
}

struct StoreDataSource: Sendable {
    var snapshot: @Sendable () async throws -> SnapshotFetch
    // Branch names are display decoration only; a failure here does not fail
    // the poll.
    var worktrees: @Sendable (_ workspaceID: String) async throws -> WorktreeListResult

    static func live(socketPath: String) -> StoreDataSource {
        StoreDataSource(
            snapshot: {
                // One RPC, two decodes of the same line: makeDecoder() for the
                // typed model, and a plain decoder for the raw tree, whose
                // dynamic keys .convertFromSnakeCase would otherwise rewrite.
                // The typed decode happens here, not in request(), so a future
                // protocol that breaks the typed shape still reports the
                // server's protocol from the lenient raw pass.
                try await Herdr.request(
                    "session.snapshot",
                    socketPath: socketPath,
                    as: EmptyResult.self
                ) { _, responseLine in
                    let raw = try HerdrRawSnapshot.decode(responseLine: responseLine)
                    do {
                        let response = try makeDecoder().decode(
                            RPCResponse<SessionSnapshotResult>.self,
                            from: responseLine
                        )
                        guard let result = response.result else {
                            throw HerdrClientError.emptyResult
                        }
                        return SnapshotFetch(session: result.snapshot, raw: raw)
                    } catch let error as DecodingError {
                        throw SnapshotSchemaError(
                            serverProtocol: raw.serverProtocol,
                            underlying: error
                        )
                    }
                }
            },
            worktrees: { workspaceID in
                try await Herdr.request(
                    "worktree.list",
                    params: ["workspace_id": workspaceID],
                    socketPath: socketPath,
                    as: WorktreeListResult.self
                )
            }
        )
    }
}

@Observable @MainActor
final class Store {
    static let localPollInterval: Duration = .milliseconds(500)

    private(set) var state: StoreState
    // Kept across failures so a failed poll on a mismatched server can still be
    // reported as protocolMismatch.
    private(set) var serverProtocol: Int?
    private(set) var pollInterval: Duration

    // The endpoint answers but speaks a protocol this app was not written
    // against, so any feature may misbehave. The data is still shown, with a
    // warning, rather than refused.
    var protocolWarning: Int? {
        guard case .ready = state, let serverProtocol,
              serverProtocol != Herdr.supportedProtocol else { return nil }
        return serverProtocol
    }

    var panes: [String: Pane] {
        guard case .ready(let snapshot) = state else { return [:] }
        return snapshot.panes
    }

    private var workspaces: [String: Workspace] {
        guard case .ready(let snapshot) = state else { return [:] }
        return snapshot.workspaces
    }

    private let dataSource: StoreDataSource
    private let agentReadMonitor: AgentReadMonitor
    private var pollingTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var hasStarted = false
    private var hasBeenStopped = false
    // Unlike hasBeenStopped this is reversible. A remote can be suspended while
    // it still waits for its tunnel, so it may be set before start().
    private var isPollingSuspended = false

    init(
        dataSource: StoreDataSource = .live(socketPath: Herdr.defaultSocketPath),
        agentReadDataSource: AgentReadDataSource = .live(
            socketPath: Herdr.defaultSocketPath
        ),
        pollInterval: Duration = .milliseconds(500),
        initialState: StoreState = .disconnected
    ) {
        precondition(pollInterval > .zero)
        self.dataSource = dataSource
        agentReadMonitor = AgentReadMonitor(dataSource: agentReadDataSource)
        self.pollInterval = pollInterval
        state = initialState
    }

    // pollInterval has no default here so no remote endpoint can silently
    // inherit the local 500ms.
    static func live(socketPath: String, pollInterval: Duration) -> Store {
        Store(
            dataSource: .live(socketPath: socketPath),
            agentReadDataSource: .live(socketPath: socketPath),
            pollInterval: pollInterval
        )
    }

    // MARK: - Derived views

    // Panes of a linked worktree are shown under the workspace holding the same
    // repo's root checkout, so one repo gets one heading.
    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        var groups: [String: (workspace: Workspace, panes: [Pane])] = [:]
        for pane in panes.values {
            let workspace = groupWorkspace(for: pane.workspaceId)
            groups[workspace.workspaceId, default: (workspace, [])].panes.append(pane)
        }
        return groups.values
            .map { group in
                (
                    workspace: group.workspace,
                    panes: group.panes.sorted { paneSortKey($0) < paneSortKey($1) }
                )
            }
            .sorted {
                ($0.workspace.number, $0.workspace.workspaceId)
                    < ($1.workspace.number, $1.workspace.workspaceId)
            }
    }

    // The workspace is the pane's own `workspace_id`, not the group it is
    // displayed under, so `{herdr.workspace.*}` describes the checkout the agent
    // runs in. Pane and tab ids number independently, so the tab must be
    // resolved through the agent record's `tab_id`.
    func rawRecords(forPane paneID: String) -> (agent: JSONValue?, workspace: JSONValue?, tab: JSONValue?) {
        guard case .ready(let snapshot) = state,
              let agent = snapshot.raw.agents[paneID] else {
            return (nil, nil, nil)
        }
        return (
            agent: agent,
            workspace: Self.identifier(agent, "workspace_id").flatMap { snapshot.raw.workspaces[$0] },
            tab: Self.identifier(agent, "tab_id").flatMap { snapshot.raw.tabs[$0] }
        )
    }

    private static func identifier(_ record: JSONValue, _ key: String) -> String? {
        guard case .string(let id)? = record[key] else { return nil }
        return id
    }

    // Terminal text lives in AgentReadMonitor rather than AgentSnapshot, so
    // excerpt changes do not make consecutive snapshots unequal.
    func agentExcerpt(for paneID: String) -> AgentExcerpt? {
        agentReadMonitor.excerpt(for: paneID)
    }

    func agentExcerptState(for paneID: String) -> AgentExcerptState {
        agentReadMonitor.excerptState(for: paneID)
    }

    private func groupWorkspace(for workspaceId: String) -> Workspace {
        guard let workspace = workspaces[workspaceId] else {
            return Workspace(workspaceId: workspaceId, label: workspaceId, number: Int.max)
        }
        guard let worktree = workspace.worktree, worktree.isLinkedWorktree else {
            return workspace
        }
        return rootWorkspacesByRepoKey[worktree.repoKey] ?? workspace
    }

    // When several workspaces open the same repo root, the lower-numbered one
    // wins so the merge target does not change between polls.
    private var rootWorkspacesByRepoKey: [String: Workspace] {
        workspaces.values.reduce(into: [:]) { roots, workspace in
            guard let worktree = workspace.worktree, !worktree.isLinkedWorktree else { return }
            if let existing = roots[worktree.repoKey], existing.number <= workspace.number {
                return
            }
            roots[worktree.repoKey] = workspace
        }
    }

    // MARK: - Lifecycle

    // There is no restart after stop: FleetStore builds a new Store instead, so
    // RPCs of the old one can never reach the new runtime.
    func start() {
        guard !hasStarted, !hasBeenStopped else { return }
        hasStarted = true
        if case .ready = state {
            // A restored snapshot stays on display until the first poll lands.
        } else {
            state = .synchronizing
        }
        // A remote whose tunnel becomes ready during the transition to sleep does
        // not start fetching; it waits for resumePolling().
        guard !isPollingSuspended else { return }
        requestSnapshot()
        startPolling()
    }

    func stop() {
        guard hasStarted, !hasBeenStopped else { return }
        hasBeenStopped = true
        pollingTask?.cancel()
        pollingTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        agentReadMonitor.stop()
        state = .disconnected
    }

    // Resumable counterpart of stop() for system sleep: the display snapshot and
    // the started state survive.
    func suspendPolling() {
        guard !isPollingSuspended else { return }
        isPollingSuspended = true
        agentReadMonitor.suspend()
        pollingTask?.cancel()
        pollingTask = nil
        // snapshotTask is not reset to nil. This keeps requestSnapshot's
        // duplicate guard in effect until the cancelled task completes
        // (loadSnapshot's defer), so the same RPC is not issued twice right
        // after resume.
        snapshotTask?.cancel()
    }

    // Also the initial fetch for a Store that was suspended before start().
    func resumePolling() {
        guard isPollingSuspended else { return }
        isPollingSuspended = false
        agentReadMonitor.resume()
        guard hasStarted, !hasBeenStopped else { return }
        requestSnapshot()
        startPolling()
    }

    // Called when the transport drops before session.snapshot itself fails.
    func markAgentContentSourceUnavailable() {
        agentReadMonitor.sourceUnavailable()
    }

    // The SSH tunnel and socket path do not change with the interval, so the
    // connection is kept and only the current sleep is cancelled.
    func setPollInterval(_ interval: Duration) {
        precondition(interval > .zero)
        guard pollInterval != interval else { return }
        pollInterval = interval
        // While suspended, only the interval is updated; resumePolling() starts
        // polling with the new interval.
        guard hasStarted, !hasBeenStopped, !isPollingSuspended else { return }
        pollingTask?.cancel()
        startPolling()
    }

    private func startPolling() {
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    return
                }
                self.requestSnapshot()
            }
        }
    }

    private func requestSnapshot() {
        // A poll tick that finished its sleep and was awaiting resumption can
        // arrive here without observing cancellation, so stop and suspend are
        // also checked here, separately from task cancellation.
        guard hasStarted, !hasBeenStopped, !isPollingSuspended, snapshotTask == nil else { return }
        snapshotTask = Task { @MainActor [weak self] in
            await self?.loadSnapshot()
        }
    }

    private func loadSnapshot() async {
        defer { snapshotTask = nil }
        do {
            let fetch = try await dataSource.snapshot()
            let serverSnapshot = fetch.session
            guard !Task.isCancelled, !hasBeenStopped else { return }
            if serverSnapshot.protocolVersion != Herdr.supportedProtocol,
               serverProtocol != serverSnapshot.protocolVersion {
                log.warning("monitoring optimistically: server protocol \(serverSnapshot.protocolVersion) != supported \(Herdr.supportedProtocol)")
            }
            serverProtocol = serverSnapshot.protocolVersion
            let branches = await fetchBranches(for: serverSnapshot)
            guard !Task.isCancelled, !hasBeenStopped else { return }
            agentReadMonitor.update(panes: serverSnapshot.agentsWithScroll())
            publish(
                AgentSnapshot(
                    agents: serverSnapshot.agents,
                    workspaces: serverSnapshot.workspaces,
                    branches: branches,
                    raw: fetch.raw
                )
            )
        } catch {
            guard !Task.isCancelled, !hasBeenStopped else { return }
            agentReadMonitor.sourceUnavailable()
            state = failureState(after: error)
            log.debug("snapshot failed: \(String(describing: error))")
        }
    }

    private func failureState(after error: Error) -> StoreState {
        let mismatched = (error as? SnapshotSchemaError)?.serverProtocol ?? serverProtocol
        if let mismatched, mismatched != Herdr.supportedProtocol {
            return .protocolMismatch(mismatched)
        }
        return .disconnected
    }

    // One worktree.list response carries open_workspace_id for every workspace
    // opening the same repo, so workspaces an earlier response already resolved
    // are skipped. Workspace worktree metadata cannot be used to filter: some
    // git workspaces carry none in session.snapshot. Detached HEAD has no branch
    // and is left unmapped, and a failed workspace only loses a display
    // decoration.
    private func fetchBranches(
        for snapshot: HerdrSessionSnapshot
    ) async -> [String: String] {
        let trackedWorkspaceIDs = Set(
            snapshot.agents.filter(Self.shouldTrack).map(\.workspaceId)
        )
        var branches: [String: String] = [:]
        for workspace in snapshot.workspaces {
            guard trackedWorkspaceIDs.contains(workspace.workspaceId),
                  branches[workspace.workspaceId] == nil else { continue }
            do {
                let list = try await dataSource.worktrees(workspace.workspaceId)
                for entry in list.worktrees {
                    guard let workspaceID = entry.openWorkspaceId,
                          let branch = entry.branch else { continue }
                    branches[workspaceID] = branch
                }
            } catch {
                log.debug(
                    "worktree.list failed for \(workspace.workspaceId, privacy: .public): \(String(describing: error))"
                )
            }
            if Task.isCancelled || hasBeenStopped { break }
        }
        return branches
    }

    // agent_kind is matched exactly, so a pane with missing metadata or an
    // unknown kind stays visible rather than disappearing.
    nonisolated static func shouldTrack(_ pane: Pane) -> Bool {
        pane.agent != nil && pane.tokens?.agentKind != "subagent"
    }

    private func publish(_ snapshot: AgentSnapshot) {
        if case .ready(let previous) = state {
            for (paneId, pane) in snapshot.panes {
                if let old = previous.panes[paneId], old.agentStatus != pane.agentStatus {
                    log.info("status: \(paneId, privacy: .public) \(old.agentStatus.rawValue, privacy: .public) -> \(pane.agentStatus.rawValue, privacy: .public) (snapshot)")
                }
            }
            guard previous != snapshot else { return }
        }
        state = .ready(snapshot)
    }

    // MARK: - Ordering

    // A merged group mixes panes from several workspaces, so the workspace
    // number keeps root panes before worktree panes. `pane_id` makes the order
    // total when one tab holds several agent panes or the tab record is absent.
    private func paneSortKey(_ pane: Pane) -> (Int, Int, String) {
        (
            workspaces[pane.workspaceId]?.number ?? Int.max,
            tabNumber(for: pane),
            pane.paneId
        )
    }

    // session.snapshot keeps `tab_id` on the agent record and `number` on the
    // tab record, so the two must be joined here.
    private func tabNumber(for pane: Pane) -> Int {
        guard case .ready(let snapshot) = state,
              let agent = snapshot.raw.agents[pane.paneId],
              case .string(let tabID)? = agent["tab_id"],
              case .int(let number)? = snapshot.raw.tabs[tabID]?["number"] else {
            return Int.max
        }
        return Int(exactly: number) ?? Int.max
    }
}
