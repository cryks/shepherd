// Coordinates screen reads for one Herdr endpoint. The owning Store supplies
// the endpoint-pinned AgentReadDataSource and forwards each successful
// session.snapshot. Reads run in the background for every supported pane so
// the excerpt cache is already filled when a menu or Monitor surface opens:
// a pane is read when its snapshot status differs from the last scheduled
// read's status, then re-read at the policy's interval while it stays working
// or blocked. Every read is reduced immediately to an AgentExcerptState; raw
// terminal text is never retained.
//
// The excerpt preference is consulted through the injected policy closure on
// every snapshot tick rather than through a push API: a disabled tick cancels
// in-flight reads and drops the cache, and the next enabled tick rebuilds it.
//
// A screen observation is bracketed by agent.get -> agent.read -> agent.get.
// Publication requires the same pane, terminal, canonical agent, native
// session, agent status, state-change sequence, and agent.get revision on both
// sides. Protocol 17 does not relate pane_read.revision to agent.get.revision;
// Herdr 0.7.5 returns zero for every pane_read source. The equal bracketing
// agent.get revision therefore supplies the extractor's lifecycle revision.
// The sandwich is not an atomic server transaction, but these checks reject
// pane moves, occupant replacement, and status ABA transitions. Late
// completions are also guarded by a monitor epoch and per-record request token
// because the socket client cannot cancel an in-progress POSIX read.

import Foundation
import Observation

/// Read behavior derived from the excerpt preference for one snapshot tick.
struct AgentReadPolicy {
    /// false stops all reads and drops the excerpt cache.
    var isEnabled: Bool
    /// Background re-read cadence for a pane whose status stays working or
    /// blocked; a status change reads without waiting for it.
    var readInterval: Duration
}

@Observable @MainActor
final class AgentReadMonitor {
    private enum ReadReason {
        case snapshot
        case verification

        var allowsVerificationFollowUp: Bool {
            self != .verification
        }
    }

    private enum Locator: Hashable {
        case terminal(String)
        case pane(String)
    }

    private struct RecordKey: Hashable {
        var locator: Locator
        var agentID: String
    }

    private final class Record {
        let key: RecordKey
        var pane: Pane
        var machine: AgentExcerptMachine
        var observedSession: HerdrAgentSession?
        var hasObservedSession = false
        var requestToken: UInt64 = 0
        var task: Task<Void, Never>?
        var needsReadAfterCurrent = false
        /// Snapshot status covered by the most recent scheduled read. nil
        /// forces a read on the next snapshot tick; it marks a new record, a
        /// failed or incoherent read, and a pending settled verification whose
        /// follow-up read could not be self-scheduled.
        var coveredStatus: AgentStatus?
        /// When the most recent read was scheduled. Bounds the periodic
        /// re-read of a pane whose status stays working or blocked.
        var lastReadStart: ContinuousClock.Instant?

        init(key: RecordKey, pane: Pane, machine: AgentExcerptMachine) {
            self.key = key
            self.pane = pane
            self.machine = machine
        }
    }

    private struct Transaction {
        var before: HerdrAgentInfo
        var read: PaneRead
        var after: HerdrAgentInfo
    }

    /// Per-pane state for supported records. Missing entries are loading: they
    /// cover the interval before reconcile creates a record and the fresh
    /// lifecycle after content caches are cleared.
    private(set) var excerptStates: [String: AgentExcerptState] = [:]

    @ObservationIgnored private let dataSource: AgentReadDataSource
    @ObservationIgnored private let verificationDelay: Duration
    @ObservationIgnored private let policy: @MainActor () -> AgentReadPolicy
    @ObservationIgnored private var records: [RecordKey: Record] = [:]
    @ObservationIgnored private var latestPanes: [Pane] = []
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var hasStopped = false

    /// The default policy follows the app-wide excerpt preference; tests
    /// inject a closure to pin enablement and cadence without UserDefaults.
    init(
        dataSource: AgentReadDataSource,
        verificationDelay: Duration = .milliseconds(125),
        policy: @escaping @MainActor () -> AgentReadPolicy = {
            AgentReadPolicy(
                isEnabled: ExcerptSetting.shared.isEnabled,
                readInterval: ExcerptSetting.shared.readInterval.duration
            )
        }
    ) {
        self.dataSource = dataSource
        self.verificationDelay = verificationDelay
        self.policy = policy
    }

