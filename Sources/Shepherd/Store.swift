// Observed state of a single herdr endpoint. Reads session.snapshot's protocol,
// agents, and workspaces as one value and transfers them onto a display snapshot
// on the MainActor.
//
// Synchronization contract:
//   - events.subscribe is not used. Herdr events do not replay history, and
//     pane.updated cannot be filtered per field, so we do not hold a high-frequency
//     stream per connection that includes updates outside the watch set
//   - start() fetches once immediately, then re-fetches at each source's
//     pollInterval. Local uses 500ms; remote uses the saved setting (default 2s)
//     passed in by FleetStore
//   - When a poll tick overlaps an in-flight fetch, the in-flight one is awaited.
//     No extra fetch is issued right after completion; the next tick catches up to
//     the latest state, so RPCs do not pile up on a slow endpoint
//   - snapshot returns agents and workspaces from the same server capture, plus
//     the verbatim herdr records of that same response line for the template
//     layer. It is published as ready from the first response after the protocol
//     matches
//   - Branch names alone are not included in session.snapshot, so worktree.list is
//     additionally fetched within the same poll for each workspace that has watched
//     panes. One response returns branches for every workspace opening the same
//     repo, so workspaces already resolved by an earlier response are not
//     re-fetched. The result is written into the raw workspace records under
//     `branch`, which is where `{herdr.workspace.branch}` reads it. Failure of this
//     fetch (including non-git workspaces) only means a missing display decoration
//     (no branch name) and does not make the whole poll disconnected
//   - On session.snapshot failure, the stale list is not published; state returns
//     to disconnected. Polling is not stopped, and the next success returns to ready
//   - stop() cancels the poll and the in-flight task. If synchronous I/O returns
//     after cancellation, it is not reflected into state
//   - suspendPolling() / resumePolling() are a resumable pause for system sleep.
//     suspend cancels the poll and in-flight RPCs and does not reflect their
//     results into state. resume fetches once immediately, then restarts polling
//   - AgentReadMonitor is a separate projection fed by every successful
//     snapshot. While the excerpt preference is on, it reads screens in the
//     background (on status changes and at the preference's cadence while a
//     pane works) so the excerpt cache is ready before any UI surface opens,
//     without delaying snapshot or branch publication
//
// No read/unread tracking is kept. blocked/done are herdr-side states; viewing the
// pane in herdr turns done back to idle, and this app's display clears on the next
// poll accordingly.

import Foundation
import Observation
import os

private let log = Logger(subsystem: "io.github.cryks.shepherd", category: "store")

/// Observed snapshot the UI receives in a single write.
/// panes and workspaces are built from the same session.snapshot; neither side is
/// updated separately later.
struct AgentSnapshot: Equatable {
    var panes: [String: Pane]
    var workspaces: [String: Workspace]
    /// The same records as panes and workspaces, kept as herdr sent them, for
    /// the row and notification templates. agents holds one entry per tracked
    /// pane; workspaces and tabs stay whole, since a tracked pane can point at
    /// any of them. Equality of a snapshot therefore covers every herdr field,
    /// not only the ones the typed models read.
    var raw: HerdrRawSnapshot

    /// Converts server snapshot arrays into ID-keyed dictionaries for the UI.
    /// Subagent panes and panes with no detected agent are excluded at this
    /// boundary and never mixed into anything downstream in the display layer.
    ///
    /// - Parameters:
    ///   - branches: Workspace ID → branch name from worktree.list. Each entry
    ///     is written onto the matching raw workspace record as `branch`, the
    ///     one field of that record herdr did not send.
    ///   - raw: Records of the same session.snapshot response. Untracked panes
    ///     are dropped from it here, so a subagent's record is not retained by
    ///     the snapshot the UI holds.
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

/// Published state of the connection and display data. Only ready serves as the
/// data source for the menu bar and monitor window; a stale snapshot after an RPC
/// failure is never left on display.
enum StoreState: Equatable {
    case disconnected
    case synchronizing
    case ready(AgentSnapshot)
    /// The server responded but its protocol differs from Herdr.supportedProtocol.
    case protocolMismatch(Int)
}

/// One session.snapshot response in both forms the app needs: the typed model
/// the store reduces, and the records exactly as herdr wrote them, which the
/// template layer addresses by their snake_case names.
struct SnapshotFetch {
    var session: HerdrSessionSnapshot
    var raw: HerdrRawSnapshot

