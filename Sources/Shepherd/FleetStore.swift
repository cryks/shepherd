// Owns the full set of connection endpoints for Shepherd. There is always exactly
// one local Herdr, and each remote enabled in settings gets its own independent
// Store and SSH tunnel. A disconnect or resync on one endpoint never discards
// another endpoint's snapshot; the menu bar state aggregates only the currently
// ready snapshots, in blocked > done > working > quiet priority order.
//
// Remotes are monitor-only; agent.focus is exposed only to the local source. Only
// RemoteSourceConfiguration and RemoteTunnel's remote socket path cache are
// persisted; the Store, tunnel state, and local forwarding socket are rebuilt for
// each runtime. On configuration changes, a monitor whose ID and SSH connection
// parameters are unchanged is reused, so edits limited to the display name or poll
// interval do not drop the SSH connection.

import AppKit
import Foundation
import Observation
import ServiceManagement
import os

private let fleetLog = Logger(subsystem: "io.github.cryks.shepherd", category: "fleet")

/// Display state that collapses the set of connected sources into a single menu bar icon.
enum MenuBarState {
    case disconnected
    case quiet
    case working
    case done
    case blocked
}

/// UI-facing connection state for a single endpoint. Collapses the Store's sync
/// state and the remote tunnel's startup state into one value so the view layer
/// does not have to switch over transport implementation details.
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

    /// @MainActor because tr(_:ja:) observes the language setting. The view layer
    /// (SourceList, Settings) reads this during body evaluation, so a language
    /// switch redraws immediately.
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

/// One section as displayed. Local has `configuration == nil` and `source != nil`;
/// a remote has `configuration != nil`, with `source == nil` only while monitoring
/// is off. Letting the remote configuration outlive the runtime keeps the section
/// header — same ID, same ordering — even after unchecking the checkbox stops the
/// SSH process.
@MainActor
struct FleetSourceSection: Identifiable {
    /// A fixed ID for local; the persistent configuration's ID for a remote.
    let id: HerdrSourceID
    /// nil means local. For a remote it is non-nil regardless of the ON/OFF state.
    let configuration: RemoteSourceConfiguration?
    /// The currently running monitoring runtime. nil only for a remote whose monitoring is off.
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

    /// Section header. For a remote, the persistent configuration's display name.
    /// For local, the string resolved by LocalSectionTitleSetting; nil when the
    /// hidden setting is chosen (the view layer draws no header row).
    var headerTitle: String? {
        if let configuration { return configuration.displayName }
        return LocalSectionTitleSetting.shared.localHeaderTitle
    }

    var state: MonitoredSourceState {
        if !isEnabled { return .disabled }
        return source?.state ?? .disconnected
    }

    /// The single line shown in the section body while not ready. When monitoring
    /// is off the checkbox already conveys OFF, so there is no body and this is nil
    /// (the view layer renders a header-only section).
    var statusMessage: String? {
        guard isEnabled else { return nil }
        return source?.statusMessage ?? tr("Starting…", ja: "起動準備中…")
    }

    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        source?.workspaceGroups ?? []
    }
}

/// Runtime that monitors local or one remote. Starts the Store only after the
/// remote tunnel becomes ready, so connection failures during socket discovery do
/// not pollute the Store's reconnection log. A stopped Store is never reused;
/// FleetStore's configuration reconciliation creates a fresh runtime.
@Observable @MainActor
final class MonitoredSource: Identifiable {
    let id: HerdrSourceID
    /// Identifies this runtime rather than its persisted endpoint. Reconnecting an
    /// existing tunnel keeps the value, while disabling monitoring or changing
    /// connection parameters creates a new runtime and therefore a new value.
    /// Attention monitoring uses this boundary to baseline the replacement instead
    /// of comparing agents from two different Herdr servers.
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

    /// For a remote, returns a snapshot only while both the tunnel and the Store are
    /// ready. The transport state is part of the condition so that, in the window
    /// right after a disconnect before the Store's callback reaches the MainActor,
    /// a stale snapshot never leaks into the fleet's menu bar state even briefly.
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

    /// Maps a tunnel failure to a short per-cause message, annotated with whether it
    /// is retrying or stopped. The stderr body is split out into connectionDiagnostic
    /// so SSH output does not flood the narrow source list.
    var statusMessage: String {
        guard let failure = tunnelFailure else { return state.message }
        let summary = failure.kind.userFacingSummary
        if let tunnelState, case .retrying = tunnelState {
            return tr("\(summary) — reconnecting", ja: "\(summary) — 再接続中")
        }
        return summary
    }

    /// RemoteTunnel guarantees control-character stripping and the 4 KiB cap on SSH
    /// stderr / probe errors. Shown only in the Settings help; the regular source
    /// list displays only the failure classification.
    var connectionDiagnostic: String? {
        guard let failure = tunnelFailure, !failure.diagnostic.isEmpty else { return nil }
        return failure.diagnostic
    }

    var workspaceGroups: [(workspace: Workspace, panes: [Pane])] {
        store.workspaceGroups
    }

