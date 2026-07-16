// Shepherd 全体の接続先集合を所有する。ローカル Herdr は常に 1 件あり、設定で
// 有効になったリモートごとに独立した Store と SSH tunnel を持つ。ある接続先の
// 切断・再同期は別の接続先の snapshot を破棄せず、メニューバー状態は現在 ready の
// snapshot だけを横断して blocked > done > working > quiet の順に集約する。
//
// リモートは監視専用で、agent.focus はローカル source にだけ公開する。永続化するのは
// RemoteSourceConfiguration とRemoteTunnelのremote socket path cacheで、Store、
// tunnel state、ローカル転送socketはruntimeごとに作り直す。設定変更ではIDとSSH接続条件が
// 同じmonitorを再利用し、表示名とpoll周期だけの変更でSSHを切らない。

import AppKit
import Foundation
import Observation
import ServiceManagement
import os

private let fleetLog = Logger(subsystem: "io.github.cryks.shepherd", category: "fleet")

/// 接続済み source 群を 1 個のメニューバーアイコンへ畳んだ表示状態。
enum MenuBarState {
    case disconnected
    case quiet
    case working
    case done
    case blocked
}

/// 1 接続先の UI 向け接続状態。Store の同期状態と remote tunnel の起動状態を
/// 1 値へ畳み、表示側が transport の実装詳細を switch しなくて済むようにする。
enum MonitoredSourceState: Equatable {
    case disabled
    case disconnected
    case discovering
    case connecting
    case retrying
    case synchronizing
    case ready
    case protocolMismatch(Int)
    case failed

    /// tr(_:ja:) が言語設定を観測するため @MainActor。表示側 (SourceList、Settings) は
    /// body 評価中にこれを読むので、言語切り替えで即座に描き直される。
    @MainActor var message: String {
        switch self {
        case .disabled:
            tr("Monitoring off", ja: "監視オフ")
        case .disconnected:
            tr("herdr not connected — waiting", ja: "herdr 未接続 — 接続待ち")
        case .discovering:
            tr("Looking for the remote herdr socket…", ja: "リモートの herdr socket を探索中…")
        case .connecting:
            tr("Connecting SSH tunnel…", ja: "SSH tunnel を接続中…")
        case .retrying:
            tr("Reconnecting SSH tunnel…", ja: "SSH tunnel を再接続中…")
        case .synchronizing:
            tr("Syncing agents…", ja: "エージェントを同期中…")
        case .ready:
            tr("Connected", ja: "接続済み")
        case .protocolMismatch(let version):
            tr("herdr protocol \(version) is not supported", ja: "herdr protocol \(version) は未対応")
        case .failed:
            tr("Cannot start the SSH tunnel", ja: "SSH tunnel を開始できません")
        }
    }
}

/// 表示上の 1 セクション。ローカルは `configuration == nil` かつ `source != nil`、
/// リモートは `configuration != nil` で、監視オフの間だけ `source == nil` になる。
/// remote configuration を runtime より長生きさせることで、checkbox を外して SSH
/// process を止めた後も、同じ ID・同じ並び順のセクション見出しを残す。
@MainActor
struct FleetSourceSection: Identifiable {
    /// ローカルでは固定 ID、リモートでは永続 configuration の ID。
    let id: HerdrSourceID
    /// nil はローカルを表す。リモートでは ON/OFF にかかわらず非 nil。
    let configuration: RemoteSourceConfiguration?
    /// 現在動作中の監視 runtime。監視オフのリモートだけ nil。
    let source: MonitoredSource?

    init(localSource: MonitoredSource) {
        precondition(!localSource.isRemote)
        id = .local
        configuration = nil
        source = localSource
    }

    init(
        configuration: RemoteSourceConfiguration,
        source: MonitoredSource?
    ) {
        precondition(source == nil || source?.id == configuration.id)
        id = configuration.id
        self.configuration = configuration
        self.source = source
    }

    var isRemote: Bool {
        configuration != nil
    }

    var isEnabled: Bool {
        configuration?.isEnabled ?? true
    }

