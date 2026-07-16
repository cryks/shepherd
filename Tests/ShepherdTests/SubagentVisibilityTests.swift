// herdr の tokens metadata のデコードと、AgentSnapshot が親エージェントだけを保持する
// 契約を検証する。イベントストリームや RPC は起動せず、list サイクルごとの
// metadata の有無による対象判定を扱う。

import XCTest
@testable import Shepherd

final class SubagentVisibilityTests: XCTestCase {
    func testDecodesSubagentKindFromTokens() throws {
        let json = Data(
            #"{"agent":"codex","agent_status":"working","pane_id":"w1:p2","workspace_id":"w1","tokens":{"agent_kind":"subagent","display_agent":"Codex subagent"}}"#.utf8
        )

        let pane = try makeDecoder().decode(Pane.self, from: json)

        XCTAssertEqual(pane.tokens?.agentKind, "subagent")
    }

    @MainActor
    func testTracksOnlyAgentsThatAreNotSubagents() {
        XCTAssertTrue(Store.shouldTrack(makePane(tokens: nil)))
        XCTAssertTrue(Store.shouldTrack(makePane(tokens: PaneTokens(agentKind: nil))))
        XCTAssertTrue(Store.shouldTrack(makePane(tokens: PaneTokens(agentKind: "primary"))))
        XCTAssertFalse(Store.shouldTrack(makePane(tokens: PaneTokens(agentKind: "subagent"))))
        XCTAssertFalse(Store.shouldTrack(makePane(agent: nil, tokens: nil)))
    }

    func testLaterSnapshotDropsPaneClassifiedAsSubagent() {
        let created = makePane(tokens: nil)
        let initial = AgentSnapshot(agents: [created], workspaces: [])
        XCTAssertEqual(initial.panes[created.paneId], created)

        var updated = created
        updated.tokens = PaneTokens(agentKind: "subagent")
        let refreshed = AgentSnapshot(agents: [updated], workspaces: [])

        XCTAssertNil(refreshed.panes[created.paneId])
    }

    private func makePane(
        agent: String? = "codex",
        tokens: PaneTokens?
    ) -> Pane {
        Pane(
            agent: agent,
            agentStatus: .working,
            paneId: "w1:p2",
            workspaceId: "w1",
            terminalId: "terminal-2",
            terminalTitleStripped: "Working",
            tokens: tokens
        )
    }
}
