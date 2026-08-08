// A notification here stands for live attention, not history: every path that
// ends an attention state also removes its notification.

import Foundation
import Observation

// HerdrSourceID survives edits and monitoring toggles, so it cannot tell a
// reconnect from a rebuilt runtime that must take a fresh baseline.
struct AttentionSourceGenerationID: Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct AttentionNotificationID: RawRepresentable, Hashable, Sendable {
    // Lets the notification layer find requests left behind by an earlier
    // process, whose IDs this process no longer holds in memory.
    static let managedPrefix = "attention.v1."

    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// Terminal IDs come first because they survive pane moves; a pane ID is the
// fallback only while terminal metadata is absent.
struct AttentionAgentLocator: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case terminal(String)
        case pane(String)
    }

    let sourceID: HerdrSourceID
    let target: Target
}

// The three strings are fully rendered from the user's templates, so the
// delivery layer adds no text of its own.
struct AttentionNotice: Equatable, Sendable {
    let id: AttentionNotificationID
    // Only for looking up the pane's excerpt before delivery. It is never
    // persisted in the notification payload, because a click re-resolves the
    // current pane through destination(for:).
    let sourcePaneID: SourcePaneID
    let threadIdentifier: String
    let title: String
    let subtitle: String
    let body: String

    init(
        id: AttentionNotificationID,
        sourcePaneID: SourcePaneID,
        threadIdentifier: String,
        title: String,
        subtitle: String,
        body: String
    ) {
        self.id = id
        self.sourcePaneID = sourcePaneID
        self.threadIdentifier = threadIdentifier
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }
}

enum AttentionEffect: Equatable, Sendable {
    case deliver(AttentionNotice)
    case remove(AttentionNotificationID)
    // Scoped to AttentionNotificationID.managedPrefix, never to unrelated app
    // notifications.
    case removeAll
}

struct AttentionDestination: Equatable {
    let sourceID: HerdrSourceID
    let isRemote: Bool
    let pane: Pane
}

// A source missing from `sources` was removed on purpose; an unavailable one is
// still monitored, so the reducer must keep its last known agents.
struct AttentionFleetObservation: Equatable {
    var sources: [AttentionSourceObservation]

    // Text is rendered here because templates (RowLayoutSetting) and their
    // variables (FleetStore.rowContext) are MainActor Observation state that the
    // pure reducer cannot touch.
    @MainActor
    init(store: FleetStore) {
        let templates = RowLayoutSetting.shared.layout.notification
        sources = store.activeSources.map { source in
            let availability: AttentionSourceObservation.Availability
            if source.availableSnapshot == nil {
                availability = .unavailable
            } else {
                let agents = source.workspaceGroups
                    .flatMap { $0.panes }
                    .map { pane in
                        Self.observation(
                            of: pane,
                            sourceID: source.id,
                            store: store,
                            templates: templates
                        )
                    }
                availability = .ready(agents)
            }
            return AttentionSourceObservation(
                sourceID: source.id,
                generationID: source.attentionGenerationID,
                isRemote: source.isRemote,
                availability: availability
            )
        }
    }

    init(sources: [AttentionSourceObservation]) {
        self.sources = sources
    }

    // `{excerpt}` deliberately resolves to empty here: the read for this turn is
    // still in flight at the transition, so AttentionNoticeStager renders the
    // notice a second time once the text lands.
    @MainActor
    private static func observation(
        of pane: Pane,
        sourceID: HerdrSourceID,
        store: FleetStore,
        templates: NotificationTemplates
    ) -> AttentionAgentObservation {
        let context = store.rowContext(
            for: SourcePaneID(sourceID: sourceID, paneID: pane.paneId)
        )
        let fields = notificationFields(templates) { name in
            context?.textTemplateValue(for: name)
        }
        return AttentionAgentObservation(
            pane: pane,
            title: fields.title,
            subtitle: fields.subtitle,
            body: fields.body
        )
    }

