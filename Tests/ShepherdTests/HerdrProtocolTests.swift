// Pins Shepherd's protocol boundary to the subset of Herdr JSON it consumes.
// Protocol 17 adds agent lifecycle fields while preserving the snapshot,
// workspace, and pane fields below; unknown fields remain outside Shepherd's
// model instead of being copied into display state.

import Foundation
import XCTest
@testable import Shepherd

final class HerdrProtocolTests: XCTestCase {
    func testDecodesProtocol17SessionSnapshotSubset() throws {
        let json = Data(
            #"""
            {
              "type": "session_snapshot",
              "snapshot": {
                "version": "0.7.5",
                "protocol": 17,
                "focused_workspace_id": "w1",
                "focused_tab_id": "w1:t1",
                "focused_pane_id": "w1:p1",
                "workspaces": [
                  {
                    "workspace_id": "w1",
                    "label": "Shepherd",
                    "number": 1,
                    "focused": true,
                    "pane_count": 1,
                    "tab_count": 1,
                    "active_tab_id": "w1:t1",
                    "agent_status": "blocked"
                  }
                ],
                "tabs": [],
                "panes": [],
                "layouts": [],
                "agents": [
                  {
                    "agent": "codex",
                    "agent_status": "blocked",
                    "pane_id": "w1:p1",
                    "workspace_id": "w1",
                    "tab_id": "w1:t1",
                    "terminal_id": "terminal-1",
                    "focused": true,
                    "revision": 7,
                    "terminal_title_stripped": "Implement protocol 17",
                    "launch_pending": false,
                    "interactive_ready": true,
                    "state_change_seq": 42
                  }
                ]
              }
            }
            """#.utf8
        )

        let result = try makeDecoder().decode(SessionSnapshotResult.self, from: json)

        XCTAssertEqual(Herdr.supportedProtocol, 17)
        XCTAssertEqual(result.snapshot.protocolVersion, Herdr.supportedProtocol)
        XCTAssertEqual(result.snapshot.workspaces.first?.workspaceId, "w1")
        XCTAssertEqual(result.snapshot.agents.first?.paneId, "w1:p1")
        XCTAssertEqual(result.snapshot.agents.first?.terminalId, "terminal-1")
        XCTAssertEqual(result.snapshot.agents.first?.agentStatus, .blocked)
    }
}
