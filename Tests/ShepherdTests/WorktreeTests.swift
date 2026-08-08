import Foundation
import XCTest
@testable import Shepherd

final class WorktreeTests: XCTestCase {
    private let repoKey = "/repo/shepherd/.git"

    // MARK: - Grouping

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
        // Workspace number outranks pane ID, so p2 leads even though it sorts
        // after p1.
        XCTAssertEqual(groups.first?.panes.map(\.paneId), ["w1:p2", "w2:p1"])
    }

    @MainActor
    func testOpaquePaneIDをTab番号とPaneIDで安定して並べる() {
        let raw = HerdrRawSnapshot(
            agents: [
                "w1:pT": .object([
                    "pane_id": .string("w1:pT"),
                    "tab_id": .string("w1:tD"),
                ]),
                "w1:pR": .object([
                    "pane_id": .string("w1:pR"),
                    "tab_id": .string("w1:tD"),
                ]),
                "w1:pV": .object([
                    "pane_id": .string("w1:pV"),
                    "tab_id": .string("w1:tA"),
                ]),
            ],
            workspaces: [
                "w1": .object(["workspace_id": .string("w1")]),
            ],
            tabs: [
                "w1:tA": .object([
                    "tab_id": .string("w1:tA"),
                    "number": .int(10),
                ]),
                "w1:tD": .object([
                    "tab_id": .string("w1:tD"),
                    "number": .int(13),
                ]),
            ]
        )
        let store = Store(initialState: .ready(AgentSnapshot(
            agents: [
                makePane(id: "w1:pT", workspaceId: "w1"),
                makePane(id: "w1:pR", workspaceId: "w1"),
                makePane(id: "w1:pV", workspaceId: "w1"),
            ],
            workspaces: [
                Workspace(workspaceId: "w1", label: "signage", number: 1),
            ],
            raw: raw
        )))

        XCTAssertEqual(
            store.workspaceGroups.first?.panes.map(\.paneId),
            ["w1:pV", "w1:pR", "w1:pT"]
        )
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

    // MARK: - Branch name propagation

    func testBranchをWorkspaceRecordへ書き込む() {
        let snapshot = AgentSnapshot(
            agents: [
                makePane(id: "w1:p1", workspaceId: "w1"),
                makePane(id: "w2:p1", workspaceId: "w2"),
                makePane(id: "w3:p1", workspaceId: "w3"),
            ],
            workspaces: [
                rootWorkspace(id: "w1", label: "shepherd", number: 1),
                linkedWorkspace(id: "w2", label: "feature-x", number: 2),
                Workspace(workspaceId: "w3", label: "notes", number: 3),
            ],
            branches: ["w1": "main", "w2": "feature/x"],
            raw: rawSnapshot(
                paneIDs: ["w1:p1", "w2:p1", "w3:p1"],
                workspaceIDs: ["w1", "w2", "w3"]
            )
        )

        XCTAssertEqual(snapshot.raw.workspaces["w1"]?["branch"]?.templateText, "main")
        XCTAssertEqual(snapshot.raw.workspaces["w2"]?["branch"]?.templateText, "feature/x")
        // An absent key, not an empty string: `[ {herdr.workspace.branch}]`
        // keeps its separator for any value that resolves.
        XCTAssertNil(snapshot.raw.workspaces["w3"]?["branch"])
    }

    @MainActor
    func testRepoごとに一度のWorktreeListで全Workspaceが解決する() async {
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

        // w1's response also carries w2's branch. w2 never being queried is
        // the only visible proof that the branch was taken from it.
        XCTAssertEqual(recorder.workspaceIDs, ["w1"])
    }

    @MainActor
    func testWorktreeMetadataの無いGitWorkspaceにも問い合わせる() async {
        // session.snapshot may omit worktree metadata even for a git repo, so
        // its presence cannot filter the query.
        let recorder = CallRecorder()
        let serverSnapshot = makeSnapshot(
            agents: [makePane(id: "w4:p1", workspaceId: "w4")],
            workspaces: [Workspace(workspaceId: "w4", label: "signage", number: 4)]
        )
        let store = Store(
            dataSource: StoreDataSource(
                snapshot: { serverSnapshot },
                worktrees: { workspaceID in
                    recorder.record(workspaceID)
                    return WorktreeListResult(worktrees: [
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

        XCTAssertEqual(recorder.workspaceIDs, ["w4"])
    }

    @MainActor
    func testWorktreeListの失敗ではReadyのままPaneを出し続ける() async {
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

        XCTAssertNotNil(store.panes["w2:p1"])
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
    ) -> SnapshotFetch {
        SnapshotFetch(
            session: HerdrSessionSnapshot(
                version: "test",
                protocolVersion: Herdr.supportedProtocol,
                agents: agents,
                workspaces: workspaces
            )
        )
    }

    // Identity keys only: the branch write is the subject under test, so no
    // record may start out with one.
    private func rawSnapshot(
        paneIDs: [String],
        workspaceIDs: [String]
    ) -> HerdrRawSnapshot {
        HerdrRawSnapshot(
            agents: Dictionary(uniqueKeysWithValues: paneIDs.map { paneID in
                (paneID, JSONValue.object(["pane_id": .string(paneID)]))
            }),
            workspaces: Dictionary(uniqueKeysWithValues: workspaceIDs.map { workspaceID in
                (workspaceID, JSONValue.object(["workspace_id": .string(workspaceID)]))
            }),
            tabs: [:]
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

// worktree.list closures are @Sendable and may run off the main actor, hence
// the lock.
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
