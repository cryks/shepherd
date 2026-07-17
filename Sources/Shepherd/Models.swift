// Types only for the portion of the herdr socket API (protocol 16) JSON that
// this app reads. session.snapshot's agents elements are received as Pane and
// its workspaces elements as Workspace; worktree.list's worktrees elements are
// received as WorktreeEntry.
// Decoding assumes keyDecodingStrategy = .convertFromSnakeCase, so field names
// are the JSON's snake_case converted to camelCase. Unknown keys are ignored.

import Foundation

/// Agent status herdr reports per pane.
/// idle and done are the same underlying "waiting" state; done applies only
/// while the completion result is unviewed in herdr. Viewing the pane in herdr
/// turns done back to idle, so this app keeps no read/unread tracking of its own.
enum AgentStatus: String, Codable {
    case idle, working, blocked, done, unknown
}

/// An agents element of session.snapshot.
/// A pane with agent == nil is not an agent pane (a plain shell, etc.).
struct Pane: Codable, Identifiable, Equatable {
    /// Detected agent name (claude, codex, ...). nil means not a watch target.
    var agent: String?
    var agentStatus: AgentStatus
    var paneId: String
    var workspaceId: String
    /// Used as the agent.focus target for local rows. The pane ID changes when
    /// the pane moves, but the terminal ID is stable. Remote rows are
    /// monitor-only and never used for sending.
    var terminalId: String?
    /// Terminal title with decorations like spinners stripped. Used to show the
    /// agent's current work.
    var terminalTitleStripped: String?
    /// herdr metadata describing the pane's origin and similar. May be nil at
    /// pane.created time and in the snapshot right after agent detection; a
    /// subsequent poll fills it in.
    var tokens: PaneTokens?
    /// When the pane's workspace opens a git checkout, Store writes the branch
    /// from worktree.list here. session.snapshot's JSON has no corresponding
    /// key, so it is nil right after decoding. It stays nil for non-git
    /// workspaces, detached HEAD, and polls where the worktree.list fetch
    /// failed; the sub-row then shows no location (no fallback text like cwd).
    var branch: String? = nil

    var id: String { paneId }

    /// Text for the main row in lists (menu, monitor window).
    /// While the work title is empty (e.g. right after the agent starts), the
    /// agent name fills in.
    var displayTitle: String {
        if let title = terminalTitleStripped, !title.isEmpty { return title }
        return agent ?? "?"
    }

    /// Text form of the "who and where" sub-row in lists.
    /// For agents with a mark asset, AgentRow composes the sub-row as icon +
    /// branch, so this is the fallback for agents without a mark. A pane
    /// without a branch shows only the agent name.
    var displaySubtitle: String {
        guard let branch else { return agent ?? "?" }
        return "\(agent ?? "?") — \(branch)"
    }
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

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case agents
        case workspaces
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
