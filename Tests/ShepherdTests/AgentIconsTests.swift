import XCTest
@testable import Shepherd

final class AgentIconsTests: XCTestCase {
    // Must match the PDFs in Resources/AgentMarks.
    private let bundledAgents = ["claude", "codex", "pi", "opencode", "omp", "grok"]

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

    func testMonoStyleUsesTemplateInEitherAppearance() {
        XCTAssertTrue(AgentIconStyle.mono.usesTemplate(agent: "claude", appearanceIsDark: false))
        XCTAssertTrue(AgentIconStyle.mono.usesTemplate(agent: "grok", appearanceIsDark: true))
    }

    func testColorStyleUsesTemplateOnlyForGrokInDarkAppearance() {
        XCTAssertTrue(AgentIconStyle.color.usesTemplate(agent: "grok", appearanceIsDark: true))
        XCTAssertFalse(AgentIconStyle.color.usesTemplate(agent: "grok", appearanceIsDark: false))
        XCTAssertFalse(AgentIconStyle.color.usesTemplate(agent: "claude", appearanceIsDark: true))
        XCTAssertFalse(AgentIconStyle.color.usesTemplate(agent: "codex", appearanceIsDark: true))
    }
}
