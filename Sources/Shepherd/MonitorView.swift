// The pop-out window. Detaches the same list as the menu bar panel (SourceList)
// into a regular window so the whole herd can stay visible while working.
// Lists parent agents per connection, and within that per workspace; local rows
// jump to the corresponding herdr pane, remote rows are monitor-only with no
// actions. This view's appear/disappear is the sole writer of
// store.monitorWindowVisible. Notification navigation is received through the
// app-owned MonitorWindowNavigation. A request opens this singleton scene at the
// app boundary; once the view appears, it reads the current SourcePaneID, scrolls
// the matching row into view, and emphasizes it for about two seconds.
//
// This file owns the window's appearance: on top of the standard opaque window
// background, SourceList (window style) floats a rounded-corner card per
// section. The title bar stays standard, leaving traffic-light alignment,
// window dragging, and the titlebar separator on scroll to AppKit. Only the
// title string is removed with removing: .title, to avoid the large leading
// inset the standard window title carries (macOS 26), and placed as our own
// Text in the navigation slot right after the traffic lights (the
// Window("Shepherd") title still appears in window overviews such as Mission
// Control). The top right adds chips with per-status agent counts.

import Observation
import SwiftUI

/// Main-actor handoff between notification action routing and the singleton
/// Monitor scene. `openRevision` changes for every request, including repeated
/// clicks on the same agent and open-only fallbacks, so an always-mounted view
/// with OpenWindowAction can react without owning notification semantics.
/// The latest reveal target remains readable for a short handoff lease. A closing
/// window can receive the revision just before disappearing; retaining the target
/// lets the replacement scene read it on appear instead of losing the click.
@Observable @MainActor
final class MonitorWindowNavigation {
    struct RevealRequest: Equatable {
        let revision: UInt64
        let paneID: SourcePaneID
    }

    private(set) var openRevision: UInt64 = 0
    private var revealRequest: RevealRequest?
    @ObservationIgnored private let revealHandoffDuration: Duration
    @ObservationIgnored private var revealExpiryTask: Task<Void, Never>?

    init(revealHandoffDuration: Duration = .seconds(5)) {
        self.revealHandoffDuration = revealHandoffDuration
    }

    /// Requests that the Monitor window come forward and optionally reveal a
    /// currently resolved row. Callers must resolve notification-time identity
    /// to the pane ID in the latest ready snapshot before passing it here.
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

    /// Returns the latest row while its handoff lease is active. Reading does not
    /// consume it because an outgoing and incoming Monitor view can overlap while
    /// the singleton window is being brought back after a notification click.
    func currentRevealRequest() -> RevealRequest? {
        revealRequest
    }
}

struct MonitorView: View {
    var store: FleetStore
    var navigation: MonitorWindowNavigation

    @State private var highlightedPaneID: SourcePaneID?
    @State private var revealTask: Task<Void, Never>?

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
                    highlightedPaneID: highlightedPaneID
                ) { pane in
                    Task { @MainActor in
                        await store.focus(pane, sourceID: .local)
                    }
                }
            }
            // A request can precede scene presentation, so read the active handoff
            // both when the singleton appears and while its window stays visible.
            .onAppear { revealPendingPane(using: proxy) }
            .onChange(of: navigation.openRevision) {
                revealPendingPane(using: proxy)
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            // The macOS 26 toolbar puts items on a Liquid Glass pedestal, but a
            // control-like look is wrong for the title and the non-clickable,
            // display-only chips, so both hide it via sharedBackgroundVisibility.
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
        .onAppear { store.monitorWindowVisible = true }
        .onDisappear {
            store.monitorWindowVisible = false
            revealTask?.cancel()
            revealTask = nil
            highlightedPaneID = nil
        }
    }

    /// Reveals only a row resolved from the current snapshot. The first yield lets
    /// SourceList lay out a newly opened window before ScrollViewProxy searches for
    /// the ID. A newer request cancels both the stale scroll and its clear timer.
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

    /// Row of chips with per-status agent counts. States with a count of 0 are
    /// omitted; when every state is 0 (no agents, or not connected) nothing is
    /// drawn. Ordered by the same severity as the menu bar aggregation
    /// (aggregateMenuBarState): blocked → done → working.
    /// The trailing 6pt is added because with only the toolbar's default
    /// trailing margin the chip capsules sit too close to the window edge.
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

    /// Tally over the same scope as the sections shown in the window
    /// (sourceSections). Remotes with monitoring off are excluded from the
    /// summary just as they are from the list.
    /// idle / unknown are not counted, as they are not "active" states.
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
