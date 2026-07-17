// Verifies the resolution contract for AgentMarks assets: bundled agents load in
// both the mono and color styles, and an agent name without an asset resolves to
// nil (the branch where AgentRow falls back to a text label).

import XCTest
@testable import Shepherd

final class AgentIconsTests: XCTestCase {
    /// Agent labels that ship a bundled mark PDF. Keep in sync with the contents of Resources/AgentMarks.
    private let bundledAgents = ["claude", "codex", "pi", "opencode", "omp"]

    @MainActor
    func testBundledMarksResolveInBothStyles() {
        for agent in bundledAgents {
            XCTAssertNotNil(AgentIcons.icon(for: agent, style: .mono), "\(agent)-mono")
            XCTAssertNotNil(AgentIcons.icon(for: agent, style: .color), "\(agent)-color")
        }
    }

    @MainActor
    func testUnknownAgentResolvesToNil() {
        XCTAssertNil(AgentIcons.icon(for: "no-such-agent"))
    }
}