    /// Test and preview fixtures that only exercise the typed path.
    init(session: HerdrSessionSnapshot, raw: HerdrRawSnapshot = .empty) {
        self.session = session
        self.raw = raw
    }
}

/// RPC boundary the Store reads through. Tests control response completion and
/// failure to reproduce the initial fetch, polling, and races with stop without a
/// real socket.
struct StoreDataSource: Sendable {
    var snapshot: @Sendable () async throws -> SnapshotFetch
    /// Worktree list of the repo the workspace belongs to. Used only for showing
    /// the pane's branch name; failure has no bearing on the poll's success.
    var worktrees: @Sendable (_ workspaceID: String) async throws -> WorktreeListResult

    /// For remote endpoints, this pins the local-side socket of the SSH tunnel so
    /// no part of the poll leaks to the local herdr.
    static func live(socketPath: String) -> StoreDataSource {
        StoreDataSource(
            snapshot: {
                // One RPC, two decodes of its response line: makeDecoder() for
                // the typed model, and a plain decoder for the raw tree, whose
                // dynamic keys .convertFromSnakeCase would otherwise rewrite.
                try await Herdr.request(
                    "session.snapshot",
                    socketPath: socketPath,
                    as: SessionSnapshotResult.self
                ) { result, responseLine in
                    SnapshotFetch(
                        session: result.snapshot,
                        raw: try HerdrRawSnapshot.decode(responseLine: responseLine)
                    )
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
    /// FleetStore applies remote setting changes without an SSH reconnect. Values
    /// of zero or less would busy-loop and are rejected; production only passes
    /// the RemotePollingInterval presets.
    private(set) var pollInterval: Duration

    /// Returns an empty dictionary outside ready, so no path exists for the display
    /// layer to reuse a pre-disconnect snapshot.
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
    /// Pause during system sleep. Unlike hasBeenStopped, it can be lifted with
    /// resumePolling(). A remote may be suspended while waiting for tunnel ready,
    /// so this flag can be set before start().
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

    /// Creates a live endpoint that reads only the given socket. The owner states
    /// the local/remote interval explicitly, avoiding call sites where a default
    /// argument would give a remote 500ms.
    static func live(socketPath: String, pollInterval: Duration) -> Store {
        Store(
            dataSource: .live(socketPath: socketPath),
            agentReadDataSource: .live(socketPath: socketPath),
            pollInterval: pollInterval
        )
    }

    // MARK: - Derived views

    /// Per-workspace groups for the monitor window, ordered by workspace number.
    /// A linked-worktree workspace does not get its own heading; its panes merge
    /// into the group of the workspace opening the same repo's root checkout (the
    /// heading is the root side's label). Within a group, panes are ordered by
    /// workspace number then Herdr tab number, so root panes come before worktree
    /// panes and each workspace follows the tab order shown by Herdr.
    /// Linked worktrees whose root checkout is not open as a workspace, and
    /// workspaces without a heading in the snapshot, appear under their own heading.
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

    /// Verbatim herdr records addressed by the template language, for one
    /// tracked pane.
    ///
    /// The workspace is the pane's own `workspace_id`, never the workspace a
    /// linked worktree is displayed under, so `{herdr.workspace.*}` describes
    /// the checkout the agent actually runs in. The tab is resolved through the
    /// agent record's `tab_id`: pane and tab ids number independently, so it
    /// cannot be derived from the pane id.
    ///
    /// Every element is nil outside `ready`, for an untracked or unknown pane,
    /// and for a record herdr did not send.
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

    /// String value of an id field, or nil when the key is absent or holds
    /// another JSON type.
    private static func identifier(_ record: JSONValue, _ key: String) -> String? {
        guard case .string(let id)? = record[key] else { return nil }
        return id
    }

    /// Current display-safe line for a pane. Terminal text stays in the
    /// endpoint's AgentReadMonitor rather than entering AgentSnapshot.
    func agentExcerpt(for paneID: String) -> AgentExcerpt? {
        agentReadMonitor.excerpt(for: paneID)
    }

    /// Loading state for a supported pane's Excerpt. FleetStore verifies
    /// endpoint readiness and grammar support before exposing this to a row.
    func agentExcerptState(for paneID: String) -> AgentExcerptState {
        agentReadMonitor.excerptState(for: paneID)
    }

    /// The workspace of the group a pane belongs to for display purposes. Panes of
    /// linked worktrees are merged into the workspace opening the root checkout of
    /// the same repoKey.
    private func groupWorkspace(for workspaceId: String) -> Workspace {
        guard let workspace = workspaces[workspaceId] else {
            return Workspace(workspaceId: workspaceId, label: workspaceId, number: Int.max)
        }
        guard let worktree = workspace.worktree, worktree.isLinkedWorktree else {
            return workspace
        }
        return rootWorkspacesByRepoKey[worktree.repoKey] ?? workspace
    }

    /// repoKey → the workspace opening the root checkout. When multiple workspaces
    /// open the same repo root, the lower-numbered one (the one listed earlier in
    /// herdr) becomes the merge target.
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

    /// Starts the initial snapshot and polling. Repeated calls do not multiply
    /// tasks, and there is no restart after stop. On settings OFF/ON, FleetStore
    /// creates a new Store so stale RPC completions never reach the new runtime.
    func start() {
        guard !hasStarted, !hasBeenStopped else { return }
        hasStarted = true
        if case .ready = state {
            // A Store holding a restored snapshot before start keeps showing it
            // until the first poll completes.
        } else {
            state = .synchronizing
        }
        // A remote whose tunnel becomes ready during the transition to sleep does
        // not start fetching; it waits for resumePolling().
        guard !isPollingSuspended else { return }
        requestSnapshot()
        startPolling()
    }

    /// Stops polling and in-flight RPCs when the endpoint is removed or disabled,
    /// and discards the display snapshot.
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

    /// Stops polling and in-flight RPCs just before system sleep. Unlike stop(),
    /// the display snapshot and started state are kept, and resumePolling() can
    /// restart. If a cancelled RPC returns after wake, loadSnapshot's
    /// Task.isCancelled guard keeps it out of state.
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

    /// Fetches once immediately on wake from sleep and restarts polling. For a
    /// Store suspended before start(), this is the initial fetch.
    func resumePolling() {
        guard isPollingSuspended else { return }
        isPollingSuspended = false
        agentReadMonitor.resume()
        guard hasStarted, !hasBeenStopped else { return }
        requestSnapshot()
        startPolling()
    }

    /// Clears screen-derived lifecycle state when the endpoint transport drops
    /// before session.snapshot itself reports failure.
    func markAgentContentSourceUnavailable() {
        agentReadMonitor.sourceUnavailable()
    }

    /// Applies a remote-settings poll preset change to the existing Store. The SSH
    /// tunnel and socket path do not change, so the connection is not rebuilt;
    /// only the current sleep is cancelled and the new interval takes over.
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
            guard serverSnapshot.protocolVersion == Herdr.supportedProtocol else {
                log.error("protocol mismatch: server=\(serverSnapshot.protocolVersion)")
                agentReadMonitor.sourceUnavailable()
                state = .protocolMismatch(serverSnapshot.protocolVersion)
                return
            }
            let branches = await fetchBranches(for: serverSnapshot)
            guard !Task.isCancelled, !hasBeenStopped else { return }
            agentReadMonitor.update(panes: serverSnapshot.agents)
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
            state = .disconnected
            log.debug("snapshot failed: \(String(describing: error))")
        }
    }

    /// Fetches worktree.list for each workspace that has watched panes and builds
    /// the workspace ID → branch name mapping. One response returns branches with
    /// open_workspace_id for every workspace opening the same repo, so workspaces
    /// already resolved by an earlier response are not re-fetched. The workspace's
    /// worktree metadata is not used to filter (some workspaces are git repos yet
    /// carry no metadata in session.snapshot). Branch is display decoration, so a
    /// failed workspace (including non-git ones) proceeds without a mapping (its
    /// pane shows no branch name) and has no bearing on the poll's success.
    /// Detached-HEAD checkouts have no branch and are not recorded.
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

    /// Whether the pane should be kept in Store.panes. agent_kind is matched
    /// exactly; agents with missing metadata or an unknown value stay in the list.
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

    /// Sort key for panes within a group. A merged group mixes panes from
    /// multiple workspaces, so the workspace number keeps the root → worktree
    /// order. Herdr's tab number is the display order within one workspace.
    /// `pane_id` is an opaque stable identifier and makes the order total when a
    /// tab contains multiple agent panes or the raw tab record is absent.
    private func paneSortKey(_ pane: Pane) -> (Int, Int, String) {
        (
            workspaces[pane.workspaceId]?.number ?? Int.max,
            tabNumber(for: pane),
            pane.paneId
        )
    }

    /// Number of the tab containing this pane. `session.snapshot` keeps `tab_id`
    /// on the agent record and `number` on the matching tab record; a missing or
    /// out-of-range value sorts after numbered tabs.
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
