// A single agent's row (AgentRow) and the per-workspace headed list
// (AgentGroupList).
//
// A row is a fixed status icon plus the lines of the RowLayout in effect: each
// line draws a left and a right template, each with its own RowTextStyle
// preset, and a line whose two sides both render empty is dropped. Menu rows
// keep the height of a line that reads {excerpt} across the loading and empty
// states so the panel does not resize when the excerpt arrives; Monitor rows
// show that line only once text is available.
//
// This file owns what a preset looks like (font, weight, hierarchical color,
// {agent_icon} size) and nothing about where values come from: AgentRowContext
// resolves every variable name, and the caller builds one per pane. Row colors
// stay hierarchical or branch on hover so the single foregroundStyle switch in
// `body` inverts the whole row for the menu's selected state.
//
// A local row's main content is a Button carrying agent.focus. A remote row's
// main content remains static. AgentGroupList constructs the cross-source
// SourcePaneID used by excerpts, notification reveal, and ScrollViewReader
// identity.

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
    /// Template values for one row. `groups` and this lookup are read from the
    /// same snapshot, so nil means the pane is gone and the row is skipped.
    let rowContext: (SourcePaneID) -> AgentRowContext?
    let highlightedPaneID: SourcePaneID?
    let excerptState: ((SourcePaneID) -> AgentExcerptState?)?
    /// Menu rows reserve the height of the {excerpt} line across loading,
    /// available, and empty states. Monitor rows render only an available Excerpt.
    let reservesExcerptLine: Bool
    let onFocus: ((Pane) -> Void)?

    init(
        sourceID: HerdrSourceID,
        groups: [(workspace: Workspace, panes: [Pane])],
        hoverStyle: AgentRow.HoverStyle,
        rowContext: @escaping (SourcePaneID) -> AgentRowContext?,
        highlightedPaneID: SourcePaneID? = nil,
        excerptState: ((SourcePaneID) -> AgentExcerptState?)? = nil,
        reservesExcerptLine: Bool = false,
        onFocus: ((Pane) -> Void)?
    ) {
        self.sourceID = sourceID
        self.groups = groups
        self.hoverStyle = hoverStyle
        self.rowContext = rowContext
        self.highlightedPaneID = highlightedPaneID
        self.excerptState = excerptState
        self.reservesExcerptLine = reservesExcerptLine
        self.onFocus = onFocus
    }

    private var identifiedGroups: [IdentifiedWorkspaceGroup] {
        groups.map { group in
            IdentifiedWorkspaceGroup(
                id: SourceWorkspaceID(
                    sourceID: sourceID,
                    workspaceID: group.workspace.workspaceId
                ),
                workspace: group.workspace,
                panes: group.panes.compactMap { pane in
                    let id = SourcePaneID(sourceID: sourceID, paneID: pane.paneId)
                    return rowContext(id).map { context in
                        IdentifiedPane(id: id, pane: pane, context: context)
                    }
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
                        context: identifiedPane.context,
                        hoverStyle: hoverStyle,
                        isRevealed: identifiedPane.id == highlightedPaneID,
                        excerptState: excerptState?(identifiedPane.id),
                        reservesExcerptLine: reservesExcerptLine,
                        onFocus: onFocus.map { action in
                            { action(identifiedPane.pane) }
                        }
                    )
                    // ForEach identity drives diffing, while this explicit view
                    // identity is the ScrollViewReader target used by MonitorView.
                    .id(identifiedPane.id)
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
        let context: AgentRowContext
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

    /// Everything the templates read, plus the pane the row is drawn for: the
    /// status icon, the `status` preset's color, and the per-agent line
    /// override all come from `context.pane`.
    let context: AgentRowContext
    let hoverStyle: HoverStyle
    /// Programmatic, transient emphasis used after a notification opens Monitor.
    /// It does not change clickability or establish persistent selection.
    let isRevealed: Bool
    /// Load state of the excerpt. nil means the preference is off or the pane
    /// has no supported terminal grammar; `{excerpt}` then resolves empty and
    /// no line is reserved.
    let excerptState: AgentExcerptState?
    /// Whether loading and empty states reserve the height of the {excerpt} line.
    let reservesExcerptLine: Bool
    /// Jump-to action on row click. nil marks a remote, monitor-only row,
    /// which gets no Button and no hover feedback.
    let onFocus: (() -> Void)?

    @State private var isHovered = false
    @AppStorage(colorAgentIconsKey) private var colorAgentIcons = false

    init(
        context: AgentRowContext,
        hoverStyle: HoverStyle,
        isRevealed: Bool = false,
        excerptState: AgentExcerptState? = nil,
        reservesExcerptLine: Bool = false,
        onFocus: (() -> Void)? = nil
    ) {
        self.context = context
        self.hoverStyle = hoverStyle
        self.isRevealed = isRevealed
        self.excerptState = excerptState
        self.reservesExcerptLine = reservesExcerptLine
        self.onFocus = onFocus
    }

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
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 3)
        .padding(.horizontal, 12)
        // The foreground color is switched in one place here. Every preset
        // expresses its color as a hierarchical style (.secondary / .primary)
        // or branches on hover, so the menu inversion needs no per-line handling.
        .foregroundStyle(isMenuHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
        .background(
            rowBackground,
            in: RoundedRectangle(cornerRadius: hoverCornerRadius, style: .continuous)
        )
        .onHover { isHovered = onFocus == nil ? false : $0 }
    }

    /// The status icon is a fixed slot outside the templates: it sits beside
    /// the line stack, centered over the whole row, and is always drawn.
    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusIcons.icon(for: context.pane.agentStatus))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(lines) { line in
                    lineView(line)
                }
            }
        }
    }

    /// Lines in effect for this pane. Read during body evaluation so an edit in
    /// the settings pane redraws every mounted row.
    private var lines: [RowLine] {
        RowLayoutSetting.shared.layout.lines(forAgent: context.pane.agent)
    }

    /// Variable name that carries the extracted agent message. A line naming it
    /// is the one whose height the menu reserves.
    private static let excerptVariable = "excerpt"

    @ViewBuilder
    private func lineView(_ line: RowLine) -> some View {
        let left = line.left.render(context.templateValue(for:))
        let right = line.right.render(context.templateValue(for:))
        if reservesExcerptLine, let excerptState, readsExcerpt(line) {
            reservedExcerptLine(line, left: left, right: right, state: excerptState)
        } else if !left.isEmpty || !right.isEmpty {
            lineContent(line, left: left, right: right)
        }
    }

    private func lineContent(
        _ line: RowLine,
        left: [TemplateRun],
        right: [TemplateRun]
    ) -> some View {
        // .top keeps the right side beside the first line when the left side
        // wraps across line.maxLines rows.
        HStack(alignment: .top, spacing: 6) {
            runsView(left, style: line.leftStyle)
                .lineLimit(line.maxLines)
                .truncationMode(.tail)
            // A line with an empty right template spends none of its width on
            // the gap, so the left side truncates at the same column it would
            // reach on a line that has no right template at all.
            if !right.isEmpty {
                Spacer()
                // The right side keeps its width and the left side gives way, so
                // a long title truncates instead of pushing the status off the row.
                runsView(right, style: line.rightStyle)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    /// Menu rows keep this line's metrics mounted for every excerpt state,
    /// preventing the panel from resizing when the first Excerpt arrives. The
    /// placeholder alone decides the height in all three states — it reserves
    /// line.maxLines rows, so a wrapping excerpt cannot grow the panel either;
    /// while loading it is also what the row shows, so a line mixing {excerpt}
    /// with other variables displays only the placeholder until text arrives.
    @ViewBuilder
    private func reservedExcerptLine(
        _ line: RowLine,
        left: [TemplateRun],
        right: [TemplateRun],
        state: AgentExcerptState
    ) -> some View {
        switch state {
        case .loading:
            excerptPlaceholder(line)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Excerpt")
                .accessibilityValue("Loading")
        case .available(let excerpt):
            excerptPlaceholder(line)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                // Overlay content does not participate in vertical measurement,
                // so fallback glyph metrics cannot resize the menu after the
                // placeholder is replaced. topLeading starts an excerpt shorter
                // than the reserved rows at the first one instead of centering.
                .overlay(alignment: .topLeading) {
                    lineContent(line, left: left, right: right)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Excerpt")
                .accessibilityValue(excerpt.text)
        case .empty:
            excerptPlaceholder(line)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
        }
    }

    private func excerptPlaceholder(_ line: RowLine) -> some View {
        Text("Loading…")
            .lineLimit(line.maxLines, reservesSpace: true)
            .modifier(rowTextStyle(line.leftStyle))
    }

    private func readsExcerpt(_ line: RowLine) -> Bool {
        line.left.variableNames.contains(Self.excerptVariable)
            || line.right.variableNames.contains(Self.excerptVariable)
    }

    // MARK: - Runs

    /// Draws one side of a line. A render with no icon is a single text run and
    /// becomes one Text; an icon run splits the side into an HStack whose
    /// spacing is 0, because the separation around a mark is written in the
    /// template (`{agent_icon}[ {…}]`) rather than imposed here.
    @ViewBuilder
    private func runsView(_ runs: [TemplateRun], style: RowTextStyle) -> some View {
        if runs.count == 1, case .text(let text) = runs[0] {
            Text(text)
                .modifier(rowTextStyle(style))
        } else {
            HStack(spacing: 0) {
                // Runs carry no identity of their own, and a re-render replaces
                // the whole line, so position is the only identity available.
                ForEach(runs.indices, id: \.self) { index in
                    switch runs[index] {
                    case .text(let text):
                        Text(text)
                    case .icon(let agent):
                        agentIcon(agent, style: style)
                    }
                }
            }
            .modifier(rowTextStyle(style))
        }
    }

    /// The brand mark. Its fill is switched by the setting (colorAgentIconsKey):
    /// mono renders the solid-black asset as a template so it follows the line's
    /// foreground color and dark mode; color renders the original to preserve
    /// the brand colors. The agent name is relegated to the hover tooltip.
    /// An agent with no asset draws nothing — the resolver already reports such
    /// agents as empty, so a `{agent_icon|…}` fallback has taken over by here.
    @ViewBuilder
    private func agentIcon(_ agent: String, style: RowTextStyle) -> some View {
        let iconStyle: AgentIconStyle = colorAgentIcons ? .color : .mono
        if let mark = AgentIcons.icon(for: agent, style: iconStyle) {
            let size = Self.iconSize(for: style)
            Image(nsImage: mark)
                .renderingMode(iconStyle == .mono ? .template : .original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .help(agent)
        }
    }

    /// Square edge of a mark. 11pt was tuned against the 12pt .callout of the
    /// sub-line, so each preset keeps that ratio against its own font size and a
    /// mark on a caption line reads at caption weight.
    private static func iconSize(for style: RowTextStyle) -> CGFloat {
        (NSFont.preferredFont(forTextStyle: style.appKitTextStyle).pointSize * 11 / 12).rounded()
    }

    private func rowTextStyle(_ style: RowTextStyle) -> RowTextStyleModifier {
        RowTextStyleModifier(
            style: style,
            statusColor: context.pane.agentStatus.indicatorColor,
            isMenuHighlighted: isMenuHighlighted
        )
    }

    // MARK: - Hover

    /// Whether we are hovered in menu style. The foreground color inversion
    /// happens only in this state; list style lays down a background only and
    /// keeps text colors at their normal appearance.
    private var isMenuHighlighted: Bool { isHovered && hoverStyle == .menu }

    private var rowBackground: AnyShapeStyle {
        if isRevealed { return AnyShapeStyle(.quaternary) }
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
}

/// Appearance of one RowTextStyle preset. Colors are hierarchical or branch on
/// hover, never an absolute Color, so the row's single foregroundStyle switch
/// still inverts the line when a menu row is highlighted.
private struct RowTextStyleModifier: ViewModifier {
    let style: RowTextStyle
    let statusColor: Color
    let isMenuHighlighted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .heading:
            content.fontWeight(.semibold)
        case .body:
            content.font(.callout)
        case .subdued:
            content.font(.callout).foregroundStyle(.secondary)
        case .monospace:
            content.font(.caption.monospaced()).foregroundStyle(.secondary)
        case .status:
            // Native menus uniformly invert selected text to the selected
            // foreground color, so only while hovered in menu style we drop the
            // status's semantic color and follow the parent foreground color.
            //
            // Semibold: this is the one preset drawn in a saturated hue rather
            // than a hierarchical style, and at caption size those hues carry
            // too little contrast against the light menu background. The added
            // stroke weight restores legibility without darkening the hue.
            content
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    isMenuHighlighted
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(statusColor)
                )
        }
    }
}

private extension RowTextStyle {
    /// AppKit counterpart of the preset's font, used only to size a mark
    /// against the text beside it. The text itself is drawn with SwiftUI fonts.
    var appKitTextStyle: NSFont.TextStyle {
        switch self {
        case .heading: .body
        case .body, .subdued: .callout
        case .monospace, .status: .caption1
        }
    }
}

extension AgentStatus {
    /// Semantic color for each state. Shared by AgentRow's status preset and
    /// the dots in the pop-out window's header summary. Matches the colors the
    /// circles are stroked with (StatusIcons: statusWorking / systemGreen /
    /// systemRed) to keep the visual language consistent.
    var indicatorColor: Color {
        switch self {
        case .working: .statusWorking
        case .blocked: .red
        case .done: .green
        case .idle: .secondary
        case .unknown: .gray.opacity(0.5)
        }
    }
}

private extension Color {
    static let statusWorking = Color(nsColor: .statusWorking)
}
