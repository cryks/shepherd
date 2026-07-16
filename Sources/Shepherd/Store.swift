// 1 つの herdr endpoint の観測状態。session.snapshot の protocol、agents、workspaces を
// 1 回の値として読み、MainActor 上の表示 snapshot へ載せ替える。
//
// 同期の契約:
//   - events.subscribe は使わない。Herdr のイベントは履歴を再送せず、pane.updated は
//     field 単位で絞れないため、監視対象外の更新を含む高頻度streamを接続ごとに持たない
//   - start() は直ちに 1 回取得し、以後は source ごとの pollInterval で取り直す。ローカルは
//     500ms、リモートは保存設定 (既定2秒) を FleetStore が渡す
//   - poll tick と取得が重なった場合は進行中の1本を待つ。完了直後の追加取得は行わず、
//     次のtickで最新状態へ追従するため、遅いendpointでRPCを積み上げない
//   - snapshot は agents と workspaces を同じserver captureから返す。protocol一致後の
//     最初の応答からreadyとして公開する
//   - ブランチ名だけは session.snapshot に含まれないため、監視対象 pane がいる
//     workspace ごとに worktree.list を同じ poll 内で追加取得する。1 回の応答は
//     同じ repo を開いている全 workspace の branch を返すため、先行の応答で解決済みの
//     workspace は引き直さない。この取得の失敗 (非 git の workspace を含む) は
//     表示装飾の欠落 (ブランチ名なし) に留め、poll 全体を disconnected にしない
//   - session.snapshot の失敗時は古い一覧を公開せずdisconnectedへ戻す。pollは止めず、
//     次の成功でreadyへ戻る
//   - stop() はpollと進行中taskをcancelする。同期I/Oがcancel後に返ってもstateへ反映しない
//   - suspendPolling() / resumePolling() はシステムスリープ用の再開可能な一時停止。
//     suspend はpollと進行中RPCをcancelし、その結果をstateへ反映しない。resume は
//     直ちに1回取得してからpollを再開する
//
// 既読管理は持たない。blocked/done は herdr 側の状態で、herdr で pane を閲覧すれば
// done が idle に戻り、このアプリの表示も次のpollで消える。

import Foundation
import Observation
import os

private let log = Logger(subsystem: "io.github.cryks.shepherd", category: "store")

/// UI が 1 回の書き換えで受け取る観測スナップショット。
/// panes と workspaces は同じ session.snapshot から作り、片方だけを後から更新しない。
struct AgentSnapshot: Equatable {
    var panes: [String: Pane]
    var workspaces: [String: Workspace]

    /// server snapshot の配列を UI 用の ID 辞書へ変換する。subagent と agent 未検出の
    /// pane はこの境界で除外し、以降の表示系には混ぜない。
    /// branches (workspace ID → branch 名) は pane の branch へこの境界で書き込み、
    /// 以降の表示系は Pane だけを見れば済むようにする。
    init(agents: [Pane], workspaces: [Workspace], branches: [String: String] = [:]) {
        panes = Dictionary(
            uniqueKeysWithValues: agents
                .filter(Store.shouldTrack)
                .map { pane in
                    var pane = pane
                    pane.branch = branches[pane.workspaceId]
                    return (pane.paneId, pane)
                }
        )
        self.workspaces = Dictionary(uniqueKeysWithValues: workspaces.map { ($0.workspaceId, $0) })
    }
}

/// 接続と表示データの公開状態。ready だけがメニューバーと監視ウィンドウの
/// データソースになり、RPC失敗後の古いsnapshotは表示へ残さない。
enum StoreState: Equatable {
    case disconnected
    case synchronizing
    case ready(AgentSnapshot)
    /// サーバは応答したが protocol が Herdr.supportedProtocol と違う。
    case protocolMismatch(Int)
}

/// Store が読み込むRPC境界。テストは応答の完了と失敗を制御し、初回取得、poll、
/// stopとの競合を実socketなしで再現する。
struct StoreDataSource: Sendable {
    var snapshot: @Sendable () async throws -> HerdrSessionSnapshot
    /// workspace が属する repo の worktree 一覧。pane のブランチ名表示だけに使い、
    /// 失敗しても poll の成否には関与しない。
    var worktrees: @Sendable (_ workspaceID: String) async throws -> WorktreeListResult

