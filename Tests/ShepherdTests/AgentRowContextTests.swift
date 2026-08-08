import XCTest
@testable import Shepherd

final class AgentRowContextTests: XCTestCase {
    // MARK: - {title}

    // While Codex waits for input it retitles its terminal to
    // "[ ! ] Action Required | <task>" and blinks the glyph between "!" and ".".
    @MainActor
    func testBothBlinkFramesOfTheCodexPrefixAreStripped() {
        XCTAssertEqual(
            renderedTitle("[ ! ] Action Required | Question選択表示の試験"),
            "Question選択表示の試験"
        )
        XCTAssertEqual(
            renderedTitle("[ . ] Action Required | Question選択表示の試験"),
            "Question選択表示の試験"
        )
    }

    @MainActor
    func testTitlesWithoutTheLeadingPrefixPassThrough() {
        XCTAssertEqual(
            renderedTitle("Refactor tunnel retry backoff"),
            "Refactor tunnel retry backoff"
        )
        XCTAssertEqual(
            renderedTitle("Fix [ ! ] Action Required | parser"),
            "Fix [ ! ] Action Required | parser"
        )
    }

    // The agent-name fallback lives in the template
    // (`{title|herdr.agent.agent}`), not in the variable.
    @MainActor
    func testTitlesThatEndUpEmptyRenderEmpty() {
        XCTAssertEqual(renderedTitle("[ ! ] Action Required | "), "")
        XCTAssertEqual(renderedTitle(""), "")
        XCTAssertEqual(renderedTitle(nil), "")
    }

    // MARK: - herdr.*

    @MainActor
    func testHerdrNamesResolveUnderTheKeysHerdrSent() {
        let context = snakeCaseRecords

        XCTAssertEqual(render("{herdr.agent.state_labels.blocked}", context), "Waiting for you")
        XCTAssertEqual(render("{herdr.agent.tokens.jj_status}", context), "conflict")
        XCTAssertEqual(render("{herdr.workspace.worktree.repo_name}", context), "shepherd")
    }

    // The typed models decode with .convertFromSnakeCase, so a camelCased path
    // is what a regression writes, and an unresolved name renders as nothing.
    @MainActor
    func testCamelCasedPathsResolveToNothing() {
        let context = snakeCaseRecords

        XCTAssertEqual(render("{herdr.agent.stateLabels.blocked}", context), "")
        XCTAssertEqual(render("{herdr.agent.tokens.jjStatus}", context), "")
        XCTAssertEqual(render("{herdr.workspace.worktree.repoName}", context), "")
        // The unresolved name takes its whole group with it, so not even a
        // stray separator hints at the mistake.
        XCTAssertEqual(render("[ · {herdr.agent.stateLabels.blocked}]", context), "")
    }

    // MARK: - Helpers

    private var snakeCaseRecords: AgentRowContext {
        AgentRowContext(
            pane: pane(title: "Task"),
            rawAgent: .object([
                "state_labels": .object(["blocked": .string("Waiting for you")]),
                "tokens": .object(["jj_status": .string("conflict")]),
            ]),
            rawWorkspace: .object([
                "worktree": .object(["repo_name": .string("shepherd")])
            ])
        )
    }

    @MainActor
    private func renderedTitle(_ title: String?) -> String {
        render("{title}", AgentRowContext(pane: pane(title: title)))
    }

    @MainActor
    private func render(_ source: String, _ context: AgentRowContext) -> String {
        RowTemplate(source).renderText { context.templateValue(for: $0) }
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
