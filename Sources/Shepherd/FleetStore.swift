import AppKit
import Foundation
import Observation
import ServiceManagement
import os

private let fleetLog = Logger(subsystem: "io.github.cryks.shepherd", category: "fleet")

enum MenuBarState {
    case disconnected
    case quiet
    case working
    case done
    case blocked
}

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

    // @MainActor because tr() observes the language setting: reading this during
    // body evaluation makes a language switch redraw right away.
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

@MainActor
func protocolWarningDescription(_ version: Int) -> String {
    tr("herdr protocol \(version) is untested", ja: "herdr protocol \(version) は未検証")
}

// A remote keeps its configuration after its runtime is gone, so the section
// header survives a monitoring-OFF toggle with the same ID and position.
@MainActor
struct FleetSourceSection: Identifiable {
    let id: HerdrSourceID
    let configuration: RemoteSourceConfiguration?
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

    var headerTitle: String? {
        if let configuration { return configuration.displayName }
        return LocalSectionTitleSetting.shared.localTitleWithRemotes
    }

    var state: MonitoredSourceState {
        if !isEnabled { return .disabled }
        return source?.state ?? .disconnected
    }

    var statusMessage: String? {
        guard isEnabled else { return nil }
        return source?.statusMessage ?? tr("Starting…", ja: "起動準備中…")
    }

    var protocolWarning: Int? {
        source?.protocolWarning
    }

    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        source?.workspaceGroups ?? []
    }
}

@Observable @MainActor
final class MonitoredSource: Identifiable {
    let id: HerdrSourceID
    // Identifies the runtime, not the persisted endpoint. A reconnect keeps the
    // value; a new runtime gets a new one so attention monitoring re-baselines
    // instead of comparing agents from two different herdr servers.
    let attentionGenerationID = AttentionSourceGenerationID()
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

    // The tunnel state is checked as well as the Store state: between a
    // disconnect and the Store callback reaching the MainActor, the Store still
    // holds a stale snapshot that must not reach the menu bar.
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

    var protocolWarning: Int? {
        guard state == .ready else { return nil }
        return store.protocolWarning
    }

    var statusMessage: String {
        guard let failure = tunnelFailure else {
            if let warning = protocolWarning {
                return protocolWarningDescription(warning)
            }
            return state.message
        }
        let summary = failure.kind.userFacingSummary
        if let tunnelState, case .retrying = tunnelState {
            return tr("\(summary) — reconnecting", ja: "\(summary) — 再接続中")
        }
        return summary
    }

    // Safe to show as-is: RemoteTunnel strips control characters and caps SSH
    // stderr at 4 KiB. Still Settings-only, because the source list is too
    // narrow for a stderr dump.
    var connectionDiagnostic: String? {
        guard let failure = tunnelFailure, !failure.diagnostic.isEmpty else { return nil }
        return failure.diagnostic
    }

    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        store.workspaceGroups
    }

    // A remote Store starts only once the tunnel reports ready, so failures
    // during socket discovery never enter the Store's reconnection log.
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
            if case .ready = state {
                if !self.storeHasStarted {
                    self.storeHasStarted = true
                    self.store.start()
                }
            } else {
                self.store.markAgentContentSourceUnavailable()
            }
        }
        tunnelState = tunnel.state
        tunnel.start()
    }

    // Detach the callback first: shutdown state changes must not reach the UI
    // of a source that is already removed.
    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        tunnel?.onStateChange = nil
        if storeHasStarted {
            store.stop()
        }
        tunnel?.stop()
    }

    // The SSH tunnel keeps running across sleep: the process is frozen anyway,
    // and RemoteTunnel's retry restores forwarding on the same local socket if
    // the connection broke.
    func suspendPolling() {
        store.suspendPolling()
    }

    func resumePolling() {
        store.resumePolling()
    }

    // Only the fields that define the transport are compared, so editing the
    // display name, the enabled flag or the poll interval does not drop the
    // SSH connection.
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

struct LocalAgentFocus {
    var focus: @MainActor (_ pane: Pane) async -> Void

    init(_ focus: @escaping @MainActor (_ pane: Pane) async -> Void) {
        self.focus = focus
    }

    // request gets the pane ID, not a terminal ID: protocol 22 agent methods
    // reject terminal IDs.
    init(
        request: @escaping @MainActor (_ target: String) async throws -> Void,
        applicationActivation:
            @escaping @MainActor () async -> ApplicationActivationResult,
        terminalActivation: @escaping @MainActor () -> TerminalApplicationActivation
    ) {
        focus = { pane in
            let activation = terminalActivation()
            do {
                try await request(pane.paneId)
            } catch {
                fleetLog.error("agent.focus failed: \(String(describing: error))")
            }
            guard await applicationActivation().allowsTerminalHandoff else { return }
            await activation.activate()
        }
    }

    static let live = LocalAgentFocus(
        request: { target in
            _ = try await Herdr.request(
                "agent.focus",
                params: ["target": target],
                socketPath: Herdr.defaultSocketPath,
                as: EmptyResult.self
            )
        },
        applicationActivation: {
            await ApplicationActivationCoordinator.shared.activate()
        },
        terminalActivation: { .configured() }
    )
}

// activate() completes when NSWorkspace accepts the cooperative activation
// request. Whether the terminal really becomes frontmost stays with AppKit.
struct TerminalApplicationActivation {
    var activate: @MainActor () async -> Void

