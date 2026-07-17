// Multi-endpoint list shared by the menu panel and the pop-out window. While at
// least one remote is visible, headers separate the endpoints, and a remote
// keeps its header even with monitoring OFF. The local header is omitted when
// the local endpoint is the only one, or when LocalSectionTitleSetting is set
// to hidden, in which case the agent rows are laid out directly.
// onFocus is passed only for local; remote rows keep the same information
// density but are monitor-only.
//
// The same section column is rendered two ways via Style:
// - menu: NSMenu-style, laying rows directly on the panel surface. Headers use
//   headline, and remote headers carry a monitoring ON/OFF checkbox (when OFF,
//   the checkbox conveys the state, so no body is drawn).
// - window: settings-app style, floating each section body above the window
//   background as a rounded card. No checkbox; monitoring OFF is shown as a
//   single line inside the card.

import SwiftUI

struct SourceList: View {
    /// Presentation per hosting surface. Row hover rendering (AgentRow.HoverStyle) follows the surface too.
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
    let onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)?
    let onLocalFocus: (Pane) -> Void

    init(
        sections: [FleetSourceSection],
        style: Style,
        onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)? = nil,
        onLocalFocus: @escaping (Pane) -> Void
    ) {
        self.sections = sections
        self.style = style
        self.onRemoteEnabledChange = onRemoteEnabledChange
        self.onLocalFocus = onLocalFocus
    }

    /// Header visibility: a list with no remote sections is local-only, so the
    /// header serves no purpose in distinguishing endpoints and is omitted. When
    /// remotes exist, each section's headerTitle is honored (only the local
    /// hidden setting returns nil).
    private var hasRemoteSections: Bool {
        sections.contains(where: \.isRemote)
    }

    var body: some View {
        switch style {
        case .menu: menuLayout
        case .window: windowLayout
        }
    }

    // MARK: - menu

    private var menuLayout: some View {
        // MenuPanel derives the window height from the content's actual size, so
        // use a VStack that can measure every source rather than a lazy stack.
        // The number of visible items is bounded by Herdr's parent agent count.
        // spacing 16 combines with the trailing row's 3pt bottom to make 19pt —
        // one step wider than the workspace header separation (11pt), so an
        // endpoint boundary reads stronger than a workspace boundary.
        let showsFirstHeader = hasRemoteSections && sections.first?.headerTitle != nil
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                MenuSourceSection(
                    section: section,
                    headerTitle: hasRemoteSections ? section.headerTitle : nil,
                    onRemoteEnabledChange: onRemoteEnabledChange,
                    onLocalFocus: onLocalFocus
                )
            }
        }
        // Normalize the effective top margin to 12pt: when the first section
        // (always local) shows a header, the header itself carries no top margin,
        // so 12pt is used as-is; without a header the first element is a workspace
        // header (which carries 6pt top), so 6pt is added for a total of 12pt.
        // This 12pt is also the value that lets the leading text clear the curve
        // of the menu panel's outer corner radius (about 12pt). The 8pt bottom
        // combines with the trailing row's 3pt bottom for an effective 11pt
        // margin, roughly symmetric with the 12pt top.
        .padding(.top, showsFirstHeader ? 12 : 6)
        .padding(.bottom, 8)
    }

    // MARK: - window

    private var windowLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                WindowSourceSection(
                    section: section,
                    headerTitle: hasRemoteSections ? section.headerTitle : nil,
                    onLocalFocus: onLocalFocus
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

// MARK: - Menu panel section

private struct MenuSourceSection: View {
    let section: FleetSourceSection
    /// Header row string. nil means no header (the local endpoint is the only
    /// one, or the local hidden setting). Remote sections put the checkbox in
    /// the header, so while remotes exist the caller always passes non-nil.
    let headerTitle: String?
    let onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)?
    let onLocalFocus: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let headerTitle {
                header(title: headerTitle)
                    .padding(.horizontal, 17)
                    // With monitoring off there are no body rows and the header
                    // becomes the section's last element, so give it the same 3pt
                    // bottom as a row to keep the 19pt total with the 16pt section spacing.
                    .padding(.bottom, section.state == .disabled ? 3 : 0)
            }

            if section.state == .ready {
                if section.workspaceGroups.isEmpty {
                    stateMessage(tr("No agents", ja: "エージェントがいません"))
                } else {
                    AgentGroupList(
                        sourceID: section.id,
                        groups: section.workspaceGroups,
                        hoverStyle: .menu,
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
            // Match AgentGroupList's vertical rhythm: 8pt from the header when
            // combined with the VStack spacing of 2 (same as a workspace header),
            // and the same 3pt as a row toward the section boundary, adding to
            // the 16pt section spacing.
            .padding(.top, 6)
            .padding(.bottom, 3)
    }
}

// MARK: - Pop-out window section

/// Wraps the section body in a rounded card. The header is a label outside the
/// card; inside the card is the same AgentGroupList as menu (workspace headers
/// + rows). There is no checkbox, so monitoring OFF is shown as a single
/// "monitoring off" line inside the card.
private struct WindowSourceSection: View {
    let section: FleetSourceSection
    /// Header row string. nil means no header (the local endpoint is the only
    /// one, or the local hidden setting), and only the card is drawn.
    let headerTitle: String?
    let onLocalFocus: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let headerTitle {
                // Label outside the card. One step smaller and dimmer than the
                // card's text to establish hierarchy against the card (content).
                // The 4pt horizontal padding is a fine-tune for the visual
                // alignment between the card's corner curve and the text's left edge.
                Text(headerTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                            onFocus: section.isRemote ? nil : onLocalFocus
                        )
                    }
                }
            } else if section.state == .disabled {
                // In menu the header checkbox conveys OFF, but window has no
                // checkbox, so the state string ("monitoring off") is shown as the body.
                card { stateMessage(MonitoredSourceState.disabled.message) }
            } else if let message = section.statusMessage {
                card { stateMessage(message) }
            }
        }
    }

    /// Body surface floated one step above the window background. A hairline
    /// border is layered over the quinary fill so the outline stays visible in
    /// both light and dark appearances.
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
            // Same left edge as AgentGroupList's row text (5 + 12 = 17pt).
            .padding(.horizontal, 17)
            .padding(.vertical, 4)
    }
}
