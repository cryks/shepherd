// Verifies Pane.displayTitle: the Codex "Action Required" title prefix is
// dropped for display, other titles pass through unchanged, and an empty
// result falls back to the agent name. Both observed blink frames of the
// bracketed glyph ("!" and ".") are covered.

import XCTest
@testable import Shepherd

final class PaneDisplayTitleTests: XCTestCase {
    func testCodexのActionRequired接頭辞を落としてタスク名だけ表示する() {
        XCTAssertEqual(
            pane(title: "[ ! ] Action Required | Question選択表示の試験").displayTitle,
            "Question選択表示の試験"
        )
        XCTAssertEqual(
            pane(title: "[ . ] Action Required | Question選択表示の試験").displayTitle,
            "Question選択表示の試験"
        )
    }

    func test接頭辞のないタイトルはそのまま表示する() {
        XCTAssertEqual(pane(title: "Refactor tunnel retry backoff").displayTitle,
                       "Refactor tunnel retry backoff")
    }

    func test先頭以外のActionRequiredは削らない() {
        XCTAssertEqual(
            pane(title: "Fix [ ! ] Action Required | parser").displayTitle,
            "Fix [ ! ] Action Required | parser"
        )
    }

    func test接頭辞を削って空になったらエージェント名へ落とす() {
        XCTAssertEqual(pane(title: "[ ! ] Action Required | ").displayTitle, "codex")
    }

    func testタイトルが空ならエージェント名へ落とす() {
        XCTAssertEqual(pane(title: "").displayTitle, "codex")
        XCTAssertEqual(pane(title: nil).displayTitle, "codex")
    }

    private func pane(title: String?) -> Pane {
        Pane(
            agent: "codex",
            agentStatus: .blocked,
            paneId: "w1:p1",
            workspaceId: "w1",
            terminalId: "terminal-1",
            terminalTitleStripped: title,
            tokens: PaneTokens(agentKind: "primary")
        )
    }
}
