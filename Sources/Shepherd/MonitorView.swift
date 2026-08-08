// The pop-out window: the same SourceList as the menu bar panel, detached into
// a regular window. The title bar stays standard so AppKit keeps traffic-light
// alignment, window dragging, and the titlebar separator on scroll.

import Foundation
import Observation
import SwiftUI

// Handoff between app-level triggers (notification routing, global hotkey) and
// the singleton Monitor scene. Revisions, not stored requests, are the signal,
// so an always-mounted view holding OpenWindowAction can react to repeated
// clicks on the same agent without owning notification semantics.
@Observable @MainActor
final class MonitorWindowNavigation {
    struct RevealRequest: Equatable {
        let revision: UInt64
        let paneID: SourcePaneID
    }

    private(set) var openRevision: UInt64 = 0
    // Separate from openRevision so an open arriving while a close is still
    // unconsumed cannot be lost, and the reverse.
    private(set) var closeRevision: UInt64 = 0
    private var revealRequest: RevealRequest?
    @ObservationIgnored private let revealHandoffDuration: Duration
    @ObservationIgnored private var revealExpiryTask: Task<Void, Never>?

    init(revealHandoffDuration: Duration = .seconds(5)) {
        self.revealHandoffDuration = revealHandoffDuration
    }

    // Callers must map notification-time identity onto the pane ID of the
    // latest ready snapshot first; a stale ID reveals nothing.
    func open(revealing paneID: SourcePaneID? = nil) {
        openRevision &+= 1
        revealExpiryTask?.cancel()
        guard let paneID else {
            revealRequest = nil
            revealExpiryTask = nil
            return
        }

        let request = RevealRequest(revision: openRevision, paneID: paneID)
        revealRequest = request
        let revealHandoffDuration = revealHandoffDuration
        revealExpiryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: revealHandoffDuration)
            } catch {
                return
            }
            guard self?.revealRequest?.revision == request.revision else { return }
            self?.revealRequest = nil
            self?.revealExpiryTask = nil
        }
    }

    // Consumed by the receiver at the menu bar label, which owns
    // DismissWindowAction. Dismissing an already-closed window is a no-op, so
    // callers need only best-effort knowledge of visibility.
    func requestClose() {
        closeRevision &+= 1
    }

    // Reading does not consume the request: an outgoing and an incoming Monitor
    // view overlap while the singleton window comes back after a notification
    // click, and both must be able to read it.
    func currentRevealRequest() -> RevealRequest? {
        revealRequest
    }
}

struct MonitorView: View {
    var store: FleetStore
    var navigation: MonitorWindowNavigation

    @State private var highlightedPaneID: SourcePaneID?
    @State private var revealTask: Task<Void, Never>?
    // Per-instance lease: FleetStore derives window visibility from the set of
    // live IDs, so an outgoing view's disappear cannot clear the state of the
    // replacement view that already appeared.
    @State private var presenceID = UUID()

    @MainActor
    init(store: FleetStore, navigation: MonitorWindowNavigation) {
        self.store = store
        self.navigation = navigation
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                SourceList(
                    sections: store.sourceSections,
                    style: .window,
                    showsSourceLabels: store.showsSourceLabels,
                    rowContext: store.rowContext(for:),
                    highlightedPaneID: highlightedPaneID,
                    excerptState: store.agentExcerptState(for:)
                ) { pane in
                    Task { @MainActor in
                        await store.focus(pane, sourceID: .local)
                    }
                }
            }
            // A request can arrive before the scene is presented, so the handoff
            // is read both on appear and on every later revision.
            .onAppear { revealPendingPane(using: proxy) }
            .onChange(of: navigation.openRevision) {
                revealPendingPane(using: proxy)
            }
        }
        // macOS 26 gives the standard window title a large leading inset, so the
        // string is dropped and redrawn as our own Text next to the traffic
        // lights. Window("Shepherd") still names the window in Mission Control.
        .toolbar(removing: .title)
        .toolbar {
            // The macOS 26 toolbar puts items on a Liquid Glass pedestal, which
            // reads as a control. The title and the chips are display-only, so
            // both hide it.
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    titleLabel
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    statusSummary
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    titleLabel
                }
                ToolbarItem(placement: .primaryAction) {
                    statusSummary
                }
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .onAppear {
            store.monitorWindowDidAppear(presenceID)
        }
        .onDisappear {
            store.monitorWindowDidDisappear(presenceID)
            revealTask?.cancel()
            revealTask = nil
            highlightedPaneID = nil
        }
    }

    private func revealPendingPane(using proxy: ScrollViewProxy) {
        revealTask?.cancel()
        guard let request = navigation.currentRevealRequest() else {
            highlightedPaneID = nil
            revealTask = nil
            return
        }

        let paneID = request.paneID
        highlightedPaneID = paneID
        revealTask = Task { @MainActor in
            // Let SourceList lay out a newly opened window first; ScrollViewProxy
            // cannot find the ID before its row exists.
            await Task.yield()
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(paneID, anchor: .center)
            }

            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard !Task.isCancelled, highlightedPaneID == paneID else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                highlightedPaneID = nil
            }
            revealTask = nil
        }
    }

    private var titleLabel: some View {
        Text("Shepherd")
            .font(.headline)
    }

    // The extra trailing padding is needed because the toolbar's own trailing
    // margin leaves the chip capsules too close to the window edge.
    private var statusSummary: some View {
        HStack(spacing: 6) {
            ForEach(statusCounts, id: \.status) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.status.indicatorColor)
                        .frame(width: 7, height: 7)
                    Text("\(entry.count)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quinary, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summaryLabel(for: entry))
            }
        }
        .padding(.trailing, 6)
    }

    // Counted over sourceSections so the chips match the list exactly, which
    // also drops remotes with monitoring off. idle and unknown are left out
    // because they are not active states. The order matches the menu bar
    // severity in aggregateMenuBarState.
    private var statusCounts: [(status: AgentStatus, count: Int)] {
        let statuses = store.sourceSections
            .flatMap(\.workspaceGroups)
            .flatMap(\.panes)
            .map(\.agentStatus)
        return [AgentStatus.blocked, .done, .working].compactMap { status in
            let count = statuses.count(where: { $0 == status })
            return count > 0 ? (status, count) : nil
        }
    }

    private func summaryLabel(for entry: (status: AgentStatus, count: Int)) -> String {
        switch entry.status {
        case .blocked:
            tr("\(entry.count) blocked", ja: "入力待ち \(entry.count)")
        case .done:
            tr("\(entry.count) done", ja: "完了 \(entry.count)")
        default:
            tr("\(entry.count) working", ja: "作業中 \(entry.count)")
        }
    }
}
