// Derives per-agent attention transitions from FleetStore snapshots without
// delivering macOS notifications itself. The pure AttentionStateMachine owns the
// last successful snapshot of each monitored source generation. Temporary source
// unavailability keeps that state, while an intentionally removed or replaced
// runtime clears it. AttentionMonitor is the app-owned Observation adapter: it
// captures the complete fleet after a tracked change and forwards value effects to
// an injected sink.
//
// A notification represents live attention rather than history. Only blocked and
// done transitions deliver. Returning to working, idle, or unknown, disappearing
// from a successful snapshot, disabling notifications, removing a source, and app
// termination remove the corresponding live notification. The first ready snapshot
// after launch, source creation, runtime replacement, or notification re-enable is
// a baseline and never delivers.
//
// Notification text is rendered where the fleet is captured: an observation
// carries the three finished strings, and the reducer only copies them into the
// notice it emits. Templates live in RowLayoutSetting and resolve through
// FleetStore.rowContext, both of which are MainActor Observation state that the
// reducer must stay free of. Identity — request IDs, thread identifiers, dedup,
// removal — is derived from source, generation, and agent locator alone, so an
// edited template never re-alerts an attention state the user already saw.

import Foundation
import Observation

/// Identifies one in-memory MonitoredSource runtime. HerdrSourceID survives edits
/// and monitoring toggle cycles, so it cannot by itself distinguish a reconnect
/// from a newly constructed endpoint that must take a fresh baseline.
struct AttentionSourceGenerationID: Hashable, Sendable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Stable request identifier shared by the state machine, notification delivery,
/// and click routing. The raw value is safe to pass directly to
/// UNNotificationRequest; the notification layer can use managedPrefix when
/// removing requests left by an earlier process.
struct AttentionNotificationID: RawRepresentable, Hashable, Sendable {
    static let managedPrefix = "attention.v1."

    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Content-independent identity observed for an agent. Terminal IDs are preferred
/// because they survive pane moves. Pane IDs are used only while terminal metadata
/// is absent.
struct AttentionAgentLocator: Hashable, Sendable {
    enum Target: Hashable, Sendable {
        case terminal(String)
        case pane(String)
    }

    let sourceID: HerdrSourceID
    let target: Target
}

/// Platform-neutral notification request. title, subtitle, and body arrive
/// already rendered from the user's notification templates, so the delivery
/// layer adds no text of its own and no localized status string is part of this
/// contract; the glyph a default banner opens with comes from the title
/// template's `{status_emoji}`. sourcePaneID names the agent pane observed at the
/// transition; AttentionNoticeStager uses it to look up that pane's current
/// excerpt before the notice reaches Notification Center. It is not persisted
/// into the notification payload, and click routing keeps resolving the current
/// pane through AttentionMonitor.destination(for:).
struct AttentionNotice: Equatable, Sendable {
    let id: AttentionNotificationID
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

/// Effects the live notification service applies in order. remove clears both
/// pending and delivered requests for the ID; removeAll is scoped by
/// AttentionNotificationID.managedPrefix rather than unrelated app notifications.
enum AttentionEffect: Equatable, Sendable {
    case deliver(AttentionNotice)
    case remove(AttentionNotificationID)
    case removeAll
}

/// Current click destination. It is returned only while the source has a ready
/// snapshot and the agent still exists, so callers never send focus or reveal to a
/// stale pane. Remote destinations open and reveal in Monitor; local destinations
/// may be passed to FleetStore.focus.
struct AttentionDestination: Equatable {
    let sourceID: HerdrSourceID
    let isRemote: Bool
    let pane: Pane
}

/// Complete fleet value consumed by AttentionStateMachine. A source omitted from
/// sources was intentionally removed from activeSources. An unavailable source is
/// still monitored but has no trustworthy current snapshot, so its previous agent
/// state and notification ownership must be retained.
struct AttentionFleetObservation: Equatable {
    var sources: [AttentionSourceObservation]

    /// Captures the same filtered parent-agent population used by the menu and
    /// Monitor, and renders each pane's notification text while the templates and
    /// the fleet are both readable. Templates come from RowLayoutSetting and
    /// their variables from FleetStore.rowContext — MainActor Observation state,
    /// which is why the strings are produced here and not in the reducer.
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

    /// Renders one pane's notification fields. Variables resolve through
    /// AgentRowContext.textTemplateValue, so `{agent_icon}` and `{excerpt}`
    /// render empty — AttentionNoticeStager is the one place that puts an
    /// excerpt into a banner. A pane with no row context resolves every variable
    /// to empty and therefore reaches the fields rule with nothing to say.
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

