// Every screen observation is bracketed as agent.get -> agent.read ->
// agent.get. The sandwich is not an atomic server transaction, so an
// observation is used only when both AgentInfo values agree on pane, terminal,
// agent, session, status, state-change sequence, and revision; that rejects
// pane moves, occupant replacement, and ABA status transitions.
//
// Protocol 19 does not relate pane_read.revision to agent.get.revision, and
// Herdr 0.8.0 returns zero for every pane_read source, so the equal bracketing
// agent.get revision is the only usable lifecycle revision. The pane revision
// in a snapshot also does not advance per terminal write, which makes screen
// changes invisible there: reads are driven by status changes plus a periodic
// re-read instead.
//
// The socket client cannot cancel an in-progress POSIX read, so a late
// completion is discarded through a monitor epoch and a per-record token
// rather than by cancelling the request.

import Foundation
import Observation

struct AgentReadPolicy {
    var isEnabled: Bool
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
        // nil is the "read on the next tick" sentinel, set for a new record and
        // whenever a read produced no usable evidence.
        var coveredStatus: AgentStatus?
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

    private(set) var excerptStates: [String: AgentExcerptState] = [:]

    @ObservationIgnored private let dataSource: AgentReadDataSource
    @ObservationIgnored private let verificationDelay: Duration
    @ObservationIgnored private let policy: @MainActor () -> AgentReadPolicy
    @ObservationIgnored private var records: [RecordKey: Record] = [:]
    @ObservationIgnored private var latestPanes: [Pane] = []
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var isSuspended = false
    @ObservationIgnored private var hasStopped = false

    // The preference is pulled through a closure on every tick rather than
    // pushed, so tests can pin it without UserDefaults.
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

    // The Store calls this on every successful snapshot, even a value-equal
    // one. Those repeated ticks are what drive retry after a failed read and
    // the second stable read AgentExcerptMachine needs.
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

    // A reconnect may have missed a whole agent turn, so evidence from before
    // the loss cannot be related to the screen that is visible now.
    func sourceUnavailable() {
        reset(clearLatestPanes: true)
    }

    // Resume drops lifecycle evidence instead of continuing from it: an agent
    // on a remote host can finish whole turns while this Mac sleeps.
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
            // A duplicate key means an incoherent snapshot; keeping the first
            // stops one screen from being shown on two rows until it resolves.
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
            // Text is carried by the terminal-keyed record, so it follows a
            // pane move and a new occupant of the same pane ID starts loading.
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

    private func scheduleFromSnapshot(_ record: Record) {
        // A scrolled viewport shows history while the CLI keeps drawing at the
        // tail, so a visible read would pass old rows off as current. Leaving
        // coveredStatus alone makes the first tick back at the tail read.
        if (record.pane.scrollOffsetFromBottom ?? 0) > 0 { return }
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
            // No evidence was gathered, so read again on the next tick instead
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
                // A verification read must not chain another one, so the
                // pending candidate goes to the next snapshot tick.
                record.coveredStatus = nil
            }
        }
    }

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
            // Equal statuses on both sides can still hide an ABA transition,
            // and this screen would then belong to a turn already gone.
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

    // Only a still-loading row consults requiresVerificationRead: it is what
    // separates a pending second read from a finished empty observation.
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
        // Retry on the next tick instead of waiting for a status change.
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