    /// remote endpointではSSH tunnelのローカル側socketを固定で閉じ込め、pollの一部が
    /// local herdrへ漏れないようにする。
    static func live(socketPath: String) -> StoreDataSource {
        StoreDataSource(
            snapshot: {
                try await Herdr.request(
                    "session.snapshot",
                    socketPath: socketPath,
                    as: SessionSnapshotResult.self
                ).snapshot
            },
            worktrees: { workspaceID in
                try await Herdr.request(
                    "worktree.list",
                    params: ["workspace_id": workspaceID],
                    socketPath: socketPath,
                    as: WorktreeListResult.self
                )
            }
        )
    }
}

@Observable @MainActor
final class Store {
    static let localPollInterval: Duration = .milliseconds(500)

    private(set) var state: StoreState
    /// FleetStore がリモート設定変更をSSH再接続なしで反映する。0以下はbusy loopに
    /// なるため受け付けず、RemotePollingIntervalのpresetだけをproductionから渡す。
    private(set) var pollInterval: Duration

    /// ready 以外で空辞書を返し、切断前のsnapshotを表示側が再利用する経路を作らない。
    var panes: [String: Pane] {
        guard case .ready(let snapshot) = state else { return [:] }
        return snapshot.panes
    }

    private var workspaces: [String: Workspace] {
        guard case .ready(let snapshot) = state else { return [:] }
        return snapshot.workspaces
    }

    private let dataSource: StoreDataSource
    private var pollingTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var hasStarted = false
    private var hasBeenStopped = false
    /// システムスリープ中の一時停止。hasBeenStoppedと違いresumePolling()で解除できる。
    /// remoteはtunnel ready待ちの間にsuspendされることがあるため、start()より先に立ちうる。
    private var isPollingSuspended = false

    init(
        dataSource: StoreDataSource = .live(socketPath: Herdr.defaultSocketPath),
        pollInterval: Duration = .milliseconds(500),
        initialState: StoreState = .disconnected
    ) {
        precondition(pollInterval > .zero)
        self.dataSource = dataSource
        self.pollInterval = pollInterval
        state = initialState
    }

    /// 指定socketだけを読むlive endpointを作る。local/remoteの周期は所有者が明示し、
    /// default引数でremoteを500msにしてしまう呼び出しを作らない。
    static func live(socketPath: String, pollInterval: Duration) -> Store {
        Store(
            dataSource: .live(socketPath: socketPath),
            pollInterval: pollInterval
        )
    }

    // MARK: - 派生ビュー

