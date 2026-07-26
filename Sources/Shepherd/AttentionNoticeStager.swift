// Stages blocked/done notification delivery so the banner can carry the
// agent's current excerpt. AttentionStateMachine composes an AttentionNotice
// at the status transition, but the excerpt cache is refreshed by a screen
// read that starts on the same snapshot tick and completes later, so a notice
// delivered immediately would carry the previous turn's text. Holding the
// deliver effect until the pane's displayed excerpt changes — or a bounded
// hold expires — lets the banner carry the blocked question or the settled
// final message instead.
//
// Effect contract: remove and removeAll pass through in batch order, and a
// remove matching a held deliver also cancels it, so an attention state that
// resolves within the hold window never presents a banner. A second deliver
// with the same notification ID (blocked to done with no resolution between)
// replaces the held notice and restarts the hold. A deliver whose excerpt
// lookup returns nil (excerpt preference off, unsupported agent, pane no
// longer in a ready snapshot) passes through unchanged without holding.
//
// Release timing: a change of the pane's excerpt to an available value whose
// text differs from the text captured at staging releases immediately; the
// hold expiry releases with whatever text is available then, which covers a
// settled read that kept an already-correct cache and never fired a change.
//
// What the excerpt does to the notice belongs to the injected `render`: the
// stager owns when a notice is released, and the caller owns the text it is
// released with. A release with no excerpt available, and a render that
// declines, both forward the notice as it was staged.

import Foundation
import Observation

/// Holds deliver effects between AttentionMonitor and AgentNotificationCenter.
///
/// The excerpt lookup is a closure so the app can pass
/// FleetStore.agentExcerptState(for:) while tests substitute an @Observable
/// fixture; the lookup runs inside withObservationTracking, so any Observable
/// state it reads re-evaluates a held notice when it changes. All state is
/// MainActor-isolated, matching the AttentionMonitor effect path.
@MainActor
final class AttentionNoticeStager {
    nonisolated static let defaultHoldDuration: Duration = .seconds(2)

    private final class HeldNotice {
        let notice: AttentionNotice
        /// Excerpt text displayed when the notice was staged. An excerpt-change
        /// release requires a text different from this one; the same text can
        /// reappear when the post-transition read keeps an already-correct
        /// cache, and only the hold expiry may release it then.
        let stagedText: String?
        var expiryTask: Task<Void, Never>?

        init(notice: AttentionNotice, stagedText: String?) {
            self.notice = notice
            self.stagedText = stagedText
        }
    }

    private let excerptState: @MainActor (SourcePaneID) -> AgentExcerptState?
    private let render: @MainActor (AttentionNotice, String) -> AttentionNotice?
    private let holdDuration: Duration
    private let forward: @MainActor ([AttentionEffect]) -> Void
    private var held: [AttentionNotificationID: HeldNotice] = [:]

    /// - Parameter render: The notice to deliver for a staged notice and the
    ///   excerpt text available at release. nil forwards the staged notice.
    init(
        excerptState: @escaping @MainActor (SourcePaneID) -> AgentExcerptState?,
        render: @escaping @MainActor (AttentionNotice, String) -> AttentionNotice?,
        holdDuration: Duration = AttentionNoticeStager.defaultHoldDuration,
        forward: @escaping @MainActor ([AttentionEffect]) -> Void
    ) {
        self.excerptState = excerptState
        self.render = render
        self.holdDuration = holdDuration
        self.forward = forward
    }

    /// Accepts one AttentionMonitor effect batch. Pass-through effects keep
    /// their relative order in a single forwarded batch; a held deliver is
    /// forwarded later as its own batch, which AgentNotificationCenter's
    /// serial queue orders after every batch already forwarded.
    func apply(_ effects: [AttentionEffect]) {
        var passThrough: [AttentionEffect] = []
        for effect in effects {
            switch effect {
            case .deliver(let notice):
                stage(notice, passThrough: &passThrough)
            case .remove(let id):
                discard(id)
                passThrough.append(effect)
            case .removeAll:
                for id in Array(held.keys) {
                    discard(id)
                }
                passThrough.append(effect)
            }
        }
        if !passThrough.isEmpty {
            forward(passThrough)
        }
    }

    private func stage(
        _ notice: AttentionNotice,
        passThrough: inout [AttentionEffect]
    ) {
        discard(notice.id)
        guard let state = excerptState(notice.sourcePaneID) else {
            passThrough.append(.deliver(notice))
            return
        }

        let heldNotice = HeldNotice(
            notice: notice,
            stagedText: Self.displayText(state)
        )
        held[notice.id] = heldNotice

        let duration = holdDuration
        heldNotice.expiryTask = Task { @MainActor [weak self, weak heldNotice] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled,
                  let self, let heldNotice,
                  self.held[heldNotice.notice.id] === heldNotice else {
                return
            }
            let text = Self.displayText(
                self.excerptState(heldNotice.notice.sourcePaneID)
            )
            self.release(heldNotice, excerpt: text)
        }
        observeExcerpt(for: heldNotice)
    }

    /// Arms one observation cycle for a held notice. onChange fires at most
    /// once and before the mutation is fully applied, so the follow-up hops
    /// through a MainActor task, re-reads the lookup, and either releases or
    /// re-arms. The identity guard drops callbacks that outlive their notice.
    private func observeExcerpt(for heldNotice: HeldNotice) {
        let paneID = heldNotice.notice.sourcePaneID
        withObservationTracking {
            _ = excerptState(paneID)
        } onChange: { [weak self, weak heldNotice] in
            Task { @MainActor [weak self, weak heldNotice] in
                guard let self, let heldNotice,
                      self.held[heldNotice.notice.id] === heldNotice else {
                    return
                }
                let text = Self.displayText(self.excerptState(paneID))
                if let text, text != heldNotice.stagedText {
                    self.release(heldNotice, excerpt: text)
                } else {
                    self.observeExcerpt(for: heldNotice)
                }
            }
        }
    }

    private func release(_ heldNotice: HeldNotice, excerpt text: String?) {
        heldNotice.expiryTask?.cancel()
        heldNotice.expiryTask = nil
        held.removeValue(forKey: heldNotice.notice.id)
        let notice = heldNotice.notice
        forward([.deliver(text.flatMap { render(notice, $0) } ?? notice)])
    }

    private func discard(_ id: AttentionNotificationID) {
        guard let heldNotice = held.removeValue(forKey: id) else { return }
        heldNotice.expiryTask?.cancel()
        heldNotice.expiryTask = nil
    }

    private static func displayText(_ state: AgentExcerptState?) -> String? {
        guard case .available(let excerpt) = state else { return nil }
        return excerpt.text
    }
}
