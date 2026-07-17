// The pop-out window. Detaches the same list as the menu bar panel (SourceList)
// into a regular window so the whole herd can stay visible while working.
// Lists parent agents per connection, and within that per workspace; local rows
// jump to the corresponding herdr pane, remote rows are monitor-only with no
// actions. This view's appear/disappear is the sole writer of
// store.monitorWindowVisible.
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

import SwiftUI

struct MonitorView: View {
    var store: FleetStore

    var body: some View {
        ScrollView {
            SourceList(sections: store.sourceSections, style: .window) { pane in
                store.focus(pane, sourceID: .local)
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
        .onDisappear { store.monitorWindowVisible = false }
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