    /// 監視ウィンドウ用の workspace ごとのグループ。workspace 番号順。
    /// linked worktree の workspace は独立した見出しにせず、同じ repo の root checkout を
    /// 開いている workspace のグループへ pane を合流させる (見出しは root 側の label)。
    /// グループ内は workspace 番号 → pane 番号の順で、root の pane が worktree の pane より
    /// 先に並ぶ。root checkout が workspace として開かれていない linked worktree と、
    /// snapshot に見出しがない workspace は自分の見出しで出す。
    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        var groups: [String: (workspace: Workspace, panes: [Pane])] = [:]
        for pane in panes.values {
            let workspace = groupWorkspace(for: pane.workspaceId)
            groups[workspace.workspaceId, default: (workspace, [])].panes.append(pane)
        }
        return groups.values
            .map { group in
                (
                    workspace: group.workspace,
                    panes: group.panes.sorted { paneSortKey($0) < paneSortKey($1) }
                )
            }
            .sorted { $0.workspace.number < $1.workspace.number }
    }

    /// pane が表示上属するグループの workspace。linked worktree の pane は
    /// 同じ repoKey の root checkout を開いている workspace へ寄せる。
    private func groupWorkspace(for workspaceId: String) -> Workspace {
        guard let workspace = workspaces[workspaceId] else {
            return Workspace(workspaceId: workspaceId, label: workspaceId, number: Int.max)
        }
        guard let worktree = workspace.worktree, worktree.isLinkedWorktree else {
            return workspace
        }
        return rootWorkspacesByRepoKey[worktree.repoKey] ?? workspace
    }

    /// repoKey → root checkout を開いている workspace。同じ repo root を複数の workspace
    /// が開いている場合は番号が小さい方 (herdr 上で先に並ぶ方) を合流先にする。
    private var rootWorkspacesByRepoKey: [String: Workspace] {
        workspaces.values.reduce(into: [:]) { roots, workspace in
            guard let worktree = workspace.worktree, !worktree.isLinkedWorktree else { return }
            if let existing = roots[worktree.repoKey], existing.number <= workspace.number {
                return
            }
            roots[worktree.repoKey] = workspace
        }
    }

    // MARK: - ライフサイクル

    /// 初回snapshotとpollを開始する。複数回呼んでもtaskを増やさず、stop後は再開しない。
    /// 設定OFF/ONではFleetStoreが新しいStoreを作り、古いRPCの完了を新しいruntimeへ渡さない。
    func start() {
        guard !hasStarted, !hasBeenStopped else { return }
        hasStarted = true
        if case .ready = state {
            // start前に復元済みsnapshotを持つStoreは、初回poll完了までその表示を保つ。
        } else {
            state = .synchronizing
        }
        // スリープ移行中にtunnel readyが届いたremoteは、取得を始めずresumePolling()を待つ。
        guard !isPollingSuspended else { return }
        requestSnapshot()
        startPolling()
    }

    /// endpointの削除・無効化時にpollと進行中RPCを止め、表示snapshotを破棄する。
    func stop() {
        guard hasStarted, !hasBeenStopped else { return }
        hasBeenStopped = true
        pollingTask?.cancel()
        pollingTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        state = .disconnected
    }

    /// システムスリープ直前にpollと進行中RPCを止める。stop()と違い表示snapshotと
    /// 開始状態は保ち、resumePolling()で再開できる。cancelしたRPCがスリープ復帰後に
    /// 返ってもloadSnapshotのTask.isCancelledガードがstateへ反映しない。
    func suspendPolling() {
        guard !isPollingSuspended else { return }
        isPollingSuspended = true
        pollingTask?.cancel()
        pollingTask = nil
        // snapshotTaskはnilへ戻さない。requestSnapshotの重複ガードをcancel済みtaskの
        // 完了 (loadSnapshotのdefer) まで効かせ、resume直後に同じRPCを二重発行しない。
        snapshotTask?.cancel()
    }

    /// スリープ復帰時に直ちに1回取得し、pollを再開する。start()前にsuspendされていた
    /// Storeはここが初回取得になる。
    func resumePolling() {
        guard isPollingSuspended else { return }
        isPollingSuspended = false
        guard hasStarted, !hasBeenStopped else { return }
        requestSnapshot()
        startPolling()
    }

    /// リモート設定のpoll preset変更を既存Storeへ反映する。SSH tunnelとsocket pathは
    /// 変わらないため接続を作り直さず、現在のsleepだけcancelして新しい周期を開始する。
    func setPollInterval(_ interval: Duration) {
        precondition(interval > .zero)
        guard pollInterval != interval else { return }
        pollInterval = interval
        // suspend中は周期だけ更新し、resumePolling()が新しい周期でpollを開始する。
        guard hasStarted, !hasBeenStopped, !isPollingSuspended else { return }
        pollingTask?.cancel()
        startPolling()
    }

    private func startPolling() {
        pollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do {
                    try await Task.sleep(for: self.pollInterval)
                } catch {
                    return
                }
                self.requestSnapshot()
            }
        }
    }

    private func requestSnapshot() {
        // sleepを終えて再開待ちだったpoll tickはcancelを観測せずここへ届くことがあるため、
        // stopとsuspendはtask cancellationとは別にここでも弾く。
        guard hasStarted, !hasBeenStopped, !isPollingSuspended, snapshotTask == nil else { return }
        snapshotTask = Task { @MainActor [weak self] in
            await self?.loadSnapshot()
        }
    }

    private func loadSnapshot() async {
        defer { snapshotTask = nil }
        do {
            let serverSnapshot = try await dataSource.snapshot()
            guard !Task.isCancelled, !hasBeenStopped else { return }
            guard serverSnapshot.protocolVersion == Herdr.supportedProtocol else {
                log.error("protocol mismatch: server=\(serverSnapshot.protocolVersion)")
                state = .protocolMismatch(serverSnapshot.protocolVersion)
                return
            }
            let branches = await fetchBranches(for: serverSnapshot)
            guard !Task.isCancelled, !hasBeenStopped else { return }
            publish(
                AgentSnapshot(
                    agents: serverSnapshot.agents,
                    workspaces: serverSnapshot.workspaces,
                    branches: branches
                )
            )
        } catch {
            guard !Task.isCancelled, !hasBeenStopped else { return }
            state = .disconnected
            log.debug("snapshot failed: \(String(describing: error))")
        }
    }

    /// 監視対象 pane がいる workspace ごとに worktree.list を引き、workspace ID →
    /// branch 名の対応を作る。1 回の応答は同じ repo を開いている全 workspace の branch を
    /// open_workspace_id 付きで返すため、先行の応答で解決済みの workspace は引き直さない。
    /// workspace の worktree metadata では絞らない (git repo でも session.snapshot に
    /// metadata が付かない workspace があるため)。branch は表示装飾なので、失敗した
    /// workspace (非 git を含む) は対応を作らないまま進み (その pane はブランチ名なしで
    /// 出る)、poll の成否には関与しない。detached HEAD の checkout は branch を持たず
    /// 記録しない。
    private func fetchBranches(
        for snapshot: HerdrSessionSnapshot
    ) async -> [String: String] {
        let trackedWorkspaceIDs = Set(
            snapshot.agents.filter(Self.shouldTrack).map(\.workspaceId)
        )
        var branches: [String: String] = [:]
        for workspace in snapshot.workspaces {
            guard trackedWorkspaceIDs.contains(workspace.workspaceId),
                  branches[workspace.workspaceId] == nil else { continue }
            do {
                let list = try await dataSource.worktrees(workspace.workspaceId)
                for entry in list.worktrees {
                    guard let workspaceID = entry.openWorkspaceId,
                          let branch = entry.branch else { continue }
                    branches[workspaceID] = branch
                }
            } catch {
                log.debug(
                    "worktree.list failed for \(workspace.workspaceId, privacy: .public): \(String(describing: error))"
                )
            }
            if Task.isCancelled || hasBeenStopped { break }
        }
        return branches
    }

    /// Store.panes に保持する対象かを返す。agent_kind は完全一致で判定し、
    /// metadata 未付与または未知の値を持つエージェントは一覧へ残す。
    nonisolated static func shouldTrack(_ pane: Pane) -> Bool {
        pane.agent != nil && pane.tokens?.agentKind != "subagent"
    }

    private func publish(_ snapshot: AgentSnapshot) {
        if case .ready(let previous) = state {
            for (paneId, pane) in snapshot.panes {
                if let old = previous.panes[paneId], old.agentStatus != pane.agentStatus {
                    log.info("status: \(paneId, privacy: .public) \(old.agentStatus.rawValue, privacy: .public) -> \(pane.agentStatus.rawValue, privacy: .public) (snapshot)")
                }
            }
            guard previous != snapshot else { return }
        }
        state = .ready(snapshot)
    }

    // MARK: - 並び順

    /// グループ内の pane の並びキー。合流したグループには複数 workspace の pane が
    /// 混ざるため、workspace 番号を第一キーにして root → worktree の順を保ち、
    /// 同じ workspace 内は pane 番号で herdr 内の表示順に近づける。
    private func paneSortKey(_ pane: Pane) -> (Int, Int) {
        (workspaces[pane.workspaceId]?.number ?? Int.max, paneNumber(pane))
    }

    /// "w11:p2" → 2。pane ID の数値部で herdr 内の表示順に近づける。
    /// ID の suffix には英字が混ざりうるので、読めないときは末尾送りにする。
    private func paneNumber(_ pane: Pane) -> Int {
        guard let last = pane.paneId.split(separator: "p").last else { return Int.max }
        return Int(last) ?? Int.max
    }
}