    /// Reconciles the monitor with one successful endpoint snapshot.
    ///
    /// The owning Store calls this for every success, even when its display
    /// snapshot is value-equal to the previous one. That repeated boundary is
    /// what permits retry after a transient read failure and the second stable
    /// settled read required by AgentExcerptMachine.
    func update(panes: [Pane]) {
        latestPanes = panes.filter { pane in
            guard Store.shouldTrack(pane), let agentID = pane.agent else {
                return false
            }
            return AgentExcerptMachine.supports(agentID: agentID)
        }
        guard !isSuspended, !hasStopped else { return }
        guard policy().isEnabled else {
            if !records.isEmpty || !excerptStates.isEmpty {
                reset(clearLatestPanes: false)
            }
            return
        }
        reconcile()
    }

    func excerpt(for paneID: String) -> AgentExcerpt? {
        guard case .available(let excerpt) = excerptState(for: paneID) else {
            return nil
        }
        return excerpt
    }

    func excerptState(for paneID: String) -> AgentExcerptState {
        excerptStates[paneID] ?? .loading
    }

    /// Invalidates screen-derived lifecycle state after endpoint loss.
    ///
    /// A reconnect may have missed a whole agent turn, so evidence gathered
    /// before the loss cannot be related to the newly visible screen; the
    /// records rebuild from the next successful snapshot.
    func sourceUnavailable() {
        reset(clearLatestPanes: true)
    }

    /// Cancels reads during system sleep. Values may remain mounted while the
    /// system is asleep, but resume clears lifecycle evidence before reading:
    /// agents on a remote host can finish whole turns while this Mac sleeps.
    func suspend() {
        guard !isSuspended, !hasStopped else { return }
        isSuspended = true
        invalidateRequests()
    }

    func resume() {
        guard isSuspended, !hasStopped else { return }
        isSuspended = false
        reset(clearLatestPanes: false)
        reconcile()
    }

    func stop() {
        guard !hasStopped else { return }
        hasStopped = true
        reset(clearLatestPanes: true)
    }

    private func reconcile() {
        guard !isSuspended, !hasStopped else { return }

        var remaining = records
        var next: [RecordKey: Record] = [:]
        var nextExcerptStates: [String: AgentExcerptState] = [:]

        for pane in latestPanes.sorted(by: { $0.paneId < $1.paneId }) {
            guard let key = recordKey(for: pane),
                  let machine = AgentExcerptMachine(agentID: key.agentID) else {
                continue
            }
            // Duplicate terminal IDs indicate an incoherent snapshot. Keeping
            // only the first prevents one screen from being attributed to two
            // visible rows until the next successful snapshot resolves it.
            guard next[key] == nil else { continue }

            let record: Record
            let excerptState: AgentExcerptState
            if let existing = remaining.removeValue(forKey: key) {
                record = existing
                excerptState = excerptStates[existing.pane.paneId] ?? .loading
            } else {
                record = Record(key: key, pane: pane, machine: machine)
                excerptState = .loading
            }
            record.pane = pane
            // State follows a stable terminal record across a pane move. A new
            // Record with the same pane ID starts loading instead of inheriting
            // the previous occupant's text.
            nextExcerptStates[pane.paneId] = excerptState
            next[key] = record
        }

        for record in remaining.values {
            cancel(record)
        }
        records = next
        if excerptStates != nextExcerptStates {
            excerptStates = nextExcerptStates
        }

        records.values.forEach(scheduleFromSnapshot)
    }

    /// Decides whether one snapshot tick reads this record's screen.
    ///
    /// Herdr's pane revision does not advance for each terminal write, so
    /// content changes are invisible in the snapshot itself. The triggers are:
    /// a status change since the last scheduled read (including a cleared
    /// coveredStatus after a failure) and the periodic re-read while the
    /// status stays working or blocked.
    private func scheduleFromSnapshot(_ record: Record) {
        let status = record.pane.agentStatus
        if record.coveredStatus != status {
            schedule(record, reason: .snapshot)
            return
        }
        guard status == .working || status == .blocked else { return }
        let readInterval = policy().readInterval
        let hasIntervalElapsed = record.lastReadStart.map {
            $0.duration(to: ContinuousClock().now) >= readInterval
        } ?? true
        if hasIntervalElapsed {
            schedule(record, reason: .snapshot)
        }
    }

