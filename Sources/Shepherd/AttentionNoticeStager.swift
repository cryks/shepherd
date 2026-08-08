// The screen read that refreshes an agent's excerpt starts on the same snapshot
// tick as the status transition but finishes later, so a banner delivered at the
// transition would quote the previous turn. Holding each deliver until the
// excerpt changes, or until a short hold expires, lets it quote the blocked
// question or the final message instead.
//
// Holding also means an attention state that resolves inside the hold never
// reaches the screen at all, because the matching remove cancels the held notice.

import Foundation
import Observation

@MainActor
final class AttentionNoticeStager {
    nonisolated static let defaultHoldDuration: Duration = .seconds(2)

    private final class HeldNotice {
        let notice: AttentionNotice
        // A read that confirms an already-correct cache reports the same text
        // again, which is no evidence of a fresh read; only a different text may
        // release early, and an unchanged one waits for the hold to expire.
        let stagedText: String?
        var expiryTask: Task<Void, Never>?

        init(notice: AttentionNotice, stagedText: String?) {
            self.notice = notice
            self.stagedText = stagedText
        }
    }

    // A closure so tests can supply their own @Observable fixture. It is called
    // inside withObservationTracking, so whatever Observable state it reads
    // drives the re-evaluation of a held notice.
    private let excerptState: @MainActor (SourcePaneID) -> AgentExcerptState?
    // The stager owns when a notice is released; the caller owns what the
    // excerpt does to its text. Returning nil forwards the notice as staged.
    private let render: @MainActor (AttentionNotice, String) -> AttentionNotice?
    private let holdDuration: Duration
    private let forward: @MainActor ([AttentionEffect]) -> Void
    private var held: [AttentionNotificationID: HeldNotice] = [:]

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

    // Pass-through effects stay in one batch to keep their relative order; a
    // held deliver leaves later as its own batch, which AgentNotificationCenter's
    // serial queue then orders after everything already forwarded.
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
        // A second deliver for the same ID (blocked to done with no resolution
        // between) replaces the held notice and restarts the hold.
        discard(notice.id)
        // No excerpt to wait for: preference off, agent unsupported, or the pane
        // has left a ready snapshot.
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

    // onChange fires at most once, and before the mutation is fully applied,
    // hence the MainActor hop, the re-read, and the re-arm. The identity check
    // drops callbacks that outlived their notice.
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