    // nil when the pane has left the snapshot: the caller then keeps the text
    // rendered at the transition instead of a banner built from nothing.
    @MainActor
    static func rendered(
        _ notice: AttentionNotice,
        excerpt: String,
        store: FleetStore
    ) -> AttentionNotice? {
        guard let context = store.rowContext(for: notice.sourcePaneID) else { return nil }
        let fields = notificationFields(RowLayoutSetting.shared.layout.notification) { name in
            name == "excerpt" ? .text(excerpt) : context.textTemplateValue(for: name)
        }
        return AttentionNotice(
            id: notice.id,
            sourcePaneID: notice.sourcePaneID,
            threadIdentifier: notice.threadIdentifier,
            title: fields.title,
            subtitle: fields.subtitle,
            body: fields.body
        )
    }

    // macOS accepts an all-empty banner without complaint, hence the fallback to
    // the built-in templates, and hence promoting a line into an empty title:
    // the title is the one field macOS always shows.
    static func notificationFields(
        _ templates: NotificationTemplates,
        _ resolve: (String) -> TemplateValue?
    ) -> (title: String, subtitle: String, body: String) {
        var fields = render(templates, resolve)
        if fields.title.isEmpty, fields.subtitle.isEmpty, fields.body.isEmpty {
            fields = render(RowLayout.default.notification, resolve)
        }
        if fields.title.isEmpty {
            if fields.subtitle.isEmpty {
                fields.title = fields.body.isEmpty ? "" : fields.body.removeFirst()
            } else {
                fields.title = fields.subtitle
                fields.subtitle = ""
            }
        }
        return (
            title: fields.title,
            subtitle: fields.subtitle,
            body: fields.body.joined(separator: "\n")
        )
    }

    // The body stays split into lines so the caller can promote one to the
    // title. Nothing is trimmed here because renderText already trims each
    // render, so an emptied template yields the empty string on its own.
    private static func render(
        _ templates: NotificationTemplates,
        _ resolve: (String) -> TemplateValue?
    ) -> (title: String, subtitle: String, body: [String]) {
        (
            title: templates.title.renderText(resolve),
            subtitle: templates.subtitle.renderText(resolve),
            body: templates.body
                .map { $0.template.renderText(resolve) }
                .filter { !$0.isEmpty }
        )
    }
}

struct AttentionSourceObservation: Equatable {
    enum Availability: Equatable {
        case unavailable
        case ready([AttentionAgentObservation])
    }

    var sourceID: HerdrSourceID
    var generationID: AttentionSourceGenerationID
    var isRemote: Bool
    var availability: Availability
}

// The reducer decides on pane status alone and never compares these strings, so
// editing a template cannot re-alert an attention state the user already saw.
struct AttentionAgentObservation: Equatable {
    var pane: Pane
    var title: String
    var subtitle: String
    var body: String
}

// Kept free of AppKit, UserNotifications, UserDefaults, Observation, clocks, and
// concurrency so attention rules can be tested as plain values.
struct AttentionStateMachine {
    private struct SourceState {
        var generationID: AttentionSourceGenerationID
        var isRemote: Bool
        var isAvailable: Bool
        var hasBaseline: Bool
        var agents: [AgentRecord]
    }

    private struct AgentRecord {
        // Never rewritten, not even when terminal metadata appears after a
        // pane-only baseline, so a live notification stays addressable.
        let notificationID: AttentionNotificationID
        var terminalID: String?
        var paneID: String
        var observation: AttentionAgentObservation
        // A baseline can hold blocked/done agents that own no notification, so
        // ownership cannot be inferred from status.
        var ownsNotice: Bool
    }

    private(set) var isEnabled = false
    private var hasStarted = false
    private var sources: [HerdrSourceID: SourceState] = [:]

    // removeAll on start clears notifications a previous crash left in
    // Notification Center.
    mutating func start(
        enabled: Bool,
        fleet: AttentionFleetObservation
    ) -> [AttentionEffect] {
        guard !hasStarted else { return [] }
        hasStarted = true
        isEnabled = enabled
        sources.removeAll()
        if enabled {
            baseline(fleet)
        }
        return [.removeAll]
    }

