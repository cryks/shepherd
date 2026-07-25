// Pins two things about the layout value: a per-agent entry replaces the base
// lines instead of merging with them, and the built-in layout renders one exact
// row and notification text. The separators and fallbacks of the built-in
// templates are spelled out only here, so this is the single file to change
// when that text is meant to change.
//
// The built-in text is rendered against a real AgentRowContext rather than a
// table of answers, which makes the second test a guard over the whole chain:
// the template sources, the names they use, and the herdr keys those names
// reach.
//
// Not exercised here: the style presets, which the view layer maps to fonts,
// and the rule that drops a line whose two sides both render empty.

import XCTest
@testable import Shepherd

final class RowLayoutTests: XCTestCase {
    func testPerAgentLinesReplaceTheBaseLines() {
        let layout = RowLayout(
            lines: [line("{one}"), line("{two}"), line("{three}")],
            linesByAgent: ["codex": [line("{only}")]],
            notification: RowLayout.default.notification
        )

        XCTAssertEqual(layout.lines(forAgent: "codex").map(\.left.source), ["{only}"])
        XCTAssertEqual(layout.lines(forAgent: "claude").count, 3)
        XCTAssertEqual(layout.lines(forAgent: nil).count, 3)
    }

    @MainActor
    func testBuiltInLayoutRendersTheDefaultRowAndNotificationText() {
        let context = doneClaudePaneOnARemoteHost
        func row(_ template: RowTemplate) -> String {
            template.renderText { context.templateValue(for: $0) }
        }
        func notification(_ template: RowTemplate) -> String {
            template.renderText { context.textTemplateValue(for: $0) }
        }

        let lines = RowLayout.default.lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(row(lines[0].left), "Add payment flow integration tests")
        XCTAssertEqual(row(lines[0].right), "done")
        // The sub-line is the brand mark, then a space, then the branch.
        XCTAssertEqual(
            lines[1].left.render { context.templateValue(for: $0) },
            [.icon(agent: "claude"), .text(" feature/checkout")]
        )
        XCTAssertEqual(row(lines[1].right), "")
        XCTAssertEqual(row(lines[2].left), "All 42 payment flow tests pass")
        XCTAssertEqual(row(lines[2].right), "")

        let templates = RowLayout.default.notification
        XCTAssertEqual(
            notification(templates.title),
            "🟢 Add payment flow integration tests"
        )
        XCTAssertEqual(notification(templates.subtitle), "devbox · webapp")
        XCTAssertEqual(notification(templates.body), "claude · feature/checkout")
    }

    // MARK: - Helpers

    /// Everything the built-in templates can name is present: a title, a brand
    /// mark, a branch, a workspace label, an excerpt, and a remote source label.
    private var doneClaudePaneOnARemoteHost: AgentRowContext {
        AgentRowContext(
            pane: Pane(
                agent: "claude",
                agentStatus: .done,
                paneId: "w1:p1",
                workspaceId: "ws-webapp",
                terminalId: "terminal-1",
                terminalTitleStripped: "Add payment flow integration tests",
                tokens: PaneTokens(agentKind: "primary")
            ),
            rawAgent: .object([
                "agent": .string("claude"),
                "agent_status": .string("done"),
                "pane_id": .string("w1:p1"),
                "workspace_id": .string("ws-webapp"),
                "tab_id": .string("w1:t1"),
            ]),
            rawWorkspace: .object([
                "workspace_id": .string("ws-webapp"),
                "label": .string("webapp"),
                "branch": .string("feature/checkout"),
            ]),
            rawTab: .object(["tab_id": .string("w1:t1"), "label": .string("agent")]),
            excerpt: "All 42 payment flow tests pass",
            sourceLabel: "devbox"
        )
    }

    private func line(_ left: String) -> RowLine {
        RowLine(
            left: RowTemplate(left),
            leftStyle: .body,
            right: RowTemplate(""),
            rightStyle: .body
        )
    }
}
