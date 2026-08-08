import XCTest
@testable import Shepherd

@MainActor
final class RowLayoutPreviewSampleTests: XCTestCase {
    func testEverySampleRowRendersSomethingUnderTheBuiltInLayout() {
        let entries = RowLayoutPreviewSample.entries
        XCTAssertFalse(entries.isEmpty, "the preview would show nothing")

        for entry in entries {
            let lines = RowLayout.default.lines(forAgent: entry.context.pane.agent)
            let runs = lines.flatMap { line in
                [line.left, line.right].flatMap { template in
                    template.render { entry.context.templateValue(for: $0) }
                }
            }
            XCTAssertFalse(runs.isEmpty, "sample pane \(entry.context.pane.paneId) drew nothing")
        }
    }

    func testSampleServesHerdrRecordsUnderTheirWireKeys() {
        guard let codex = RowLayoutPreviewSample.entries
            .first(where: { $0.context.pane.agent == "codex" }) else {
            return XCTFail("the sample has no codex pane")
        }
        // The sample is synthetic and has no worktree.list, so it must already carry
        // the branch under the key AgentSnapshot injects on the live path.
        XCTAssertEqual(
            codex.context.templateValue(for: "herdr.workspace.branch"),
            .text("feature/row-templates")
        )
        XCTAssertEqual(
            codex.context.templateValue(for: "herdr.agent.tokens.model"),
            .text("gpt-5.4")
        )
    }
}
