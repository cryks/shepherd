import SwiftUI

struct SourceList: View {
    enum Style {
        case menu
        case window

        var hoverStyle: AgentRow.HoverStyle {
            switch self {
            case .menu: .menu
            case .window: .list
            }
        }
    }

    let sections: [FleetSourceSection]
    let style: Style
    // The same flag also suppresses {source} in notification templates, so a
    // row and its notification never disagree about showing the endpoint name.
    let showsSourceLabels: Bool
    let highlightedPaneID: SourcePaneID?
    // nil for a pane that left its endpoint's snapshot between this list being
    // built and the row being drawn.
    let rowContext: (SourcePaneID) -> AgentRowContext?
    let excerptState: ((SourcePaneID) -> AgentExcerptState?)?
    let onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)?
    let onLocalFocus: (Pane) -> Void

    init(
        sections: [FleetSourceSection],
        style: Style,
        showsSourceLabels: Bool,
        rowContext: @escaping (SourcePaneID) -> AgentRowContext?,
        highlightedPaneID: SourcePaneID? = nil,
        excerptState: ((SourcePaneID) -> AgentExcerptState?)? = nil,
        onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)? = nil,
        onLocalFocus: @escaping (Pane) -> Void
    ) {
        self.sections = sections
        self.style = style
        self.showsSourceLabels = showsSourceLabels
        self.rowContext = rowContext
        self.highlightedPaneID = highlightedPaneID
        self.excerptState = excerptState
        self.onRemoteEnabledChange = onRemoteEnabledChange
        self.onLocalFocus = onLocalFocus
    }

    var body: some View {
        switch style {
        case .menu: menuLayout
        case .window: windowLayout
        }
    }

    // MARK: - menu

    private var menuLayout: some View {
        // MenuPanel sizes its window from the content's measured height, so a
        // lazy stack cannot be used. Item count is bounded by Herdr's parent
        // agent count. spacing 16 plus the trailing row's 3pt bottom gives 19pt,
        // one step wider than the 11pt between workspaces.
        let showsFirstHeader = showsSourceLabels && sections.first?.headerTitle != nil
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                MenuSourceSection(
                    section: section,
                    headerTitle: showsSourceLabels ? section.headerTitle : nil,
                    rowContext: rowContext,
                    excerptState: excerptState,
                    onRemoteEnabledChange: onRemoteEnabledChange,
                    onLocalFocus: onLocalFocus
                )
            }
        }
        // Both branches produce a 12pt effective top margin, which clears the
        // menu panel's outer corner curve: a header carries no top padding of
        // its own, while the workspace header below it already carries 6pt.
        // The 8pt bottom plus the trailing row's 3pt gives 11pt, near-symmetric.
        .padding(.top, showsFirstHeader ? 12 : 6)
        .padding(.bottom, 8)
    }

    // MARK: - window

    private var windowLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                WindowSourceSection(
                    section: section,
                    headerTitle: showsSourceLabels ? section.headerTitle : nil,
                    highlightedPaneID: highlightedPaneID,
                    rowContext: rowContext,
                    excerptState: excerptState,
                    onLocalFocus: onLocalFocus
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

// MARK: - Protocol warning

private struct ProtocolWarningBadge: View {
    let version: Int

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .imageScale(.small)
            .help(protocolWarningDescription(version))
            .accessibilityLabel(protocolWarningDescription(version))
    }
}

// Fallback for a section with no header to host the badge.
private struct ProtocolWarningLine: View {
    let version: Int

    var body: some View {
        Label {
            Text(protocolWarningDescription(version))
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
        }
        .font(.callout)
    }
}

// MARK: - Menu panel section