    /// セクション見出し。リモートは永続設定の表示名。ローカルは LocalSectionTitleSetting
    /// が解決した文字列で、hidden 設定では nil (表示側は見出し行を描画しない)。
    var headerTitle: String? {
        if let configuration { return configuration.displayName }
        return LocalSectionTitleSetting.shared.localHeaderTitle
    }

    var state: MonitoredSourceState {
        if !isEnabled { return .disabled }
        return source?.state ?? .disconnected
    }

    /// 非 ready 状態でセクション本文に出す 1 行。監視オフは checkbox が OFF を
    /// 表すため本文を持たず nil (表示側は見出しだけのセクションになる)。
    var statusMessage: String? {
        guard isEnabled else { return nil }
        return source?.statusMessage ?? tr("Starting…", ja: "起動準備中…")
    }

    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        source?.workspaceGroups ?? []
    }
}

/// ローカルまたは 1 件のリモートを監視する runtime。remote tunnel が ready に
/// なってから Store を開始し、socket 探索中の接続失敗を Store の再接続ログへ混ぜない。
/// stop 後の Store は再利用せず、FleetStore の設定 reconciliation が新しい runtime を作る。
@Observable @MainActor
final class MonitoredSource: Identifiable {
    let id: HerdrSourceID
    private(set) var configuration: RemoteSourceConfiguration?
    let store: Store

    private(set) var tunnelState: RemoteTunnelState?
    private(set) var startupFailed = false

    private var tunnel: (any RemoteTunnelManaging)?
    private var hasStarted = false
    private var hasStopped = false
    private var storeHasStarted = false

    init(localStore: Store) {
        id = .local
        configuration = nil
        store = localStore
        tunnel = nil
        tunnelState = nil
    }

    init(
        configuration: RemoteSourceConfiguration,
        tunnel: any RemoteTunnelManaging,
        store: Store
    ) {
        id = configuration.id
        self.configuration = configuration
        self.tunnel = tunnel
        self.store = store
        tunnelState = tunnel.state
    }

    init(failedConfiguration configuration: RemoteSourceConfiguration) {
        id = configuration.id
        self.configuration = configuration
        store = Store(initialState: .disconnected)
        tunnel = nil
        tunnelState = nil
        startupFailed = true
    }

    var isRemote: Bool {
        configuration != nil
    }

    /// remote は tunnel と Store が両方 ready のときだけ snapshot を返す。
    /// 切断直後に Store の callback が MainActor へ届くまでの間も、古い snapshot が
    /// fleet のメニューバー状態へ一瞬混ざらないよう transport state も条件にする。
    var availableSnapshot: AgentSnapshot? {
        if isRemote {
            guard let tunnelState, case .ready = tunnelState else { return nil }
        }
        guard case .ready(let snapshot) = store.state else { return nil }
        return snapshot
    }

    var state: MonitoredSourceState {
        if startupFailed { return .failed }

        if let tunnelState {
            switch tunnelState {
            case .stopped:
                return .disconnected
            case .discovering:
                return .discovering
            case .connecting:
                return .connecting
            case .ready:
                break
            case .retrying:
                return .retrying
            case .failed:
                return .failed
            }
        }

        switch store.state {
        case .disconnected:
            return .disconnected
        case .synchronizing:
            return .synchronizing
        case .ready:
            return .ready
        case .protocolMismatch(let version):
            return .protocolMismatch(version)
        }
    }

    /// tunnel failure は原因別の短い文言へ変換し、再試行中か停止済みかを添える。
    /// stderr 本文は connectionDiagnostic に分け、狭い一覧を SSH 出力で埋めない。
    var statusMessage: String {
        guard let failure = tunnelFailure else { return state.message }
        let summary = failure.kind.userFacingSummary
        if let tunnelState, case .retrying = tunnelState {
            return tr("\(summary) — reconnecting", ja: "\(summary) — 再接続中")
        }
        return summary
    }

