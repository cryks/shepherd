// herdr ソケット API (protocol 16) の JSON のうち、このアプリが読む範囲だけを型にする。
// session.snapshot の agents 要素を Pane、workspaces 要素を Workspace で受け、
// worktree.list の worktrees 要素を WorktreeEntry で受ける。
// デコードは keyDecodingStrategy = .convertFromSnakeCase 前提で、
// フィールド名は JSON の snake_case を camelCase にしたもの。未知のキーは無視される。

import Foundation

/// herdr が pane ごとに報告するエージェント状態。
/// idle と done は「待機中」という同じ実体で、done は完了結果が herdr 上で未閲覧のときだけ付く。
/// herdr 側で pane を閲覧すると done は idle に戻るため、このアプリは独自の既読管理を持たない。
enum AgentStatus: String, Codable {
    case idle, working, blocked, done, unknown
}

/// session.snapshot の agents 要素。
/// agent が nil の pane はエージェント pane ではない (素のシェルなど)。
struct Pane: Codable, Identifiable, Equatable {
    /// 検出されたエージェント名 (claude, codex など)。nil なら監視対象外。
    var agent: String?
    var agentStatus: AgentStatus
    var paneId: String
    var workspaceId: String
    /// ローカル行の agent.focus target に使う。pane ID は pane 移動で変わるが
    /// terminal ID は安定する。リモート行は監視専用なので送信には使わない。
    var terminalId: String?
    /// スピナー等の装飾を除いたターミナルタイトル。エージェントの現在作業の表示に使う。
    var terminalTitleStripped: String?
    /// pane の生成元などを表す herdr metadata。pane.created の時点では nil のことがあり、
    /// agent検出直後のsnapshotではnilのことがあり、後続pollで値が入る。
    var tokens: PaneTokens?
    /// pane の workspace が git checkout を開いているとき、Store が worktree.list の
    /// branch を書き込む。session.snapshot の JSON に対応キーはなくデコード直後は nil。
    /// 非 git の workspace、detached HEAD、worktree.list の取得に失敗した poll では
    /// nil のままで、サブ行は場所を出さない (cwd などの代替テキストで埋めない)。
    var branch: String? = nil

    var id: String { paneId }

    /// 一覧 (メニュー・監視ウィンドウ) のメイン行に出す文言。
    /// 作業タイトルが空の間 (エージェント起動直後など) はエージェント名で埋める。
    var displayTitle: String {
        if let title = terminalTitleStripped, !title.isEmpty { return title }
        return agent ?? "?"
    }

    /// 一覧のサブ行に出す「誰が・どこで」のテキスト表示。
    /// マークアセットを持つ agent のサブ行は AgentRow がアイコン + branch で組むため、
    /// これはマークの無い agent 用のフォールバック。branch が無い pane は agent 名だけを出す。
    var displaySubtitle: String {
        guard let branch else { return agent ?? "?" }
        return "\(agent ?? "?") — \(branch)"
    }
}

/// herdr が pane に付与する metadata のうち、Shepherd が読む範囲。
/// agent_kind は将来追加される値でも pane 全体をデコードできるよう String で保持する。
struct PaneTokens: Codable, Equatable {
    /// pane の生成元。サブエージェントでは `"subagent"`、metadata 未付与または
    /// herdr が生成元を分類しない pane では nil。
    var agentKind: String?
}

/// session.snapshot の workspaces 要素。監視ウィンドウのグループ見出しと並び順に使う。
struct Workspace: Codable, Identifiable, Equatable {
    var workspaceId: String
    var label: String?
    /// herdr UI 上の表示番号。グループの並び順に使う。
    var number: Int
    /// workspace が git checkout を開いているときだけ付く。非 git の workspace では nil。
    var worktree: WorkspaceWorktree? = nil

    var id: String { workspaceId }
}

/// session.snapshot の workspace が持つ worktree metadata のうち読む範囲。
/// 同じ repo を開いた workspace 同士の対応付けに使う。
struct WorkspaceWorktree: Codable, Equatable {
    /// repo root の .git パス。root checkout と linked worktree で同じ値になり、
    /// linked worktree の pane を root checkout のグループへ寄せるキーになる。
    var repoKey: String
    /// true は `git worktree add` で作られた checkout。false は repo root の checkout で、
    /// 監視一覧では linked worktree の合流先になる。
    var isLinkedWorktree: Bool
}

// MARK: - RPC エンベロープ

struct RPCError: Codable, Error {
    var code: String
    var message: String
}

/// 一発 RPC のレスポンス行。result と error は排他。
struct RPCResponse<R: Codable>: Codable {
    var id: String?
    var result: R?
    var error: RPCError?
}

/// `session.snapshot` が返す bootstrap payload。Shepherd は全 pane ではなく
/// agent として検出済みの行、およびそのグループ見出しに必要な workspace だけを読む。
/// version と protocol は同じ取得結果に含まれるため、別の ping RPC を挟まない。
struct HerdrSessionSnapshot: Codable {
    var version: String
    var protocolVersion: Int
    var agents: [Pane]
    var workspaces: [Workspace]

    enum CodingKeys: String, CodingKey {
        case version
        case protocolVersion = "protocol"
        case agents
        case workspaces
    }
}

/// `session.snapshot` の result は型名と snapshot 本体を 1 段包む。
/// 未使用の `type` は decoder が無視し、Store へは snapshot 本体だけを渡す。
struct SessionSnapshotResult: Codable {
    var snapshot: HerdrSessionSnapshot
}

/// `worktree.list` の result。params の workspace_id が属する repo の checkout 一覧を返す。
/// Shepherd はブランチ名の表示に使う範囲だけを読む。
struct WorktreeListResult: Codable {
    var worktrees: [WorktreeEntry]
}

/// worktree.list の worktrees 要素。root checkout と linked worktree の両方が含まれる。
struct WorktreeEntry: Codable {
    /// checkout しているブランチ名。detached HEAD では nil。
    var branch: String?
    /// この checkout を開いている workspace の ID。どの workspace でも開かれていなければ nil。
    var openWorkspaceId: String?
}

/// result の中身を読まない RPC (agent.focus など) 用。
struct EmptyResult: Codable {}
