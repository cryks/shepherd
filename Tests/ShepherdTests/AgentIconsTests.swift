import XCTest
@testable import Shepherd

final class AgentIconsTests: XCTestCase {
    // Must match the PDFs in Resources/AgentMarks.
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
