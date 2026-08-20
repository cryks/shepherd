// Synthetic agents for the Display settings preview, so templates can be tuned
// with no herdr running. The two panes differ on purpose: the codex pane has a
// branch and an excerpt, the claude pane has neither and an empty terminal
// title, which is what makes `[...]` group behavior visible.
//
// The sample is a whole `session.snapshot` response line put through both live
// decoders rather than hand-built values, so it cannot drift from the real key
// names and value types.

import Foundation

@MainActor
enum RowLayoutPreviewSample {
    // A nil excerptState is how the sample shows a pane with no excerpt
    // support.
    struct Entry: Identifiable {
        let context: AgentRowContext
        let excerptState: AgentExcerptState?

        var id: String { context.pane.paneId }
    }

    static let entries: [Entry] = panes.map { pane in
        let excerpt = excerpts[pane.paneId]
        let rawAgent = raw.agents[pane.paneId]
        return Entry(
            context: AgentRowContext(
                pane: pane,
                rawAgent: rawAgent,
                rawWorkspace: raw.workspaces[pane.workspaceId],
                rawTab: tabID(of: rawAgent).flatMap { raw.tabs[$0] },
                excerpt: excerpt?.text,
                // The live value is suppressed while no remote is visible, so
                // the sample always names a source to keep the separator in
                // `[{source} · ]` on screen.
                sourceLabel: LocalSectionTitleSetting.defaultTitle
            ),
            excerptState: excerpt.map(AgentExcerptState.available)
        )
    }

    // Verbatim records addressed by `{herdr.agent.*}`, `{herdr.workspace.*}`
    // and `{herdr.tab.*}`.
    private static let raw: HerdrRawSnapshot =
        (try? HerdrRawSnapshot.decode(responseLine: responseLine)) ?? .empty

    private static let panes: [Pane] =
        (try? makeDecoder().decode(RPCResponse<SessionSnapshotResult>.self, from: responseLine))?
            .result?.snapshot.agents ?? []

    private static let excerpts: [String: AgentExcerpt] = [
        "w1:p1": AgentExcerpt(
            text: "Rewrote the fallback so an empty title falls back to the agent name.",
            kind: .response,
            confidence: .medium,
            screenRevision: 4821
        ),
    ]

    private static func tabID(of record: JSONValue?) -> String? {
        guard case .string(let id)? = record?["tab_id"] else { return nil }
        return id
    }

    // The real home directory, so `{cwd_short}` visibly collapses to `~`
    // instead of showing a path that can never match.
    private static let home = NSHomeDirectory()

    // `branch` is written into the literal because the live path gets it from
    // worktree.list, which a synthetic snapshot cannot supply, and
    // `{herdr.workspace.branch}` still has to resolve.
    private static let responseLine = Data(
        """
        {
          "id": "shepherd:session.snapshot",
          "result": {
            "type": "session.snapshot",
            "snapshot": {
              "version": "0.8.2",
              "protocol": 20,
              "agents": [
                {
                  "pane_id": "w1:p1",
                  "workspace_id": "w1",
                  "tab_id": "w1:t1",
                  "terminal_id": "term-9f21",
                  "agent": "codex",
                  "display_agent": "Codex",
                  "agent_status": "working",
                  "title": "codex",
                  "terminal_title_stripped": "Rewriting the row template layer",
                  "cwd": "\(home)/work/shepherd",
                  "foreground_cwd": "\(home)/work/shepherd/Sources",
                  "focused": true,
                  "revision": 4821,
                  "state_labels": { "working": "Working", "idle": "Idle" },
                  "agent_session": {
                    "source": "herdr:codex",
                    "agent": "codex",
                    "kind": "id",
                    "value": "01JD8QK2S7"
                  },
                  "tokens": { "agent_kind": "primary", "model": "gpt-5.4" }
                },
                {
                  "pane_id": "w2:p1",
                  "workspace_id": "w2",
                  "tab_id": "w2:t1",
                  "terminal_id": "term-3c07",
                  "agent": "claude",
                  "display_agent": "Claude Code",
                  "agent_status": "idle",
                  "title": "claude",
                  "terminal_title_stripped": "",
                  "cwd": "\(home)/Documents/notes",
                  "foreground_cwd": "\(home)/Documents/notes",
                  "focused": false,
                  "revision": 118,
                  "state_labels": { "working": "Working", "idle": "Idle" },
                  "tokens": { "agent_kind": "primary" }
                }
              ],
              "workspaces": [
                {
                  "workspace_id": "w1",
                  "label": "shepherd",
                  "number": 1,
                  "pane_count": 2,
                  "branch": "feature/row-templates",
                  "worktree": {
                    "repo_key": "\(home)/work/shepherd/.git",
                    "repo_name": "shepherd",
                    "repo_root": "\(home)/work/shepherd",
                    "checkout_path": "\(home)/work/shepherd",
                    "is_linked_worktree": false
                  },
                  "tokens": { "project": "shepherd" }
                },
                {
                  "workspace_id": "w2",
                  "label": "notes",
                  "number": 2,
                  "pane_count": 1,
                  "tokens": {}
                }
              ],
              "tabs": [
                { "tab_id": "w1:t1", "label": "shepherd", "number": 1 },
                { "tab_id": "w2:t1", "label": "notes", "number": 2 }
              ]
            }
          }
        }
        """.utf8
    )
}