    /// SSH stderr / probe error の制御文字除去・4 KiB 上限は RemoteTunnel が保証する。
    /// Settings の help だけに出し、通常の source 一覧には原因分類だけを表示する。
    var connectionDiagnostic: String? {
        guard let failure = tunnelFailure, !failure.diagnostic.isEmpty else { return nil }
        return failure.diagnostic
    }

    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        store.workspaceGroups
    }

    /// ローカルは直ちに Store を開始する。remote は tunnel の ready callback が
    /// 転送 socket の ping 成功後に Store を開始する。
    func start() {
        guard !hasStarted, !hasStopped else { return }
        hasStarted = true

        guard let tunnel else {
            guard !startupFailed else { return }
            storeHasStarted = true
            store.start()
            return
        }

        tunnel.onStateChange = { [weak self] state in
            guard let self else { return }
            self.tunnelState = state
            if case .ready = state, !self.storeHasStarted {
                self.storeHasStarted = true
                self.store.start()
            }
        }
        tunnelState = tunnel.state
        tunnel.start()
    }

    /// callback を外してから socket/process を止める。shutdown による状態遷移を
    /// 削除済み source の UI へ届けない。
    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        tunnel?.onStateChange = nil
        if storeHasStarted {
            store.stop()
        }
        tunnel?.stop()
    }

    /// システムスリープ中のpoll停止。tunnel ready待ちでStoreが未開始でも先にsuspendを
    /// 立て、スリープ移行中にreadyが届いてもStoreが取得を始めないようにする。
    /// SSH tunnelは止めない。プロセスごとスリープで凍結され、復帰後に接続が切れていれば
    /// RemoteTunnelの再試行が同じローカルsocketで転送を回復する。
    func suspendPolling() {
        store.suspendPolling()
    }

    /// スリープ復帰時のpoll再開。Storeは直ちに1回取得する。
    func resumePolling() {
        store.resumePolling()
    }

    /// SSH alias と session が同じなら同じ endpoint とみなす。label、enabled、poll周期は
    /// transportを変えないため、既存StoreとSSH tunnelを保ったまま更新する。
    func canReuse(for candidate: RemoteSourceConfiguration) -> Bool {
        guard let configuration else { return false }
        return configuration.id == candidate.id
            && configuration.sshAlias == candidate.sshAlias
            && configuration.normalizedSessionName == candidate.normalizedSessionName
    }

    func updateMetadata(from candidate: RemoteSourceConfiguration) {
        precondition(canReuse(for: candidate))
        configuration = candidate
        store.setPollInterval(candidate.pollInterval.duration)
    }

    private var tunnelFailure: RemoteTunnelFailure? {
        guard let tunnelState else { return nil }
        switch tunnelState {
        case .retrying(let failure, _), .failed(let failure):
            return failure
        case .stopped, .discovering, .connecting, .ready:
            return nil
        }
    }
}

private extension RemoteTunnelFailure.Kind {
    @MainActor var userFacingSummary: String {
        switch self {
        case .sshLaunch:
            tr("Cannot launch SSH", ja: "SSH を起動できません")
        case .authentication:
            tr("SSH authentication failed", ja: "SSH 認証に失敗しました")
        case .hostKey:
            tr("Cannot verify the SSH host key", ja: "SSH ホスト鍵を確認できません")
        case .unreachable:
            tr("Cannot reach the SSH destination", ja: "SSH 接続先に到達できません")
        case .remoteHerdrMissing:
            tr("Cannot run herdr on the remote host", ja: "リモートで herdr を実行できません")
        case .remoteHerdrStopped:
            tr("The remote herdr is not running", ja: "リモートの herdr が停止しています")
        case .malformedStatus:
            tr("Cannot read the herdr server status", ja: "herdr の server status を読めません")
        case .invalidRemoteSocket:
            tr("The remote herdr socket path is invalid", ja: "リモートの herdr socket path が不正です")
        case .forwardingRejected:
            tr("Cannot forward the herdr socket over SSH", ja: "herdr socket を SSH 転送できません")
        case .timeout:
            tr("The SSH connection timed out", ja: "SSH 接続がタイムアウトしました")
        case .unexpectedExit:
            tr("The SSH connection closed", ja: "SSH 接続が終了しました")
        }
    }
}