    // Re-enabling baselines the current fleet so attention that predates the
    // toggle does not arrive as a new transition.
    mutating func setEnabled(
        _ enabled: Bool,
        fleet: AttentionFleetObservation
    ) -> [AttentionEffect] {
        guard hasStarted, isEnabled != enabled else { return [] }
        isEnabled = enabled
        sources.removeAll()
        if enabled {
            baseline(fleet)
            return []
        }
        return [.removeAll]
    }

    // Only a ready snapshot proves a status change or a disappearance, so an
    // unavailable source keeps its agents until a reconnect can be compared.
    mutating func ingest(_ fleet: AttentionFleetObservation) -> [AttentionEffect] {
        guard hasStarted, isEnabled else { return [] }

        var effects: [AttentionEffect] = []
        let observedIDs = Set(fleet.sources.map(\.sourceID))
        let removedIDs = sources.keys
            .filter { !observedIDs.contains($0) }
            .sorted { $0.rawValue < $1.rawValue }
        for sourceID in removedIDs {
            if let removed = sources.removeValue(forKey: sourceID) {
                effects.append(contentsOf: removalEffects(for: removed))
            }
        }

        for observation in fleet.sources {
            guard var state = sources[observation.sourceID] else {
                sources[observation.sourceID] = makeInitialState(observation)
                continue
            }

            guard state.generationID == observation.generationID else {
                effects.append(contentsOf: removalEffects(for: state))
                sources[observation.sourceID] = makeInitialState(observation)
                continue
            }

            state.isRemote = observation.isRemote
            switch observation.availability {
            case .unavailable:
                state.isAvailable = false
            case .ready(let agents):
                state.isAvailable = true
                if state.hasBaseline {
                    effects.append(contentsOf: reconcile(
                        agents,
                        sourceID: observation.sourceID,
                        state: &state
                    ))
                } else {
                    state.hasBaseline = true
                    state.agents = baselineRecords(
                        agents,
                        sourceID: observation.sourceID,
                        generationID: observation.generationID
                    )
                }
            }
            sources[observation.sourceID] = state
        }
        return effects
    }

    // removeAll rather than per-record removes: a request may exist in
    // Notification Center that this reducer no longer holds.
    mutating func stop() -> [AttentionEffect] {
        guard hasStarted else { return [] }
        hasStarted = false
        isEnabled = false
        sources.removeAll()
        return [.removeAll]
    }

    // Resolves against the latest snapshot instead of the pane seen at delivery,
    // and skips unavailable sources, so a click never targets a stale pane.
    func destination(for notificationID: AttentionNotificationID) -> AttentionDestination? {
        for (sourceID, source) in sources where source.isAvailable {
            guard let record = source.agents.first(where: {
                $0.notificationID == notificationID
                    && $0.ownsNotice
                    && $0.observation.pane.agentStatus.needsAttention
            }) else { continue }
            return AttentionDestination(
                sourceID: sourceID,
                isRemote: source.isRemote,
                pane: record.observation.pane
            )
        }
        return nil
    }

    private mutating func baseline(_ fleet: AttentionFleetObservation) {
        for observation in fleet.sources {
            sources[observation.sourceID] = makeInitialState(observation)
        }
    }

    private func makeInitialState(_ observation: AttentionSourceObservation) -> SourceState {
        switch observation.availability {
        case .unavailable:
            return SourceState(
                generationID: observation.generationID,
                isRemote: observation.isRemote,
                isAvailable: false,
                hasBaseline: false,
                agents: []
            )
        case .ready(let agents):
            return SourceState(
                generationID: observation.generationID,
                isRemote: observation.isRemote,
                isAvailable: true,
                hasBaseline: true,
                agents: baselineRecords(
                    agents,
                    sourceID: observation.sourceID,
                    generationID: observation.generationID
                )
            )
        }
    }