    /// Renders the three fields and settles what an empty one means. macOS shows
    /// a banner with an empty title, subtitle, and body without complaint, so an
    /// all-empty render — a user who cleared every template, or a pane whose
    /// variables all resolved empty — falls back to the built-in templates. An
    /// empty title is then filled from the subtitle, else the body, and the field
    /// it came from is cleared, because the title is the line macOS always shows.
    private static func notificationFields(
        _ templates: NotificationTemplates,
        _ resolve: (String) -> TemplateValue?
    ) -> (title: String, subtitle: String, body: String) {
        var fields = render(templates, resolve)
        if fields.title.isEmpty, fields.subtitle.isEmpty, fields.body.isEmpty {
            fields = render(RowLayout.default.notification, resolve)
        }
        if fields.title.isEmpty {
            if fields.subtitle.isEmpty {
                fields.title = fields.body
                fields.body = ""
            } else {
                fields.title = fields.subtitle
                fields.subtitle = ""
            }
        }
        return fields
    }

    /// No field is trimmed here: renderText already drops the whole render's
    /// leading and trailing whitespace, so a template left with nothing but a
    /// discarded separator group yields the empty string.
    private static func render(
        _ templates: NotificationTemplates,
        _ resolve: (String) -> TemplateValue?
    ) -> (title: String, subtitle: String, body: String) {
        (
            title: templates.title.renderText(resolve),
            subtitle: templates.subtitle.renderText(resolve),
            body: templates.body.renderText(resolve)
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

/// One agent as seen at a capture, with the text its notification would carry
/// already rendered. The reducer decides on the pane's status alone and never
/// reads these strings, so an edited template or a renamed source changes what
/// the agent's next attention transition says without delivering anything now.
struct AttentionAgentObservation: Equatable {
    var pane: Pane
    var title: String
    var subtitle: String
    var body: String
}

/// Pure reducer for attention state. It has no AppKit, UserNotifications,
/// UserDefaults, Observation, clock, or asynchronous dependencies.
struct AttentionStateMachine {
    private struct SourceState {
        var generationID: AttentionSourceGenerationID
        var isRemote: Bool
        var isAvailable: Bool
        var hasBaseline: Bool
        var agents: [AgentRecord]
    }

    private struct AgentRecord {
        /// Immutable for the lifetime of this record. If terminal metadata appears
        /// after a pane-only baseline, aliases are promoted without changing the
        /// request ID, so the same live notification remains addressable.
        let notificationID: AttentionNotificationID
        var terminalID: String?
        var paneID: String
        var observation: AttentionAgentObservation
        /// true after this reducer emitted deliver for the current attention
        /// episode. A baseline may contain blocked/done without owning a notice.
        var ownsNotice: Bool
    }

    private(set) var isEnabled = false
    private var hasStarted = false
    private var sources: [HerdrSourceID: SourceState] = [:]

    /// Starts one process lifetime. removeAll clears notifications left by a crash;
    /// enabled sources are then baselined from the supplied current fleet.
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

    /// Applies the independent notification preference. Re-enabling takes an
    /// atomic baseline of the current fleet, so attention that predates the toggle
    /// does not appear as a new transition.
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

    /// Reconciles a full observation. Successful snapshots are authoritative for
    /// status and disappearance; unavailable sources retain the last successful
    /// state until a reconnect can provide another comparison point.
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

    /// Ends the process lifetime and instructs delivery to remove every managed
    /// request, including one no longer represented in memory after a race.
    mutating func stop() -> [AttentionEffect] {
        guard hasStarted else { return [] }
        hasStarted = false
        isEnabled = false
        sources.removeAll()
        return [.removeAll]
    }

    /// Resolves a notification request to the latest pane rather than trusting the
    /// pane ID embedded when the banner was delivered. Unavailable sources return
    /// nil so click handling can open Monitor without targeting stale state.
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
            // Promote an earlier pane fallback only when it did not already have a
            // conflicting terminal identity. Equal pane IDs with two different
            // terminal IDs are different agents.
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

    /// Wraps the text the observation arrived with in a request. The notice is
    /// built from the transition's observation, so a template edit or a rename
    /// after delivery leaves the live banner alone.
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

    /// Base64 does not contain '.', the field separator used above, so arbitrary
    /// Herdr IDs cannot make two structured identifiers collapse to one string.
    private static func encoded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }
}

private extension AgentStatus {
    var needsAttention: Bool {
        self == .blocked || self == .done
    }
}

/// App-owned bridge from Observation to AttentionStateMachine. It emits effects
/// synchronously on MainActor; a live notification service may enqueue or await
/// platform work behind the injected closure while tests record values directly.
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

    /// Starts tracking before FleetStore starts polling. The initial capture is the
    /// process baseline, and the observation is armed before removeAll reaches the
    /// effect sink so sink-side work cannot create an unobserved fleet mutation.
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
            // Observation invokes onChange on the writer's executor before the
            // mutation completes. Deferring one MainActor turn reads the new value.
            Task { @MainActor [weak self] in
                self?.consumeObservedChange()
            }
        }
    }

    private func consumeObservedChange() {
        guard hasStarted, !hasStopped, let store else { return }
        let observation = AttentionFleetObservation(store: store)
        // Re-arm before invoking the external sink. There is no suspension between
        // this capture and registration, so subsequent MainActor writes are tracked.
        armObservation()
        emit(machine.ingest(observation))
    }

    private func emit(_ effects: [AttentionEffect]) {
        guard !effects.isEmpty else { return }
        effectHandler(effects)
    }
}