    /// Local starts the Store immediately. For a remote, the tunnel's ready callback
    /// starts the Store after a ping over the forwarded socket succeeds.
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

    /// Detaches the callback before stopping the socket/process, so state transitions
    /// caused by the shutdown never reach the UI of an already-removed source.
    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        tunnel?.onStateChange = nil
        if storeHasStarted {
            store.stop()
        }
        tunnel?.stop()
    }

    /// Halts polling during system sleep. Sets suspend up front even while the Store
    /// has not started yet because it is waiting for tunnel ready, so a ready event
    /// arriving mid-transition to sleep does not make the Store start fetching.
    /// The SSH tunnel is left running: the whole process is frozen by sleep, and if
    /// the connection is broken after wake, RemoteTunnel's retry restores forwarding
    /// on the same local socket.
    func suspendPolling() {
        store.suspendPolling()
    }

    /// Resumes polling on wake from sleep. The Store fetches once immediately.
    func resumePolling() {
        store.resumePolling()
    }

    /// Treats the endpoint as identical when the SSH alias and session match. The
    /// label, enabled flag, and poll interval do not affect the transport, so those
    /// updates keep the existing Store and SSH tunnel.
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

/// Jump-to-local-pane action. Separates FleetStore's source guard from the actual
/// RPC so tests can assert this dependency is never invoked for a remote source.
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

/// The app's top-level state. activeSources owns only the local runtime plus the
/// remotes that are both visible and monitoring-enabled; sourceSections exposes
/// local first, then visible remotes in configuration order. A remote with
/// monitoring OFF keeps only its section and never creates a Store, SSH process,
/// or temporary socket. A remote with visibility OFF (isVisible == false) emits no
/// section at all, and its runtime is stopped even if monitoring is ON.
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
    /// true while the system is asleep. Sources created by reconcileSources during
    /// this window are also suspended, and resumePolling() resumes them all at once.
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

    /// Ordered projection displayed by the menu and the monitor window. Even after a
    /// monitoring-OFF operation removes the runtime, the same section is rebuilt from
    /// the configuration. A visibility-OFF remote produces no section, so it
    /// disappears from both screens, header and all.
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

    /// Stops all polling and managed SSH processes at app termination. A stopped
    /// fleet never reuses its session generation; the next app launch rebuilds it
    /// from configuration.
    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        activeSources.forEach { $0.stop() }
    }

    /// Stops polling on all sources just before system sleep. Called by
    /// ShepherdApplicationDelegate on NSWorkspace.willSleepNotification.
    func suspendPolling() {
        guard !isPollingSuspended else { return }
        isPollingSuspended = true
        activeSources.forEach { $0.suspendPolling() }
    }

    /// Resumes polling on all sources at wake from sleep. Called on NSWorkspace.didWakeNotification.
    func resumePolling() {
        guard isPollingSuspended else { return }
        isPollingSuspended = false
        activeSources.forEach { $0.resumePolling() }
    }

    /// If at least one source is ready, unconnected sources are excluded from the
    /// aggregation, so one stopped remote does not hide local's blocked/done behind
    /// the dashed (disconnected) icon. With zero ready sources the whole fleet is
    /// disconnected.
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

    /// Updates the SSH connection parameters and display name. The visibility and
    /// monitoring ON/OFF flags keep their current values, so a stale editor draft
    /// opened in another window cannot roll back toggles in the settings list or
    /// checkbox operations in the menu.
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

    /// Persists the menu panel checkbox state and applies it to the runtime set. OFF
    /// stops the tunnel but keeps the configuration, so the sourceSections header
    /// remains visible.
    func setRemoteEnabled(id: HerdrSourceID, isEnabled: Bool) throws {
        guard let index = remoteConfigurations.firstIndex(where: { $0.id == id }) else {
            throw RemoteSourceMutationError.sourceNotFound
        }
        var candidate = remoteConfigurations
        candidate[index].isEnabled = isEnabled
        try commit(candidate)
    }

    /// Persists the per-host toggle in the settings Remotes list and applies it to
    /// the runtime set. This flag sits above isEnabled: OFF removes the section from
    /// sourceSections, header included, and stops the tunnel even for a remote with
    /// monitoring ON. isEnabled itself is not rewritten, so turning it back ON lets a
    /// remote that had monitoring ON resume monitoring as-is.
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

    /// Persists a drag reorder in the settings screen. Arguments follow the SwiftUI
    /// onMove convention: destination is the insertion index into the array before
    /// the elements are removed.
    func moveRemote(fromOffsets source: IndexSet, toOffset destination: Int) throws {
        var candidate = remoteConfigurations
        candidate.move(fromOffsets: source, toOffset: destination)
        try commit(candidate)
    }

    func monitoredSource(id: HerdrSourceID) -> MonitoredSource? {
        activeSources.first { $0.id == id }
    }

    /// Remote rows are never handed a call site for this. The sourceID check is
    /// layered here as well, so a miswired view cannot send agent.focus to a remote
    /// herdr.
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