    private func schedule(_ record: Record, reason: ReadReason) {
        guard !isSuspended, !hasStopped else { return }
        if record.task != nil {
            record.needsReadAfterCurrent = true
            return
        }

        record.coveredStatus = record.pane.agentStatus
        record.lastReadStart = ContinuousClock().now
        record.requestToken &+= 1
        let token = record.requestToken
        let requestEpoch = epoch
        let paneID = record.pane.paneId
        let delay = reason == .verification ? verificationDelay : .zero

        record.task = Task { @MainActor [weak self, weak record] in
            guard let self, let record else { return }
            if delay > .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
            }
            guard self.isCurrent(record, epoch: requestEpoch, token: token) else {
                return
            }

            do {
                let before = try await self.dataSource.get(paneID)
                guard self.isCurrent(record, epoch: requestEpoch, token: token) else {
                    return
                }
                let read = try await self.dataSource.readVisible(before.agent.paneId)
                guard self.isCurrent(record, epoch: requestEpoch, token: token) else {
                    return
                }
                let after = try await self.dataSource.get(read.read.paneId)
                guard self.isCurrent(record, epoch: requestEpoch, token: token) else {
                    return
                }
                self.complete(
                    Transaction(
                        before: before.agent,
                        read: read.read,
                        after: after.agent
                    ),
                    for: record,
                    reason: reason
                )
            } catch {
                guard self.isCurrent(record, epoch: requestEpoch, token: token) else {
                    return
                }
                self.fail(record)
            }
        }
    }

    private func complete(
        _ transaction: Transaction,
        for record: Record,
        reason: ReadReason
    ) {
        let appliedCoherently = apply(transaction, to: record)
        record.task = nil
        if !appliedCoherently {
            // An incoherent frame carries no extractor evidence; clearing the
            // covered status makes the next snapshot tick read again instead
            // of waiting for another status change.
            record.coveredStatus = nil
        }

        if record.needsReadAfterCurrent {
            record.needsReadAfterCurrent = false
            schedule(record, reason: .snapshot)
        } else if appliedCoherently, record.machine.requiresVerificationRead {
            if reason.allowsVerificationFollowUp {
                schedule(record, reason: .verification)
            } else {
                // A verification read cannot chain another one. Hand the
                // still-pending candidate to the next snapshot tick.
                record.coveredStatus = nil
            }
        }
    }

    /// Returns true when the transaction supplied a coherent extractor frame.
    private func apply(_ transaction: Transaction, to record: Record) -> Bool {
        let before = transaction.before
        let read = transaction.read
        let after = transaction.after

        guard matchesRecord(before, record: record),
              sameOccupantIdentity(before, after),
              read.paneId == before.paneId,
              read.paneId == after.paneId,
              read.workspaceId == before.workspaceId,
              read.workspaceId == after.workspaceId,
              read.tabId == before.tabId,
              read.tabId == after.tabId else {
            resetMachine(record)
            return false
        }

        if record.hasObservedSession,
           record.observedSession != before.agentSession {
            resetMachine(record)
        }
        record.observedSession = before.agentSession
        record.hasObservedSession = true

        if before.agentStatus != after.agentStatus {
            _ = record.machine.ingest(AgentExcerptInput(
                statusBeforeRead: before.agentStatus,
                statusAfterRead: after.agentStatus,
                revision: before.revision,
                text: read.text
            ))
            return false
        }

        guard before.stateChangeSeq == after.stateChangeSeq else {
            // Equal endpoint statuses can hide an ABA transition. A fresh
            // machine is safer than relating this screen to the old turn.
            resetMachine(record)
            return false
        }

        guard let observationRevision = bracketedObservationRevision(
                  before: before.revision,
                  after: after.revision
              ),
              record.pane.paneId == after.paneId,
              record.pane.agentStatus == after.agentStatus,
              record.pane.revision.map({ $0 <= observationRevision }) ?? true else {
            return false
        }

        let update = record.machine.ingest(AgentExcerptInput(
            statusBeforeRead: before.agentStatus,
            statusAfterRead: after.agentStatus,
            revision: observationRevision,
            text: read.text
        ))
        apply(update, to: record)
        return true
    }

    private func matchesRecord(_ info: HerdrAgentInfo, record: Record) -> Bool {
        guard info.paneId == record.pane.paneId,
              info.agent?.lowercased() == record.key.agentID else {
            return false
        }
        if case .terminal(let terminalID) = record.key.locator {
            return info.terminalId == terminalID
        }
        return true
    }

    private func sameOccupantIdentity(
        _ before: HerdrAgentInfo,
        _ after: HerdrAgentInfo
    ) -> Bool {
        before.agent?.lowercased() == after.agent?.lowercased() &&
            before.terminalId == after.terminalId &&
            before.agentSession == after.agentSession
    }

    /// Projects one coherent extractor mutation into the row state. `keep`
    /// preserves an already loaded line, including its diagnostic revision;
    /// only a fresh loading record needs the machine's verification flag to
    /// distinguish a pending second read from a completed empty observation.
    private func apply(
        _ update: AgentExcerptUpdate,
        to record: Record
    ) {
        let paneID = record.pane.paneId
        switch update {
        case .replace(let excerpt):
            setExcerptState(.available(excerpt), for: paneID)
        case .remove:
            setExcerptState(
                record.machine.requiresVerificationRead ? .loading : .empty,
                for: paneID
            )
        case .keep:
            guard excerptStates[paneID] == .loading else { return }
            if let excerpt = record.machine.excerpt {
                setExcerptState(.available(excerpt), for: paneID)
            } else if !record.machine.requiresVerificationRead {
                setExcerptState(.empty, for: paneID)
            }
        }
    }

    private func setExcerptState(
        _ state: AgentExcerptState,
        for paneID: String
    ) {
        if excerptStates[paneID] != state {
            excerptStates[paneID] = state
        }
    }

    private func fail(_ record: Record) {
        record.task = nil
        // Retry from the next snapshot tick rather than waiting for another
        // status change.
        record.coveredStatus = nil
        if record.needsReadAfterCurrent {
            record.needsReadAfterCurrent = false
            schedule(record, reason: .snapshot)
        }
    }

    private func resetMachine(_ record: Record) {
        guard let machine = AgentExcerptMachine(agentID: record.key.agentID) else {
            return
        }
        record.machine = machine
        record.observedSession = nil
        record.hasObservedSession = false
        record.coveredStatus = nil
        setExcerptState(.loading, for: record.pane.paneId)
    }

    private func bracketedObservationRevision(
        before: UInt64,
        after: UInt64
    ) -> UInt64? {
        before == after ? after : nil
    }

    private func recordKey(for pane: Pane) -> RecordKey? {
        guard let agentID = pane.agent?.lowercased(),
              AgentExcerptMachine.supports(agentID: agentID) else {
            return nil
        }
        let locator: Locator
        if let terminalID = pane.terminalId, !terminalID.isEmpty {
            locator = .terminal(terminalID)
        } else {
            locator = .pane(pane.paneId)
        }
        return RecordKey(locator: locator, agentID: agentID)
    }

    private func isCurrent(
        _ record: Record,
        epoch: UInt64,
        token: UInt64
    ) -> Bool {
        !Task.isCancelled &&
            self.epoch == epoch &&
            record.requestToken == token &&
            records[record.key] === record &&
            !isSuspended &&
            !hasStopped
    }

    private func cancel(_ record: Record) {
        record.requestToken &+= 1
        record.task?.cancel()
        record.task = nil
        record.needsReadAfterCurrent = false
    }

    private func invalidateRequests() {
        epoch &+= 1
        records.values.forEach(cancel)
    }

    private func reset(clearLatestPanes: Bool) {
        invalidateRequests()
        records.removeAll()
        excerptStates.removeAll()
        if clearLatestPanes {
            latestPanes.removeAll()
        }
    }
}
