import AppKit
import SwiftUI

struct AgentGroupList: View {
    let sourceID: HerdrSourceID
    let groups: [(workspace: Workspace, panes: [Pane])]
    let hoverStyle: AgentRow.HoverStyle
    // `groups` and this lookup come from the same snapshot, so nil means the
    // pane is gone and the row is dropped rather than drawn stale.
    let rowContext: (SourcePaneID) -> AgentRowContext?
    let highlightedPaneID: SourcePaneID?
    let excerptState: ((SourcePaneID) -> AgentExcerptState?)?
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
                    // ForEach identity only drives diffing; MonitorView's
                    // ScrollViewReader needs this explicit view identity.
                    .id(identifiedPane.id)
                }
            }
        }
        // 5pt is the inset MenuPanel's MenuItems keep from the surface edge,
        // so highlights line up in the same panel. Vertical spacing differs
        // per placement, so SourceList owns it.
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
    // The same row appears in the monitor window's List and in the menu panel,
    // whose native selection idioms differ, so the caller picks.
    enum HoverStyle {
        case list
        // Reproduces NSMenu selection to match MenuPanel's MenuItems.
        case menu
    }

    let context: AgentRowContext
    let hoverStyle: HoverStyle
    let isRevealed: Bool
    let excerptState: AgentExcerptState?
    let reservesExcerptLine: Bool
    // nil marks a remote, monitor-only row: no Button, no hover feedback.
    let onFocus: (() -> Void)?

    @State private var isHovered = false
    @AppStorage(colorAgentIconsKey) private var colorAgentIcons = false
    @Environment(\.colorScheme) private var colorScheme

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
        // Every preset states its color hierarchically or branches on hover, so
        // this single switch inverts the whole row with no per-line handling.
        .foregroundStyle(isMenuHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
        .background(
            rowBackground,
            in: RoundedRectangle(cornerRadius: hoverCornerRadius, style: .continuous)
        )
        .onHover { isHovered = onFocus == nil ? false : $0 }
    }

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

    // Read during body evaluation so a settings edit redraws mounted rows.
    private var lines: [RowLine] {
        RowLayoutSetting.shared.layout.lines(forAgent: context.pane.agent)
    }

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
        // Aligning at the center of the lowercase body keeps a small status
        // caption optically level with taller text: line-box .center sits it
        // visibly high and .firstTextBaseline visibly low, because the fonts
        // distribute leading and descent differently. Anchoring on the first
        // baseline also keeps the right side beside the first line when the
        // left side wraps.
        HStack(alignment: .xHeightCenter, spacing: 6) {
            runsView(left, style: line.leftStyle)
                .lineLimit(line.maxLines)
                .truncationMode(.tail)
                .alignmentGuide(.xHeightCenter) { xHeightCenter($0, line.leftStyle) }
            // Skipping the Spacer keeps an empty right template from spending
            // width, so the left side truncates at the same column it would
            // reach on a line with no right template at all.
            if !right.isEmpty {
                Spacer()
                // Priority keeps the status on the row and truncates the title
                // instead of pushing it off.
                runsView(right, style: line.rightStyle)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .alignmentGuide(.xHeightCenter) { xHeightCenter($0, line.rightStyle) }
            }
        }
    }

    private func xHeightCenter(_ d: ViewDimensions, _ style: RowTextStyle) -> CGFloat {
        d[.firstTextBaseline]
            - NSFont.preferredFont(forTextStyle: style.appKitTextStyle).xHeight / 2
    }

    // The placeholder alone sets the height in all three states, so the menu
    // panel does not resize when the first excerpt arrives and a wrapping
    // excerpt cannot grow it either.
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
                // Overlay content does not take part in vertical measurement,
                // so fallback glyph metrics cannot resize the menu. topLeading
                // starts a short excerpt at the first reserved row.
                .overlay(alignment: .topLeading) {
                    // The overlay proposes the placeholder's laid-out height,
                    // which pixel alignment can leave a fraction short of what
                    // maxLines wrapped lines need (45.0pt snaps to 44.5pt at 2x
                    // for proportional callout), and Text answers by dropping a
                    // line. Ignoring the proposal draws every row; overflow
                    // stays sub-pixel because both sides use the same metrics.
                    lineContent(line, left: left, right: right)
                        .fixedSize(horizontal: false, vertical: true)
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

    @ViewBuilder
    private func runsView(_ runs: [TemplateRun], style: RowTextStyle) -> some View {
        if runs.count == 1, case .text(let text) = runs[0] {
            Text(text)
                .modifier(rowTextStyle(style))
        } else {
            // spacing 0: the separation around a mark is written in the
            // template (`{agent_icon}[ {…}]`), not imposed here.
            HStack(spacing: 0) {
                // Runs carry no identity and a re-render replaces the whole
                // line, so position is the only identity available.
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

    // Template follows the line color. Original keeps the brand hues. An
    // agent with no asset draws nothing, because the resolver already
    // reported it empty and a `{agent_icon|…}` fallback has taken over.
    @ViewBuilder
    private func agentIcon(_ agent: String, style: RowTextStyle) -> some View {
        let iconStyle: AgentIconStyle = colorAgentIcons ? .color : .mono
        if let mark = AgentIcons.icon(for: agent, style: iconStyle) {
            let size = Self.iconSize(for: style)
            let template = iconStyle.usesTemplate(
                agent: agent,
                appearanceIsDark: colorScheme == .dark
            )
            Image(nsImage: mark)
                .renderingMode(template ? .template : .original)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .help(agent)
        }
    }

    // 11pt was tuned against the 12pt .callout sub-line; keeping that ratio
    // sizes a mark against whichever preset it sits in.
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

    private var isMenuHighlighted: Bool { isHovered && hoverStyle == .menu }

    private var rowBackground: AnyShapeStyle {
        if isRevealed { return AnyShapeStyle(.quaternary) }
        guard isHovered else { return AnyShapeStyle(.clear) }
        switch hoverStyle {
        case .list: return AnyShapeStyle(.quaternary)
        case .menu: return AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor))
        }
    }

    // 9 is the concentric radius of MenuPanel's ~14pt outer corner minus the
    // 5pt inset, so the highlight matches the MenuItems below it.
    private var hoverCornerRadius: CGFloat {
        switch hoverStyle {
        case .list: 6
        case .menu: 9
        }
    }
}

// Colors stay hierarchical or branch on hover, never an absolute Color, so the
// row's single foregroundStyle switch still inverts a highlighted menu line.
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
            content.font(.callout.monospaced()).foregroundStyle(.secondary)
        case .status:
            // Native menus invert selected text uniformly, so the semantic
            // status color gives way to the parent color while highlighted.
            //
            // Semibold: this is the one preset drawn in a saturated hue, and at
            // caption size those hues carry too little contrast on the light
            // menu background. Extra stroke weight restores it without
            // darkening the hue.
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

private extension VerticalAlignment {
    struct XHeightCenterID: AlignmentID {
        // Both sides set the guide themselves; this only covers views that
        // never do, such as the Spacer between them.
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }

    static let xHeightCenter = VerticalAlignment(XHeightCenterID.self)
}

private extension RowTextStyle {
    // Used only to measure a mark against the text beside it; the text itself
    // is drawn with SwiftUI fonts.
    var appKitTextStyle: NSFont.TextStyle {
        switch self {
        case .heading: .body
        case .body, .subdued, .monospace: .callout
        case .status: .caption1
        }
    }
}

extension AgentStatus {
    // Matches the colors StatusIcons strokes its circles with (statusWorking /
    // systemGreen / systemRed).
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