private struct MenuSourceSection: View {
    let section: FleetSourceSection
    // nil drops the header. A remote section hosts its monitoring checkbox in
    // the header, so callers never pass nil while remotes are visible.
    let headerTitle: String?
    let rowContext: (SourcePaneID) -> AgentRowContext?
    let excerptState: ((SourcePaneID) -> AgentExcerptState?)?
    let onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)?
    let onLocalFocus: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let headerTitle {
                header(title: headerTitle)
                    .padding(.horizontal, 17)
                    // With monitoring off the header is the section's last
                    // element, so it takes over a row's 3pt bottom to keep the
                    // 19pt gap between sections.
                    .padding(.bottom, section.state == .disabled ? 3 : 0)
            } else if let warning = section.protocolWarning {
                ProtocolWarningLine(version: warning)
                    .padding(.horizontal, 17)
            }

            if section.state == .ready {
                if section.workspaceGroups.isEmpty {
                    stateMessage(tr("No agents", ja: "エージェントがいません"))
                } else {
                    AgentGroupList(
                        sourceID: section.id,
                        groups: section.workspaceGroups,
                        hoverStyle: .menu,
                        rowContext: rowContext,
                        excerptState: excerptState,
                        // Hold the excerpt line's height up front, or the menu
                        // panel resizes each time an excerpt arrives.
                        reservesExcerptLine: true,
                        onFocus: section.isRemote ? nil : onLocalFocus
                    )
                }
            } else if let message = section.statusMessage {
                stateMessage(message)
            }
        }
    }

    @ViewBuilder
    private func header(title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            if let warning = section.protocolWarning {
                ProtocolWarningBadge(version: warning)
            }

            Spacer()

            if let configuration = section.configuration,
               let onRemoteEnabledChange {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { configuration.isEnabled },
                        set: { onRemoteEnabledChange(configuration.id, $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .accessibilityLabel(tr(
                    "Monitor \(configuration.displayName)",
                    ja: "\(configuration.displayName) の監視"
                ))
            }
        }
    }

    private func stateMessage(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            // Matches AgentGroupList's rhythm: 6 plus the VStack's 2 gives the
            // 8pt a workspace header keeps below the section header, and the
            // 3pt bottom is what a row contributes to the section gap.
            .padding(.top, 6)
            .padding(.bottom, 3)
    }
}

// MARK: - Pop-out window section

private struct WindowSourceSection: View {
    let section: FleetSourceSection
    // nil drops the header and draws the card alone.
    let headerTitle: String?
    // Set by notification navigation and may name a pane in another section,
    // so AgentGroupList compares the whole source-qualified ID.
    let highlightedPaneID: SourcePaneID?
    let rowContext: (SourcePaneID) -> AgentRowContext?
    let excerptState: ((SourcePaneID) -> AgentExcerptState?)?
    let onLocalFocus: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let headerTitle {
                // The 4pt inset makes the label's left edge look aligned with
                // the card below it, whose corner curve pulls its content in.
                HStack(spacing: 5) {
                    Text(headerTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if let warning = section.protocolWarning {
                        ProtocolWarningBadge(version: warning)
                    }
                }
                .padding(.horizontal, 4)
            } else if let warning = section.protocolWarning {
                ProtocolWarningLine(version: warning)
                    .padding(.horizontal, 4)
            }

            if section.state == .ready {
                if section.workspaceGroups.isEmpty {
                    card { stateMessage(tr("No agents", ja: "エージェントがいません")) }
                } else {
                    card {
                        AgentGroupList(
                            sourceID: section.id,
                            groups: section.workspaceGroups,
                            hoverStyle: .list,
                            rowContext: rowContext,
                            highlightedPaneID: highlightedPaneID,
                            excerptState: excerptState,
                            onFocus: section.isRemote ? nil : onLocalFocus
                        )
                    }
                }
            } else if section.state == .disabled {
                // This surface has no header checkbox to convey OFF, so the
                // state has to be spelled out in the body.
                card { stateMessage(MonitoredSourceState.disabled.message) }
            } else if let message = section.statusMessage {
                card { stateMessage(message) }
            }
        }
    }

    // The quinary fill alone does not separate from the window background in
    // every appearance, so a hairline border is layered over it.
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quinary,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }

    private func stateMessage(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            // 17 = the 5 + 12 that puts AgentGroupList's row text at this edge.
            .padding(.horizontal, 17)
            .padding(.vertical, 4)
    }
}
