// Fixed synthetic agents the Display settings preview renders while "Sample" is
// selected, so a user can tune templates with no herdr running and can see how
// `[...]` groups behave: the codex pane has a branch and an excerpt, the claude
// pane has neither and an empty terminal title.
//
// The sample is one whole `session.snapshot` response line, decoded the same two
// ways the live path decodes it — makeDecoder() for the typed Pane values,
// HerdrRawSnapshot.decode(responseLine:) for the verbatim records the templates
// address. That keeps the sample honest about key names and value types instead
// of hand-building both sides.
//
// The `branch` member of each workspace record is written into the literal here.
// On the live path AgentSnapshot injects it from worktree.list; a synthetic
// snapshot has no worktree.list to read, and `{herdr.workspace.branch}` must
// still resolve.

import Foundation

@MainActor
enum RowLayoutPreviewSample {
    /// One sample row: the context its templates resolve against plus the
    /// excerpt state that drives the reserved excerpt line. A nil state is how
    /// the sample shows a pane with no excerpt support.
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
                // The live value is suppressed while no remote is visible; the
                // sample always names a source so the separator in
                // `[{source} · ]` is visible.
                sourceLabel: LocalSectionTitleSetting.defaultTitle
            ),
            excerptState: excerpt.map(AgentExcerptState.available)
        )
    }

    /// Verbatim records addressed by `{herdr.agent.*}`, `{herdr.workspace.*}`,
    /// and `{herdr.tab.*}` while the sample is shown.
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

    /// Home directory of the person looking at the preview, so `{cwd_short}`
    /// visibly collapses to `~` instead of showing a path that cannot match.
    private static let home = NSHomeDirectory()

    private static let responseLine = Data(
        """
        {
          "id": "shepherd:session.snapshot",
          "result": {
            "type": "session.snapshot",
            "snapshot": {
              "version": "0.7.5",
              "protocol": 17,
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
