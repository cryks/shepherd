// Types only for the portion of the herdr socket API (protocol 19) JSON that
// this app reads. session.snapshot's agents elements are received as Pane and
// its workspaces elements as Workspace; worktree.list's worktrees elements are
// received as WorktreeEntry. Agent screen monitoring decodes agent.get into
// HerdrAgentInfo and agent.read into PaneRead.
// Decoding assumes keyDecodingStrategy = .convertFromSnakeCase, so field names
// are the JSON's snake_case converted to camelCase. Unknown keys are ignored.
//
// These types hold only what herdr sent, in the fields this app reads; no
// display text is derived here. Rows and notifications render templates against
// the verbatim records in HerdrRawSnapshot, so a field that exists only to be
// shown belongs there, not on Pane or Workspace.

import Foundation

/// Agent status herdr reports per pane.
/// idle and done are the same underlying "waiting" state; done applies only
/// while the completion result is unviewed in herdr. Viewing the pane in herdr
/// turns done back to idle, so this app keeps no read/unread tracking of its own.
enum AgentStatus: String, Codable, Sendable {
    case idle, working, blocked, done, unknown

    /// A status herdr adds in a future protocol decodes as unknown instead of
    /// failing the whole snapshot, so optimistic monitoring across protocol
    /// bumps keeps every pane visible.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

/// An agents element of session.snapshot.
/// A pane with agent == nil is not an agent pane (a plain shell, etc.).
struct Pane: Codable, Identifiable, Equatable {
    /// Detected agent name (claude, codex, ...). nil means not a watch target.
    var agent: String?
    var agentStatus: AgentStatus
    var paneId: String
    var workspaceId: String
    /// Stable identity across pane moves. AttentionMonitor uses it to correlate
    /// observations and notification IDs; protocol 19 agent methods reject
    /// terminal IDs, so LocalAgentFocus targets the current paneId instead.
    var terminalId: String?
    /// Pane revision from session.snapshot. It is optional in Shepherd's model
    /// so synthetic and older cached fixtures can omit it; protocol 19 supplies
    /// it for live agents. Herdr does not advance it for every terminal write,
    /// so AgentReadMonitor uses each successful snapshot as a read opportunity.
    var revision: UInt64? = nil
    /// Rows the terminal viewport sits above the newest buffer row; 0 when the
    /// view is pinned to the tail. session.snapshot reports scroll only in its
    /// panes records, so decoding an agents record leaves this nil;
    /// HerdrSessionSnapshot.agentsWithScroll() fills it for AgentReadMonitor,
    /// while display snapshots keep it nil so scroll movement alone cannot
    /// make consecutive snapshots unequal.
    var scrollOffsetFromBottom: Int? = nil
    /// Terminal title with decorations like spinners stripped. Used to show the
    /// agent's current work.
    var terminalTitleStripped: String?
    /// herdr metadata describing the pane's origin and similar. May be nil at
    /// pane.created time and in the snapshot right after agent detection; a
    /// subsequent poll fills it in.
    var tokens: PaneTokens?

    var id: String { paneId }
}

/// A panes element of session.snapshot. The panes records describe every
/// terminal pane, agent or not; Shepherd reads only the identity and viewport
/// scroll state here. Agent identity and status stay in the agents records
/// that decode into Pane.
struct SnapshotPane: Codable, Equatable {
    var paneId: String
    /// nil when herdr does not report scroll for this pane; treated as a
    /// viewport pinned to the tail.
    var scroll: PaneScroll?
}

/// Viewport scroll state of one pane.
struct PaneScroll: Codable, Equatable {
    /// Rows the viewport sits above the newest buffer row; 0 at the tail.
    var offsetFromBottom: Int
}

/// The portion of the metadata herdr attaches to a pane that Shepherd reads.
/// agent_kind is kept as String so the whole pane still decodes when values are
/// added in the future.
struct PaneTokens: Codable, Equatable {
    /// The pane's origin. `"subagent"` for subagents; nil when metadata is
    /// missing or herdr does not classify the pane's origin.
    var agentKind: String?
}

/// A workspaces element of session.snapshot. Used for the monitor window's
/// group headings and ordering.
struct Workspace: Codable, Identifiable, Equatable {
    var workspaceId: String
    var label: String?
    /// Display number in the herdr UI. Used for group ordering.
    var number: Int
    /// Present only when the workspace opens a git checkout; nil for non-git
    /// workspaces.
    var worktree: WorkspaceWorktree? = nil

    var id: String { workspaceId }
}

/// The portion of the worktree metadata on a session.snapshot workspace that is
/// read. Used to correlate workspaces that opened the same repo.
struct WorkspaceWorktree: Codable, Equatable {
    /// The repo root's .git path. Same value for the root checkout and linked
    /// worktrees, serving as the key that merges linked-worktree panes into the
    /// root checkout's group.
    var repoKey: String
    /// true for a checkout created with `git worktree add`. false for the repo
    /// root's checkout, which becomes the merge target for linked worktrees in
    /// the monitor list.
    var isLinkedWorktree: Bool
}

// MARK: - RPC envelope

struct RPCError: Codable, Error {
    var code: String
    var message: String
}

/// Response line of a one-shot RPC. result and error are mutually exclusive.
struct RPCResponse<R: Codable>: Codable {
    var id: String?
    var result: R?
    var error: RPCError?
}

/// Bootstrap payload returned by `session.snapshot`. Shepherd reads not every
/// pane but only rows detected as agents, plus the workspaces needed for their
/// group headings.
/// version and protocol come in the same fetch result, so no separate ping RPC
/// is inserted.
struct HerdrSessionSnapshot: Codable {
    var version: String
    var protocolVersion: Int
    var agents: [Pane]
    var workspaces: [Workspace]
    /// The panes records of the same capture, read only for viewport scroll.
    var panes: [SnapshotPane]? = nil

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case agents
        case workspaces
        case panes
    }

