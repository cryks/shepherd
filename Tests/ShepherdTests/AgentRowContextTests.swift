// Pins the two halves of the variable namespace that a wrong answer would hide
// rather than break.
//
// `{title}` is herdr's terminal_title_stripped with Codex's "Action Required"
// prefix removed. While Codex waits for input it retitles its terminal to
// "[ ! ] Action Required | <task>" and blinks the bracketed glyph between "!"
// and ".", so both frames have to strip; a title that merely quotes the phrase
// does not; and a title that is empty once the prefix is gone stays empty,
// because the agent-name fallback belongs to the template
// (`{title|herdr.agent.agent}`), not to the variable.
//
// `herdr.*` names address the raw records under the keys herdr sent. The typed
// models decode with .convertFromSnakeCase, so a camelCased path is exactly
// what a regression would produce — and it would produce it silently, since an
// unresolved name renders as nothing.
//
// Not exercised here: `{cwd_short}` / `{cwd_name}` / `{source}`, and the
// grammar that turns a resolved value into text (RowTemplateGrammarTests).

import XCTest
@testable import Shepherd

final class AgentRowContextTests: XCTestCase {
    // MARK: - {title}

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

    @MainActor
    func testCamelCasedPathsResolveToNothing() {
        let context = snakeCaseRecords

        XCTAssertEqual(render("{herdr.agent.stateLabels.blocked}", context), "")
        XCTAssertEqual(render("{herdr.agent.tokens.jjStatus}", context), "")
        XCTAssertEqual(render("{herdr.workspace.worktree.repoName}", context), "")
        // The name resolving to nothing also takes its group with it, so a
        // camelCased path leaves no separator behind to notice it by.
        XCTAssertEqual(render("[ · {herdr.agent.stateLabels.blocked}]", context), "")
    }

    // MARK: - Helpers

    /// Records holding nested keys of both shapes herdr uses: a hook-defined
    /// token and a state label, plus a workspace's worktree metadata.
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