    private func baselineRecords(
        _ agents: [AttentionAgentObservation],
        sourceID: HerdrSourceID,
        generationID: AttentionSourceGenerationID
    ) -> [AgentRecord] {
        agents.map { agent in
            makeRecord(
                agent,
                sourceID: sourceID,
                generationID: generationID,
                ownsNotice: false
            )
        }
    }

    private func reconcile(
        _ currentAgents: [AttentionAgentObservation],
        sourceID: HerdrSourceID,
        state: inout SourceState
    ) -> [AttentionEffect] {
        let previous = state.agents
        var unmatched = Set(previous.indices)
        var next: [AgentRecord] = []
        var effects: [AttentionEffect] = []

        for current in currentAgents {
            if let index = matchingRecordIndex(
                for: current.pane,
                in: previous,
                unmatched: unmatched
            ) {
                unmatched.remove(index)
                var record = previous[index]
                let previousStatus = record.observation.pane.agentStatus
                let currentStatus = current.pane.agentStatus

                if previousStatus != currentStatus {
                    if currentStatus.needsAttention {
                        effects.append(.deliver(makeNotice(
                            id: record.notificationID,
                            sourceID: sourceID,
                            agent: current
                        )))
                        record.ownsNotice = true
                    } else {
                        if record.ownsNotice {
                            effects.append(.remove(record.notificationID))
                        }
                        record.ownsNotice = false
                    }
                }

                if let terminalID = current.pane.terminalId {
                    record.terminalID = terminalID
                }
                record.paneID = current.pane.paneId
                record.observation = current
                next.append(record)
            } else {
                var record = makeRecord(
                    current,
                    sourceID: sourceID,
                    generationID: state.generationID,
                    ownsNotice: false
                )
                if current.pane.agentStatus.needsAttention {
                    effects.append(.deliver(makeNotice(
                        id: record.notificationID,
                        sourceID: sourceID,
                        agent: current
                    )))
                    record.ownsNotice = true
                }
                next.append(record)
            }
        }

        for index in unmatched.sorted() where previous[index].ownsNotice {
            effects.append(.remove(previous[index].notificationID))
        }
        state.agents = next
        return effects
    }

    private func matchingRecordIndex(
        for pane: Pane,
        in records: [AgentRecord],
        unmatched: Set<Int>
    ) -> Int? {
        if let terminalID = pane.terminalId {
            if let index = unmatched.sorted().first(where: {
                records[$0].terminalID == terminalID
            }) {
                return index
            }
            // Adopt a pane-only record only when it carries no terminal identity:
            // the same pane ID under two terminal IDs means two different agents.
            return unmatched.sorted().first(where: {
                records[$0].terminalID == nil && records[$0].paneID == pane.paneId
            })
        }
        return unmatched.sorted().first(where: {
            records[$0].paneID == pane.paneId
        })
    }

    private func makeRecord(
        _ agent: AttentionAgentObservation,
        sourceID: HerdrSourceID,
        generationID: AttentionSourceGenerationID,
        ownsNotice: Bool
    ) -> AgentRecord {
        let locator: AttentionAgentLocator
        if let terminalID = agent.pane.terminalId {
            locator = AttentionAgentLocator(
                sourceID: sourceID,
                target: .terminal(terminalID)
            )
        } else {
            locator = AttentionAgentLocator(
                sourceID: sourceID,
                target: .pane(agent.pane.paneId)
            )
        }
        return AgentRecord(
            notificationID: Self.notificationID(
                generationID: generationID,
                locator: locator
            ),
            terminalID: agent.pane.terminalId,
            paneID: agent.pane.paneId,
            observation: agent,
            ownsNotice: ownsNotice
        )
    }

    private func removalEffects(for source: SourceState) -> [AttentionEffect] {
        source.agents.compactMap { record in
            record.ownsNotice ? .remove(record.notificationID) : nil
        }
    }

