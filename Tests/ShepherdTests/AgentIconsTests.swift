// AgentMarks アセットの解決契約を検証する。同梱済みの agent は mono / color の
// 両スタイルが読めること、アセットの無い agent 名は nil に落ちること
// (AgentRow がテキスト表示にフォールバックする分岐) を見る。

import XCTest
@testable import Shepherd

final class AgentIconsTests: XCTestCase {
    /// マーク PDF を同梱している agent ラベル。Resources/AgentMarks の内容と一致させる。
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
