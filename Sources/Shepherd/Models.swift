// Decoding of the herdr socket API (protocol 19) assumes
// keyDecodingStrategy = .convertFromSnakeCase; unknown keys are ignored.
//
// These types hold only the fields the app reasons about. A field that exists
// only to be displayed belongs in HerdrRawSnapshot, which the templates address
// by the names herdr wrote.

import Foundation

// idle and done are the same underlying waiting state; done lasts only while the
// result is unviewed in herdr, which flips it back to idle on its own.
enum AgentStatus: String, Codable, Sendable {
    case idle, working, blocked, done, unknown

    // A status added in a future protocol must not fail the whole snapshot, so
    // optimistic monitoring keeps every pane visible across protocol bumps.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .unknown
    }
}

// An agents element of session.snapshot.
struct Pane: Codable, Identifiable, Equatable {
    // nil for a pane herdr detected no agent in (a plain shell, etc.).
    var agent: String?
    var agentStatus: AgentStatus
    var paneId: String
    var workspaceId: String
    // Stable across pane moves, so AttentionMonitor correlates observations by
    // it. Protocol 19 agent methods reject terminal IDs, so calls still target
    // paneId.
    var terminalId: String?
    // Optional so synthetic and older cached fixtures can omit it. Herdr does
    // not advance it for every terminal write, so it cannot be used alone to
    // decide whether a screen read is needed.
    var revision: UInt64? = nil
    // Only the panes records report scroll, so an agents record decodes this as
    // nil. agentsWithScroll() fills it for AgentReadMonitor while display
    // snapshots keep it nil, so scrolling alone cannot make two snapshots
    // unequal.
    var scrollOffsetFromBottom: Int? = nil
    // Terminal title with decorations such as spinners already stripped.
    var terminalTitleStripped: String?
    // May be nil at pane.created time and in the snapshot right after agent
    // detection; a later poll fills it in.
    var tokens: PaneTokens?

    var id: String { paneId }
}

// A panes element of session.snapshot. These records cover every terminal pane,
// agent or not; agent identity and status stay in the agents records.
struct SnapshotPane: Codable, Equatable {
    var paneId: String
    // nil when herdr reports no scroll for the pane, which means the tail.
    var scroll: PaneScroll?
}

struct PaneScroll: Codable, Equatable {
    // 0 at the tail.
    var offsetFromBottom: Int
}

struct PaneTokens: Codable, Equatable {
    // Kept as String, not an enum, so a value added later still decodes.
    // `"subagent"` marks a subagent pane.
    var agentKind: String?
}

struct Workspace: Codable, Identifiable, Equatable {
    var workspaceId: String
    var label: String?
    // Display number in the herdr UI, which also orders the groups here.
    var number: Int
    // nil for a workspace that opens no git checkout.
    var worktree: WorkspaceWorktree? = nil

    var id: String { workspaceId }
}

struct WorkspaceWorktree: Codable, Equatable {
    // The repo root's .git path. Identical for the root checkout and its linked
    // worktrees, which is what merges their panes into one group.
    var repoKey: String
    // true for a checkout made with `git worktree add`; the false side is the
    // merge target.
    var isLinkedWorktree: Bool
}

// MARK: - RPC envelope

struct RPCError: Codable, Error {
    var code: String
    var message: String
}

// result and error are mutually exclusive.
struct RPCResponse<R: Codable>: Codable {
    var id: String?
    var result: R?
    var error: RPCError?
}

struct HerdrSessionSnapshot: Codable {
    var version: String
    var protocolVersion: Int
    var agents: [Pane]
    var workspaces: [Workspace]
    var panes: [SnapshotPane]? = nil

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case agents
        case workspaces
        case panes
    }

    // Joining scroll offsets is a separate step rather than part of decoding
    // because only AgentReadMonitor wants them; the published snapshot must keep
    // agents free of scroll state.
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

struct SessionSnapshotResult: Codable {
    var snapshot: HerdrSessionSnapshot
}

// Result of `worktree.list`: the checkouts of the repo that the requested
// workspace_id belongs to.
struct WorktreeListResult: Codable {
    var worktrees: [WorktreeEntry]
}

struct WorktreeEntry: Codable {
    // nil for detached HEAD.
    var branch: String?
    // nil when no workspace has this checkout open.
    var openWorkspaceId: String?
}

// For RPCs whose result body is not read (agent.focus, etc.).
struct EmptyResult: Codable {}

// MARK: - Agent screen reads

// The whole value takes part in occupant identity: a terminal can keep its
// terminal ID while the agent process starts a different native session.
struct HerdrAgentSession: Codable, Equatable, Sendable {
    // Protocol 19 reports either a native session ID or a session path.
    enum Kind: String, Codable, Sendable {
        case id
        case path
    }

    // Authority that reported the session, such as `herdr:codex`.
    var source: String
    var agent: String
    var kind: Kind
    var value: String
}

// The protocol 19 subset of `AgentInfo` needed to bracket an `agent.read`:
// callers compare the values before and after the read so a status transition or
// an occupant swap cannot be presented as one coherent observation.
struct HerdrAgentInfo: Codable, Equatable, Sendable {
    // Optional because the protocol schema permits null, even though `agent.get`
    // resolves only panes that currently have agent identity.
    var agent: String?
    var agentStatus: AgentStatus
    var paneId: String
    var workspaceId: String
    var tabId: String
    var terminalId: String
    var revision: UInt64
    // Monotonic sequence of semantic agent-state transitions.
    var stateChangeSeq: UInt64
    // Absent for screen-detected sessions; present only when an official
    // integration reported one.
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
        // Herdr omits the field until a transition is recorded.
        stateChangeSeq = try container.decodeIfPresent(UInt64.self, forKey: .stateChangeSeq) ?? 0
        agentSession = try container.decodeIfPresent(HerdrAgentSession.self, forKey: .agentSession)
    }
}

struct AgentGetResult: Codable, Equatable, Sendable {
    var agent: HerdrAgentInfo
}

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
    // Unusable for correlation: herdr 0.8.0 hard-codes zero for every source,
    // and protocol 19 defines no relation to AgentInfo.revision.
    var revision: UInt64
    // True when herdr dropped bytes at its response limit.
    var truncated: Bool
}

struct AgentReadResult: Codable, Equatable, Sendable {
    var read: PaneRead
}