enum RemoteSourceMutationError: Error, LocalizedError {
    case duplicateID
    case sourceNotFound

    var errorDescription: String? {
        switch self {
        case .duplicateID:
            trStored(
                "A remote connection with the same ID already exists",
                ja: "同じ ID のリモート接続がすでにあります"
            )
        case .sourceNotFound:
            trStored(
                "The remote connection was not found",
                ja: "対象のリモート接続が見つかりません"
            )
        }
    }
}

typealias RemoteTunnelFactory = @MainActor (
    RemoteSourceConfiguration
) throws -> any RemoteTunnelManaging

typealias EndpointStoreFactory = @MainActor (
    _ socketPath: String,
    _ pollInterval: Duration
) -> Store

/// ローカル pane への駆けつけ処理。FleetStore の source guard と実際の RPC を分け、
/// remote source ではこの依存自体が呼ばれないことをテストできるようにする。
struct LocalAgentFocus {
    var focus: @MainActor (_ pane: Pane) -> Void

    static let live = LocalAgentFocus { pane in
        Task {
            do {
                _ = try await Herdr.request(
                    "agent.focus",
                    params: ["target": pane.terminalId ?? pane.paneId],
                    socketPath: Herdr.defaultSocketPath,
                    as: EmptyResult.self
                )
            } catch {
                fleetLog.error("agent.focus failed: \(String(describing: error))")
            }
            activateConfiguredTerminal()
        }
    }

    @MainActor
    private static func activateConfiguredTerminal() {
        let bundleID = UserDefaults.standard.string(forKey: "TerminalBundleID")
            ?? "com.mitchellh.ghostty"
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate()
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            NSWorkspace.shared.openApplication(
                at: url,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
    }
}

/// アプリの最上位 state。activeSources はローカルと、表示 ON かつ監視 ON の remote
/// runtime だけを所有し、sourceSections はローカルに続けて表示 ON の remote を設定順に
/// 公開する。監視 OFF の remote は section だけを残し、Store・SSH process・一時 socket を
/// 作らない。表示 OFF (isVisible == false) の remote は section 自体を出さず、監視 ON の
/// remote でも runtime を止める。
@Observable @MainActor
final class FleetStore {
    private(set) var activeSources: [MonitoredSource]
    private(set) var remoteConfigurations: [RemoteSourceConfiguration]
    var monitorWindowVisible = false

    private let repository: RemoteSourceRepository
    private let tunnelFactory: RemoteTunnelFactory
    private let remoteStoreFactory: EndpointStoreFactory
    private let localAgentFocus: LocalAgentFocus
    private let localSource: MonitoredSource
    private var hasStarted = false
    private var hasStopped = false
    /// システムスリープ中はtrue。この間にreconcileSourcesが作るsourceへもsuspendを
    /// 適用し、resumePolling()がまとめて再開する。
    private var isPollingSuspended = false

    init(
        repository: RemoteSourceRepository = .live,
        localStore: Store? = nil,
        tunnelFactory: @escaping RemoteTunnelFactory = { configuration in
            try RemoteTunnelManager(configuration: configuration)
        },
        remoteStoreFactory: @escaping EndpointStoreFactory = { socketPath, pollInterval in
            Store.live(socketPath: socketPath, pollInterval: pollInterval)
        },
        localAgentFocus: LocalAgentFocus = .live
    ) {
        self.repository = repository
        self.tunnelFactory = tunnelFactory
        self.remoteStoreFactory = remoteStoreFactory
        self.localAgentFocus = localAgentFocus
        let loadedConfigurations = repository.load()
        if Set(loadedConfigurations.map(\.id)).count == loadedConfigurations.count {
            remoteConfigurations = loadedConfigurations
        } else {
            remoteConfigurations = []
            fleetLog.error("remote source settings contain duplicate IDs")
        }
        localSource = MonitoredSource(
            localStore: localStore ?? Store.live(
                socketPath: Herdr.defaultSocketPath,
                pollInterval: Store.localPollInterval
            )
        )
        activeSources = [localSource]
        reconcileSources()
    }

