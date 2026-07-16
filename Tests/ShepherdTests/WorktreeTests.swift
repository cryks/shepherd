// linked worktree の pane を root checkout のグループへ合流させる表示規則と、
// worktree.list から引いた branch 名の Pane への反映を検証する。
// RPC は closure 差し替えで即時応答させ、実 socket や poll 周期には依存しない。

import Foundation
import XCTest
@testable import Shepherd

final class WorktreeTests: XCTestCase {
    private let repoKey = "/repo/shepherd/.git"

    // MARK: - グルーピング

    @MainActor
    func testLinkedWorktreeのPaneをRootのグループへ合流させる() {
        let store = Store(initialState: .ready(AgentSnapshot(
            agents: [
                makePane(id: "w1:p2", workspaceId: "w1"),
                makePane(id: "w2:p1", workspaceId: "w2"),
            ],
            workspaces: [
                rootWorkspace(id: "w1", label: "shepherd", number: 1),
                linkedWorkspace(id: "w2", label: "feature-x", number: 2),
            ]
        )))

        let groups = store.workspaceGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.workspace.workspaceId, "w1")
        XCTAssertEqual(groups.first?.workspace.label, "shepherd")
        // pane 番号 (p2 > p1) より workspace 番号を優先し、root の pane を先に出す。
        XCTAssertEqual(groups.first?.panes.map(\.paneId), ["w1:p2", "w2:p1"])
    }

    @MainActor
    func testRootが開かれていないLinkedWorktreeは自分の見出しで出す() {
        let store = Store(initialState: .ready(AgentSnapshot(
            agents: [makePane(id: "w2:p1", workspaceId: "w2")],
            workspaces: [linkedWorkspace(id: "w2", label: "feature-x", number: 2)]
        )))

        let groups = store.workspaceGroups
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.workspace.workspaceId, "w2")
        XCTAssertEqual(groups.first?.workspace.label, "feature-x")
    }

    @MainActor
    func test別RepoのWorkspaceは合流させない() {
        let store = Store(initialState: .ready(AgentSnapshot(
            agents: [
                makePane(id: "w1:p1", workspaceId: "w1"),
                makePane(id: "w3:p1", workspaceId: "w3"),
            ],
            workspaces: [
                rootWorkspace(id: "w1", label: "shepherd", number: 1),
                Workspace(
                    workspaceId: "w3",
                    label: "other",
                    number: 3,
                    worktree: WorkspaceWorktree(
                        repoKey: "/repo/other/.git",
                        isLinkedWorktree: true
                    )
                ),
            ]
        )))

        XCTAssertEqual(
            store.workspaceGroups.map(\.workspace.workspaceId),
            ["w1", "w3"]
        )
    }

    // MARK: - branch 名の反映

    @MainActor
    func testWorktreeListのBranchをRootとWorktreeの両Paneへ書き込む() async {
        let recorder = CallRecorder()
        let serverSnapshot = makeSnapshot(
            agents: [
                makePane(id: "w1:p1", workspaceId: "w1"),
                makePane(id: "w2:p1", workspaceId: "w2"),
            ],
            workspaces: [
                rootWorkspace(id: "w1", label: "shepherd", number: 1),
                linkedWorkspace(id: "w2", label: "feature-x", number: 2),
            ]
        )
        let store = Store(
            dataSource: StoreDataSource(
                snapshot: { serverSnapshot },
                worktrees: { workspaceID in
                    recorder.record(workspaceID)
                    return WorktreeListResult(worktrees: [
                        WorktreeEntry(branch: "main", openWorkspaceId: "w1"),
                        WorktreeEntry(branch: "feature/x", openWorkspaceId: "w2"),
                    ])
                }
            ),
            pollInterval: .seconds(60)
        )
        defer { store.stop() }

        store.start()
        let ready = await becameReady(store)
        XCTAssertTrue(ready)

        XCTAssertEqual(store.panes["w1:p1"]?.branch, "main")
        XCTAssertEqual(store.panes["w2:p1"]?.branch, "feature/x")
        // w1 への応答が同じ repo の w2 も解決するため、問い合わせは 1 回で済む。
        XCTAssertEqual(recorder.workspaceIDs, ["w1"])
    }

    @MainActor
    func testWorktreeMetadataの無いGitWorkspaceにもBranchを書き込む() async {
        // session.snapshot は git repo の workspace でも worktree metadata を
        // 付けないことがある (protocol 16 で実測)。metadata の有無で問い合わせを
        // 絞らないことを確かめる。
        let serverSnapshot = makeSnapshot(
            agents: [makePane(id: "w4:p1", workspaceId: "w4")],
            workspaces: [Workspace(workspaceId: "w4", label: "signage", number: 4)]
        )
        let store = Store(
            dataSource: StoreDataSource(
                snapshot: { serverSnapshot },
                worktrees: { _ in
                    WorktreeListResult(worktrees: [
                        WorktreeEntry(branch: "main", openWorkspaceId: "w4"),
                    ])
                }
            ),
            pollInterval: .seconds(60)
        )
        defer { store.stop() }

        store.start()
        let ready = await becameReady(store)
        XCTAssertTrue(ready)

        XCTAssertEqual(store.panes["w4:p1"]?.branch, "main")
    }

    @MainActor
    func testWorktreeListの失敗ではReadyのままBranchなしで表示する() async {
        let serverSnapshot = makeSnapshot(
            agents: [makePane(id: "w2:p1", workspaceId: "w2")],
            workspaces: [linkedWorkspace(id: "w2", label: "feature-x", number: 2)]
        )
        let store = Store(
            dataSource: StoreDataSource(
                snapshot: { serverSnapshot },
                worktrees: { _ in throw StubError.worktreeList }
            ),
            pollInterval: .seconds(60)
        )
        defer { store.stop() }

        store.start()
        let ready = await becameReady(store)
        XCTAssertTrue(ready)

        XCTAssertNil(store.panes["w2:p1"]?.branch)
        // マーク無し agent 用のフォールバック文字列も cwd では埋めず、agent 名だけになる。
        XCTAssertEqual(store.panes["w2:p1"]?.displaySubtitle, "claude")
    }

    @MainActor
    func testエージェントの居ないWorkspaceへは問い合わせない() async {
        let recorder = CallRecorder()
        let serverSnapshot = makeSnapshot(
            agents: [makePane(id: "w1:p1", workspaceId: "w1")],
            workspaces: [
                rootWorkspace(id: "w1", label: "shepherd", number: 1),
                Workspace(
                    workspaceId: "w3",
                    label: "other",
                    number: 3,
                    worktree: WorkspaceWorktree(
                        repoKey: "/repo/other/.git",
                        isLinkedWorktree: false
                    )
                ),
            ]
        )
        let store = Store(
            dataSource: StoreDataSource(
                snapshot: { serverSnapshot },
                worktrees: { workspaceID in
                    recorder.record(workspaceID)
                    return WorktreeListResult(worktrees: [
                        WorktreeEntry(branch: "main", openWorkspaceId: workspaceID),
                    ])
                }
            ),
            pollInterval: .seconds(60)
        )
        defer { store.stop() }

        store.start()
        let ready = await becameReady(store)
        XCTAssertTrue(ready)

        XCTAssertEqual(recorder.workspaceIDs, ["w1"])
    }

    // MARK: - Helpers

    private func makeSnapshot(
        agents: [Pane],
        workspaces: [Workspace]
    ) -> HerdrSessionSnapshot {
        HerdrSessionSnapshot(
            version: "test",
            protocolVersion: Herdr.supportedProtocol,
            agents: agents,
            workspaces: workspaces
        )
    }

    private func makePane(id: String, workspaceId: String) -> Pane {
        Pane(
            agent: "claude",
            agentStatus: .working,
            paneId: id,
            workspaceId: workspaceId,
            terminalId: "terminal-\(id)",
            terminalTitleStripped: "Task",
            tokens: PaneTokens(agentKind: "primary")
        )
    }

    private func rootWorkspace(id: String, label: String, number: Int) -> Workspace {
        Workspace(
            workspaceId: id,
            label: label,
            number: number,
            worktree: WorkspaceWorktree(repoKey: repoKey, isLinkedWorktree: false)
        )
    }

    private func linkedWorkspace(id: String, label: String, number: Int) -> Workspace {
        Workspace(
            workspaceId: id,
            label: label,
            number: number,
            worktree: WorkspaceWorktree(repoKey: repoKey, isLinkedWorktree: true)
        )
    }

    @MainActor
    private func becameReady(_ store: Store) async -> Bool {
        for _ in 0..<200 {
            if case .ready = store.state { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if case .ready = store.state { return true }
        return false
    }
}

private enum StubError: Error {
    case worktreeList
}

/// worktree.list の呼び出し対象 workspace を @Sendable closure から記録する。
private final class CallRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    var workspaceIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record(_ workspaceID: String) {
        lock.lock()
        recorded.append(workspaceID)
        lock.unlock()
    }
}
