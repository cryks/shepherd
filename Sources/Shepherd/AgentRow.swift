// A single agent's row (AgentRow) and the per-workspace headed list
// (AgentGroupList). Shared components used by both the monitor window and the
// menu bar panel, so changes to the row layout or heading styling made in this
// file alone propagate to both surfaces.
// AgentRow shows the StatusIcons circle on the left (same rendering as the menu
// bar itself), and on the right two lines — the work title and a sub-line
// (agent brand mark + branch name) — plus a status string.
// Only the hover highlight is switched via HoverStyle, to match the native
// idiom of the surface the row is placed on. Rows from a local source are
// Buttons carrying agent.focus; rows from a remote source are static,
// monitor-only displays. Both share the same row layout, and non-interactive
// rows are not dimmed with a disabled appearance.

import AppKit
import SwiftUI

/// Per-workspace heading (caption) + vertically stacked AgentRows. Owns no
/// scrolling or sizing, so the caller wraps it in a ScrollView or similar.
/// The click behavior of a row (whether to close the panel in addition to
/// focusing the pane, etc.) is decided by the caller via onFocus.
struct AgentGroupList: View {
    let sourceID: HerdrSourceID
    let groups: [(workspace: Workspace, panes: [Pane])]
    let hoverStyle: AgentRow.HoverStyle
    let onFocus: ((Pane) -> Void)?

    private var identifiedGroups: [IdentifiedWorkspaceGroup] {
        groups.map { group in
            IdentifiedWorkspaceGroup(
                id: SourceWorkspaceID(
                    sourceID: sourceID,
                    workspaceID: group.workspace.workspaceId
                ),
                workspace: group.workspace,
                panes: group.panes.map { pane in
                    IdentifiedPane(
                        id: SourcePaneID(sourceID: sourceID, paneID: pane.paneId),
                        pane: pane
                    )
                }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(identifiedGroups) { group in
                Text(group.workspace.label ?? group.workspace.workspaceId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                ForEach(group.panes) { identifiedPane in
                    AgentRow(
                        pane: identifiedPane.pane,
                        hoverStyle: hoverStyle,
                        onFocus: onFocus.map { action in
                            { action(identifiedPane.pane) }
                        }
                    )
                }
            }
        }
        // The horizontal 5pt is the inset the highlight keeps from the edge of
        // the surface, the same value as the MenuItems at the bottom of
        // MenuPanel. Combined with the 12pt text inset inside headings and
        // rows, text starts 17pt from the surface edge, aligned across all rows.
        // No vertical padding here: the gap to the source heading, between
        // sections, and to the surface edge differ per placement context, so
        // SourceList owns those values.
        .padding(.horizontal, 5)
    }

    private struct IdentifiedWorkspaceGroup: Identifiable {
        let id: SourceWorkspaceID
        let workspace: Workspace
        let panes: [IdentifiedPane]
    }

    private struct IdentifiedPane: Identifiable {
        let id: SourcePaneID
        let pane: Pane
    }
}

struct AgentRow: View {
    /// Hover highlight style. The same row is placed in both the monitor
    /// window's List and the menu panel, but the native selection idiom differs
    /// per surface, so the caller chooses.
    enum HoverStyle {
        /// For the monitor window's List. Lays down a subtle gray (quaternary) only; foreground colors are unchanged.
        case list
        /// For the menu bar panel. Reproduces NSMenu's selection state (accent
        /// color background + selected foreground color) to match the MenuItems
        /// at the bottom of MenuPanel.
        case menu
    }

    let pane: Pane
    let hoverStyle: HoverStyle
    /// Jump-to action on row click. nil marks a remote, monitor-only row,
    /// which gets no Button and no hover feedback.
    let onFocus: (() -> Void)?

    @State private var isHovered = false
    @AppStorage(colorAgentIconsKey) private var colorAgentIcons = false

    var body: some View {
        Group {
            if let onFocus {
                Button(action: onFocus) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 12)
        // The foreground color is switched in one place here. The subtitle's
        // .secondary and the template-rendered mark derive from this color as
        // hierarchical styles, so the menu inversion needs no per-element handling.
        .foregroundStyle(isMenuHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
        .background(
            hoverBackground,
            in: RoundedRectangle(cornerRadius: hoverCornerRadius, style: .continuous)
        )
        .onHover { isHovered = onFocus == nil ? false : $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusIcons.icon(for: pane.agentStatus))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pane.displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(pane.agentStatus.rawValue)
                        .font(.caption)
                        // Native menus uniformly invert selected text to the
                        // selected foreground color, so only while hovered in
                        // menu style we drop the status's semantic color and
                        // follow the parent foreground color instead.
                        .foregroundStyle(
                            isMenuHighlighted
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(pane.agentStatus.indicatorColor)
                        )
                }
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    /// Whether we are hovered in menu style. The foreground color inversion
    /// happens only in this state; list style lays down a background only and
    /// keeps text colors at their normal appearance.
    private var isMenuHighlighted: Bool { isHovered && hoverStyle == .menu }

    private var hoverBackground: AnyShapeStyle {
        guard isHovered else { return AnyShapeStyle(.clear) }
        switch hoverStyle {
        case .list: return AnyShapeStyle(.quaternary)
        case .menu: return AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor))
        }
    }

    /// menu matches the corner radius of MenuPanel's MenuItems (radius 9 = the
    /// concentric value of the panel's ~14pt outer corner radius minus the 5pt
    /// inset), keeping highlight shapes consistent within the same panel.
    private var hoverCornerRadius: CGFloat {
        switch hoverStyle {
        case .list: 6
        case .menu: 9
        }
    }

    /// The sub-line. Agents with a mark asset are shown as "brand mark +
    /// branch name", with the agent name string relegated to the hover tooltip.
    /// Panes without a branch (non-git, detached HEAD, fetch failure) show the
    /// mark only. Agents without a mark keep the displaySubtitle text.
    /// The mark's fill is switched by the setting (colorAgentIconsKey): mono
    /// renders the solid-black asset as a template so it follows the sub-line's
    /// secondary foreground color and dark mode; color renders the original to
    /// preserve the brand colors.
    @ViewBuilder
    private var subtitle: some View {
        let style: AgentIconStyle = colorAgentIcons ? .color : .mono
        if let agent = pane.agent, let mark = AgentIcons.icon(for: agent, style: style) {
            HStack(spacing: 4) {
                Image(nsImage: mark)
                    .renderingMode(style == .mono ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                if let branch = pane.branch {
                    Text(branch)
                }
            }
            .help(agent)
        } else {
            Text(pane.displaySubtitle)
        }
    }

}

extension AgentStatus {
    /// Semantic color for each state. Shared by AgentRow's status string and
    /// the dots in the pop-out window's header summary. Matches the color
    /// family of the menu bar circles (StatusIcons: systemYellow / systemGreen
    /// / systemRed) to keep the visual language consistent.
    var indicatorColor: Color {
        switch self {
        case .working: .yellow
        case .blocked: .red
        case .done: .green
        case .idle: .secondary
        case .unknown: .gray.opacity(0.5)
        }
    }
}