    /// agents with each pane's viewport scroll offset joined by pane_id from
    /// the panes records. The join is a separate step rather than part of
    /// decoding because only AgentReadMonitor consumes the joined form; the
    /// published display snapshot keeps the plain agents.
    func agentsWithScroll() -> [Pane] {
        let offsets: [String: Int] = Dictionary(
            (panes ?? []).compactMap { record in
                record.scroll.map { (record.paneId, $0.offsetFromBottom) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard !offsets.isEmpty else { return agents }
        var joined = agents
        for index in joined.indices {
            joined[index].scrollOffsetFromBottom = offsets[joined[index].paneId]
        }
        return joined
    }
}

/// The result of `session.snapshot` wraps the type name and the snapshot body
/// one level deep. The unused `type` is ignored by the decoder, and only the
/// snapshot body is passed to Store.
struct SessionSnapshotResult: Codable {
    var snapshot: HerdrSessionSnapshot
}

/// Result of `worktree.list`. Returns the checkout list of the repo that the
/// workspace_id in params belongs to. Shepherd reads only what it needs to show
/// branch names.
struct WorktreeListResult: Codable {
    var worktrees: [WorktreeEntry]
}

/// A worktrees element of worktree.list. Includes both the root checkout and
/// linked worktrees.
struct WorktreeEntry: Codable {
    /// Name of the checked-out branch. nil for detached HEAD.
    var branch: String?
    /// ID of the workspace that has this checkout open. nil if no workspace has
    /// it open.
    var openWorkspaceId: String?
}

/// For RPCs whose result body is not read (agent.focus, etc.).
struct EmptyResult: Codable {}

// MARK: - Agent screen reads

/// The native session reference Herdr associates with the current agent
/// occupant. The whole value participates in occupant identity: a terminal may
/// keep its terminal ID while the agent process starts a different native
/// session.
struct HerdrAgentSession: Codable, Equatable, Sendable {
    /// Representation used for `value`. Protocol 19 supports either a native
    /// session ID or a session path.
    enum Kind: String, Codable, Sendable {
        case id
        case path
    }

    /// Authority that reported the native session, such as `herdr:codex`.
    var source: String
    /// Canonical agent label belonging to the reported session.
    var agent: String
    var kind: Kind
    var value: String
}

/// The protocol 19 subset of `AgentInfo` needed to bracket an `agent.read`.
/// Callers compare values returned before and after a screen read so a status
/// transition or occupant replacement cannot be presented as one coherent
/// observation.
struct HerdrAgentInfo: Codable, Equatable, Sendable {
    /// Canonical agent label. The protocol schema permits null even though
    /// `agent.get` resolves only panes that currently have agent identity.
    var agent: String?
    var agentStatus: AgentStatus
    var paneId: String
    var workspaceId: String
    var tabId: String
    /// Stable terminal identity across pane moves.
    var terminalId: String
    /// Pane presentation and metadata revision captured by `agent.get`.
    var revision: UInt64
    /// Monotonic sequence for semantic agent-state transitions. Herdr omits the
    /// field when no transition has been recorded, which decodes as zero.
    var stateChangeSeq: UInt64
    /// Native agent session identity when an official integration has reported
    /// one. It is absent for screen-detected sessions.
    var agentSession: HerdrAgentSession?

    private enum CodingKeys: String, CodingKey {
        case agent
        case agentStatus
        case paneId
        case workspaceId
        case tabId
        case terminalId
        case revision
        case stateChangeSeq
        case agentSession
    }

    init(
        agent: String?,
        agentStatus: AgentStatus,
        paneId: String,
        workspaceId: String,
        tabId: String,
        terminalId: String,
        revision: UInt64,
        stateChangeSeq: UInt64,
        agentSession: HerdrAgentSession?
    ) {
        self.agent = agent
        self.agentStatus = agentStatus
        self.paneId = paneId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.terminalId = terminalId
        self.revision = revision
        self.stateChangeSeq = stateChangeSeq
        self.agentSession = agentSession
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        agentStatus = try container.decode(AgentStatus.self, forKey: .agentStatus)
        paneId = try container.decode(String.self, forKey: .paneId)
        workspaceId = try container.decode(String.self, forKey: .workspaceId)
        tabId = try container.decode(String.self, forKey: .tabId)
        terminalId = try container.decode(String.self, forKey: .terminalId)
        revision = try container.decode(UInt64.self, forKey: .revision)
        stateChangeSeq = try container.decodeIfPresent(UInt64.self, forKey: .stateChangeSeq) ?? 0
        agentSession = try container.decodeIfPresent(HerdrAgentSession.self, forKey: .agentSession)
    }
}

/// Result body returned by `agent.get`.
struct AgentGetResult: Codable, Equatable, Sendable {
    var agent: HerdrAgentInfo
}

/// Plain terminal data returned inside the protocol's `pane_read` result.
struct PaneRead: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case visible
        case recent
        case recentUnwrapped = "recent_unwrapped"
        case detection
    }

    enum Format: String, Codable, Sendable {
        case text
        case ansi
    }

    var paneId: String
    var workspaceId: String
    var tabId: String
    var source: Source
    var format: Format
    var text: String
    /// Protocol revision field returned with `text`. Herdr 0.8.0 hard-codes zero
    /// for every source, and protocol 19 defines no correlation with AgentInfo.
    var revision: UInt64
    /// True when Herdr omitted bytes because its response limit was reached.
    var truncated: Bool
}

/// Result body returned by `agent.read`.
struct AgentReadResult: Codable, Equatable, Sendable {
    var read: PaneRead
}