    // Text comes from the transition's own observation, so a template edit or a
    // rename after delivery leaves the live banner alone.
    private func makeNotice(
        id: AttentionNotificationID,
        sourceID: HerdrSourceID,
        agent: AttentionAgentObservation
    ) -> AttentionNotice {
        AttentionNotice(
            id: id,
            sourcePaneID: SourcePaneID(
                sourceID: sourceID,
                paneID: agent.pane.paneId
            ),
            threadIdentifier: Self.threadIdentifier(sourceID: sourceID),
            title: agent.title,
            subtitle: agent.subtitle,
            body: agent.body
        )
    }

    private static func notificationID(
        generationID: AttentionSourceGenerationID,
        locator: AttentionAgentLocator
    ) -> AttentionNotificationID {
        let targetTag: String
        let targetValue: String
        switch locator.target {
        case .terminal(let value):
            targetTag = "terminal"
            targetValue = value
        case .pane(let value):
            targetTag = "pane"
            targetValue = value
        }
        return AttentionNotificationID(
            rawValue: AttentionNotificationID.managedPrefix
                + "\(generationID.rawValue.uuidString.lowercased())."
                + "\(encoded(locator.sourceID.rawValue))."
                + "\(targetTag).\(encoded(targetValue))"
        )
    }

    private static func threadIdentifier(sourceID: HerdrSourceID) -> String {
        "attention.source.v1.\(encoded(sourceID.rawValue))"
    }

    // Base64 never contains '.', the field separator above, so arbitrary Herdr
    // IDs cannot make two different identifiers collapse into one string.
    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

private extension AgentStatus {
    var needsAttention: Bool {
        self == .blocked || self == .done
    }
}

// Effects are emitted synchronously on MainActor; the sink is injected so the
// live service can queue platform work while tests just record values.
@MainActor
final class AttentionMonitor {
    private weak var store: FleetStore?
    private var machine = AttentionStateMachine()
    private let effectHandler: @MainActor ([AttentionEffect]) -> Void
    private var hasStarted = false
    private var hasStopped = false

    init(
        store: FleetStore,
        effectHandler: @escaping @MainActor ([AttentionEffect]) -> Void
    ) {
        self.store = store
        self.effectHandler = effectHandler
    }

    // Must run before FleetStore starts polling. Observation is armed before the
    // effects reach the sink, so work done by the sink cannot mutate the fleet
    // unobserved.
    func start(enabled: Bool) {
        guard !hasStarted, !hasStopped, let store else { return }
        hasStarted = true
        let effects = machine.start(
            enabled: enabled,
            fleet: AttentionFleetObservation(store: store)
        )
        armObservation()
        emit(effects)
    }

    func setEnabled(_ enabled: Bool) {
        guard hasStarted, !hasStopped, let store else { return }
        emit(machine.setEnabled(
            enabled,
            fleet: AttentionFleetObservation(store: store)
        ))
    }

    func stop() {
        guard hasStarted, !hasStopped else { return }
        hasStopped = true
        hasStarted = false
        emit(machine.stop())
    }

    func destination(for notificationID: AttentionNotificationID) -> AttentionDestination? {
        machine.destination(for: notificationID)
    }

    private func armObservation() {
        guard hasStarted, !hasStopped, let store else { return }
        withObservationTracking {
            _ = AttentionFleetObservation(store: store)
        } onChange: { [weak self] in
            // Observation calls onChange on the writer's executor before the
            // mutation lands; one MainActor hop is needed to read the new value.
            Task { @MainActor [weak self] in
                self?.consumeObservedChange()
            }
        }
    }

    private func consumeObservedChange() {
        guard hasStarted, !hasStopped, let store else { return }
        let observation = AttentionFleetObservation(store: store)
        // Re-arm before calling the sink: no suspension sits between the capture
        // and the registration, so no MainActor write can slip through untracked.
        armObservation()
        emit(machine.ingest(observation))
    }

    private func emit(_ effects: [AttentionEffect]) {
        guard !effects.isEmpty else { return }
        effectHandler(effects)
    }
}