    /// メニューと監視ウィンドウが表示する順序付き projection。監視 OFF 操作で
    /// runtime が消えても configuration から同じ section を再構成する。表示 OFF の
    /// remote は section を作らないため、両画面から見出しごと消える。
    var sourceSections: [FleetSourceSection] {
        let remoteSources = Dictionary(
            uniqueKeysWithValues: activeSources
                .filter(\.isRemote)
                .map { ($0.id, $0) }
        )
        return [FleetSourceSection(localSource: localSource)]
            + remoteConfigurations.filter(\.isVisible).map { configuration in
                FleetSourceSection(
                    configuration: configuration,
                    source: remoteSources[configuration.id]
                )
            }
    }

    var menuBarState: MenuBarState {
        Self.aggregateMenuBarState(activeSources.compactMap(\.availableSnapshot))
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                fleetLog.error("launch-at-login toggle failed: \(String(describing: error))")
            }
        }
    }

    func start() {
        guard !hasStarted, !hasStopped else { return }
        hasStarted = true
        activeSources.forEach { $0.start() }
    }

    /// アプリ終了時に全pollとmanaged SSH processを止める。停止後のfleetは
    /// session 世代を再利用せず、次のアプリ起動で設定から作り直す。
    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        activeSources.forEach { $0.stop() }
    }

    /// システムスリープ直前に全sourceのpollを止める。ShepherdApplicationDelegateが
    /// NSWorkspace.willSleepNotificationで呼ぶ。
    func suspendPolling() {
        guard !isPollingSuspended else { return }
        isPollingSuspended = true
        activeSources.forEach { $0.suspendPolling() }
    }

    /// スリープ復帰時に全sourceのpollを再開する。NSWorkspace.didWakeNotificationで呼ぶ。
    func resumePolling() {
        guard isPollingSuspended else { return }
        isPollingSuspended = false
        activeSources.forEach { $0.resumePolling() }
    }

    /// ready の source が 1 件でもあれば、未接続 source は集約から外す。これにより
    /// remote 1 台の停止が local の blocked/done を破線で隠さない。ready が 0 件なら
    /// fleet 全体を disconnected とする。
    static func aggregateMenuBarState(_ snapshots: [AgentSnapshot]) -> MenuBarState {
        guard !snapshots.isEmpty else { return .disconnected }
        let statuses = Set(
            snapshots.flatMap { snapshot in
                snapshot.panes.values.map(\.agentStatus)
            }
        )
        if statuses.contains(.blocked) { return .blocked }
        if statuses.contains(.done) { return .done }
        if statuses.contains(.working) { return .working }
        return .quiet
    }

    func addRemote(_ configuration: RemoteSourceConfiguration) throws {
        guard !remoteConfigurations.contains(where: { $0.id == configuration.id }) else {
            throw RemoteSourceMutationError.duplicateID
        }
        try commit(remoteConfigurations + [configuration])
    }

    /// SSH 接続条件と表示名を更新する。表示・監視の ON/OFF は現在値を保ち、別ウィンドウで
    /// 開いた古い editor draft が設定一覧のトグルやメニューの checkbox 操作を
    /// 巻き戻さないようにする。
    func updateRemote(_ configuration: RemoteSourceConfiguration) throws {
        guard let index = remoteConfigurations.firstIndex(where: { $0.id == configuration.id }) else {
            throw RemoteSourceMutationError.sourceNotFound
        }
        var candidate = remoteConfigurations
        var updated = configuration
        updated.isVisible = candidate[index].isVisible
        updated.isEnabled = candidate[index].isEnabled
        candidate[index] = updated
        try commit(candidate)
    }

    /// メニューパネルの checkbox 状態を保存して runtime 集合へ反映する。OFF では
    /// tunnel を止めるが configuration は残すため、sourceSections の見出しは消えない。
    func setRemoteEnabled(id: HerdrSourceID, isEnabled: Bool) throws {
        guard let index = remoteConfigurations.firstIndex(where: { $0.id == id }) else {
            throw RemoteSourceMutationError.sourceNotFound
        }
        var candidate = remoteConfigurations
        candidate[index].isEnabled = isEnabled
        try commit(candidate)
    }

    /// 設定 Remotes 一覧のホスト単位トグルを保存して runtime 集合へ反映する。
    /// isEnabled の上位フラグで、OFF では sourceSections から見出しごと消え、監視 ON の
    /// remote も tunnel を止める。isEnabled は書き換えないため、ON へ戻すと監視 ON
    /// だった remote はそのまま監視を再開する。
    func setRemoteVisible(id: HerdrSourceID, isVisible: Bool) throws {
        guard let index = remoteConfigurations.firstIndex(where: { $0.id == id }) else {
            throw RemoteSourceMutationError.sourceNotFound
        }
        var candidate = remoteConfigurations
        candidate[index].isVisible = isVisible
        try commit(candidate)
    }

    func removeRemote(id: HerdrSourceID) throws {
        guard remoteConfigurations.contains(where: { $0.id == id }) else {
            throw RemoteSourceMutationError.sourceNotFound
        }
        try commit(remoteConfigurations.filter { $0.id != id })
    }

    /// 設定画面のドラッグ並び替えを保存する。引数は SwiftUI onMove の規約に従い、
    /// destination は要素を取り出す前の配列に対する挿入位置。
    func moveRemote(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var candidate = remoteConfigurations
        candidate.move(fromOffsets: source, toOffset: destination)
        try commit(candidate)
    }

    func monitoredSource(id: HerdrSourceID) -> MonitoredSource? {
        activeSources.first { $0.id == id }
    }

    /// リモート行には呼び出し口を渡さない。sourceID の検証もここで重ね、
    /// 表示側の誤配線から remote herdr へ agent.focus が送られないようにする。
    func focus(_ pane: Pane, sourceID: HerdrSourceID) {
        guard sourceID == .local else { return }
        localAgentFocus.focus(pane)
    }

    private func commit(_ configurations: [RemoteSourceConfiguration]) throws {
        let validated = try configurations.map { try $0.validated() }
        guard Set(validated.map(\.id)).count == validated.count else {
            throw RemoteSourceMutationError.duplicateID
        }
        try repository.save(validated)
        remoteConfigurations = validated
        reconcileSources()
    }

    private func reconcileSources() {
        var remaining = Dictionary(
            uniqueKeysWithValues: activeSources
                .filter(\.isRemote)
                .map { ($0.id, $0) }
        )
        var next = [localSource]

        for configuration in remoteConfigurations
        where configuration.isVisible && configuration.isEnabled {
            if let existing = remaining[configuration.id] {
                remaining.removeValue(forKey: configuration.id)
                if existing.canReuse(for: configuration) {
                    existing.updateMetadata(from: configuration)
                    next.append(existing)
                    continue
                }
                existing.stop()
            }
            let source = makeRemoteSource(configuration)
            if isPollingSuspended {
                source.suspendPolling()
            }
            next.append(source)
            if hasStarted, !hasStopped {
                source.start()
            }
        }

        remaining.values.forEach { $0.stop() }
        activeSources = next
    }

    private func makeRemoteSource(_ configuration: RemoteSourceConfiguration) -> MonitoredSource {
        do {
            let tunnel = try tunnelFactory(configuration)
            return MonitoredSource(
                configuration: configuration,
                tunnel: tunnel,
                store: remoteStoreFactory(
                    tunnel.localSocketPath,
                    configuration.pollInterval.duration
                )
            )
        } catch {
            fleetLog.error(
                "remote tunnel setup failed for \(configuration.id.rawValue, privacy: .public): \(String(describing: error))"
            )
            return MonitoredSource(failedConfiguration: configuration)
        }
    }

}