    @MainActor
    static func configured() -> Self {
        let bundleID = UserDefaults.standard.string(forKey: "TerminalBundleID")
            ?? "com.mitchellh.ghostty"
        return Self(
            activate: {
                guard let url = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: bundleID
                ) else {
                    fleetLog.error("configured terminal application was not found")
                    return
                }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                do {
                    _ = try await NSWorkspace.shared.openApplication(
                        at: url,
                        configuration: configuration
                    )
                } catch {
                    fleetLog.error(
                        "terminal activation failed: \(String(describing: error))"
                    )
                }
            }
        )
    }
}

@Observable @MainActor
final class FleetStore {
    private(set) var activeSources: [MonitoredSource]
    private(set) var remoteConfigurations: [RemoteSourceConfiguration]
    // Counted with presence leases rather than a flag: while the Monitor window
    // reopens, the outgoing and incoming SwiftUI instances overlap, and the
    // last appear/disappear callback to arrive is not the current one.
    var monitorWindowVisible: Bool {
        !monitorWindowPresenceIDs.isEmpty
    }

    private let repository: RemoteSourceRepository
    private let tunnelFactory: RemoteTunnelFactory
    private let remoteStoreFactory: EndpointStoreFactory
    private let localAgentFocus: LocalAgentFocus
    private let localSource: MonitoredSource
    private var hasStarted = false
    private var hasStopped = false
    private var monitorWindowPresenceIDs: Set<UUID> = []
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

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        monitorWindowPresenceIDs.removeAll()
        activeSources.forEach { $0.stop() }
    }

    func suspendPolling() {
        guard !isPollingSuspended else { return }
        isPollingSuspended = true
        activeSources.forEach { $0.suspendPolling() }
    }

    func resumePolling() {
        guard isPollingSuspended else { return }
        isPollingSuspended = false
        activeSources.forEach { $0.resumePolling() }
    }

    // Callers pass only the snapshots of ready sources, so one stopped remote
    // cannot hide local's blocked or done behind the disconnected icon.
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

    func updateRemote(_ configuration: RemoteSourceConfiguration) throws {
        guard let index = remoteConfigurations.firstIndex(where: { $0.id == configuration.id }) else {
            throw RemoteSourceMutationError.sourceNotFound
        }
        var candidate = remoteConfigurations
        // Both toggles are taken from the stored copy, never from the argument:
        // a stale editor draft must not roll back a checkbox flipped elsewhere.
        var updated = configuration
        updated.isVisible = candidate[index].isVisible
        updated.isEnabled = candidate[index].isEnabled
        candidate[index] = updated
        try commit(candidate)
    }

    func setRemoteEnabled(id: HerdrSourceID, isEnabled: Bool) throws {
        guard let index = remoteConfigurations.firstIndex(where: { $0.id == id }) else {
            throw RemoteSourceMutationError.sourceNotFound
        }
        var candidate = remoteConfigurations
        candidate[index].isEnabled = isEnabled
        try commit(candidate)
    }

    // Visibility sits above isEnabled and leaves it alone, so turning a host
    // back on resumes monitoring exactly as it was left.
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

    // Arguments follow the SwiftUI onMove convention: destination is an index
    // into the array before the moved elements are removed.
    func moveRemote(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var candidate = remoteConfigurations
        candidate.move(fromOffsets: source, toOffset: destination)
        try commit(candidate)
    }

    func monitoredSource(id: HerdrSourceID) -> MonitoredSource? {
        activeSources.first { $0.id == id }
    }

    var showsSourceLabels: Bool {
        remoteConfigurations.contains(where: \.isVisible)
    }

    func rowContext(for paneID: SourcePaneID) -> AgentRowContext? {
        guard let source = monitoredSource(id: paneID.sourceID),
              let pane = source.store.panes[paneID.paneID] else { return nil }
        let raw = source.store.rawRecords(forPane: paneID.paneID)
        return AgentRowContext(
            pane: pane,
            rawAgent: raw.agent,
            rawWorkspace: raw.workspace,
            rawTab: raw.tab,
            excerpt: agentExcerpt(for: paneID)?.text,
            sourceLabel: sourceLabel(of: source)
        )
    }

    private func sourceLabel(of source: MonitoredSource) -> String? {
        guard showsSourceLabels else { return nil }
        if let configuration = source.configuration { return configuration.displayName }
        return LocalSectionTitleSetting.shared.localTitleWithRemotes
    }

    func agentExcerpt(for paneID: SourcePaneID) -> AgentExcerpt? {
        guard let state = agentExcerptState(for: paneID),
              case .available(let excerpt) = state else {
            return nil
        }
        return excerpt
    }

    func agentExcerptState(for paneID: SourcePaneID) -> AgentExcerptState? {
        guard ExcerptSetting.shared.isEnabled,
              let source = monitoredSource(id: paneID.sourceID),
              source.state == .ready,
              let pane = source.store.panes[paneID.paneID],
              isAgentContentSupported(pane) else {
            return nil
        }
        return source.store.agentExcerptState(for: paneID.paneID)
    }

    func isAgentContentSupported(_ pane: Pane) -> Bool {
        pane.agent.map(AgentExcerptMachine.supports(agentID:)) ?? false
    }

    func monitorWindowDidAppear(_ presenceID: UUID) {
        guard !hasStopped else { return }
        monitorWindowPresenceIDs.insert(presenceID)
    }

    func monitorWindowDidDisappear(_ presenceID: UUID) {
        monitorWindowPresenceIDs.remove(presenceID)
    }

    // Remote rows never reach this call site; the guard is a second layer so a
    // miswired view cannot send agent.focus to a remote herdr.
    func focus(_ pane: Pane, sourceID: HerdrSourceID) async {
        guard sourceID == .local else { return }
        await localAgentFocus.focus(pane)
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
