// How an agent row is drawn and what a notification says, as a persisted
// value: an ordered list of lines (each a left and a right template with its
// own style), per-agent replacements of that list, and the three notification
// templates.
//
// RowLayoutSetting is the sole writer of the "AgentRowLayout" default. It holds
// the layout already parsed, so a row reading templates during body evaluation
// never re-parses JSON, and being @Observable an edit in the settings pane
// redraws every mounted row.
//
// Storage contract: the key stays absent until the user edits the layout, and
// an absent or undecodable value reads as RowLayout.default, so hand-edited
// defaults cannot break launch.

import Foundation
import Observation

/// One line of a row: two templates side by side, each with its own style.
/// A line whose left and right both render empty is dropped by the view layer.
struct RowLine: Codable, Equatable, Sendable, Identifiable {
    /// Identity for the settings editor's list and for SwiftUI diffing. It has
    /// no meaning to rendering.
    var id: UUID
    var left: RowTemplate
    var leftStyle: RowTextStyle
    var right: RowTemplate
    var rightStyle: RowTextStyle

    init(
        id: UUID = UUID(),
        left: RowTemplate,
        leftStyle: RowTextStyle,
        right: RowTemplate,
        rightStyle: RowTextStyle
    ) {
        self.id = id
        self.left = left
        self.leftStyle = leftStyle
        self.right = right
        self.rightStyle = rightStyle
    }

    /// `id` is generated when the stored JSON omits it, so a hand-written
    /// layout only has to name the templates and their styles.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        left = try container.decode(RowTemplate.self, forKey: .left)
        leftStyle = try container.decode(RowTextStyle.self, forKey: .leftStyle)
        right = try container.decode(RowTemplate.self, forKey: .right)
        rightStyle = try container.decode(RowTextStyle.self, forKey: .rightStyle)
    }
}

/// The three fields of a notification, rendered text-only. `{excerpt}` and
/// `{agent_icon}` resolve empty here; AttentionNoticeStager appends the excerpt
/// to the body itself.
struct NotificationTemplates: Codable, Equatable, Sendable {
    var title: RowTemplate
    var subtitle: RowTemplate
    var body: RowTemplate
}

struct RowLayout: Codable, Equatable, Sendable {
    var lines: [RowLine]
    /// Keyed by herdr's agent id (claude, codex, ...). An entry REPLACES
    /// `lines` entirely for that agent; nothing is merged.
    var linesByAgent: [String: [RowLine]]
    var notification: NotificationTemplates

    /// Reproduces the row and notification text the app shows before any edit.
    static let `default` = RowLayout(
        lines: [
            RowLine(
                left: RowTemplate("{title|herdr.agent.agent}"),
                leftStyle: .heading,
                right: RowTemplate("{herdr.agent.agent_status}"),
                rightStyle: .status
            ),
            RowLine(
                left: RowTemplate("{agent_icon|herdr.agent.agent}[ {herdr.workspace.branch}]"),
                leftStyle: .subdued,
                right: RowTemplate(""),
                rightStyle: .subdued
            ),
            RowLine(
                left: RowTemplate("{excerpt}"),
                leftStyle: .monospace,
                right: RowTemplate(""),
                rightStyle: .monospace
            ),
        ],
        linesByAgent: [:],
        notification: NotificationTemplates(
            title: RowTemplate("{status_emoji} {title|herdr.agent.agent}"),
            subtitle: RowTemplate("[{source} · ]{herdr.workspace.label|herdr.workspace.workspace_id}"),
            body: RowTemplate("{herdr.agent.agent}[ · {herdr.workspace.branch}]")
        )
    )

    /// Lines used for one pane: the per-agent override when present, else
    /// `lines`. A pane with no detected agent always gets `lines`.
    func lines(forAgent agent: String?) -> [RowLine] {
        guard let agent, let override = linesByAgent[agent] else { return lines }
        return override
    }
}

/// The sole writer of the row layout preference. Being @Observable, rows and
/// the settings preview that read `layout` during body evaluation are redrawn
/// as the user edits.
@Observable @MainActor
final class RowLayoutSetting {
    static let shared = RowLayoutSetting()

    /// UserDefaults key holding the layout as JSON Data.
    static let layoutKey = "AgentRowLayout"

    /// Row and notification templates in effect. Persisted on every write.
    var layout: RowLayout {
        didSet {
            guard let data = try? JSONEncoder().encode(layout) else { return }
            defaults.set(data, forKey: Self.layoutKey)
        }
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: Storage destination. The app proper uses standard;
    ///   tests pass a dedicated suite. A missing key reads as RowLayout.default
    ///   and is not written back, so the app keeps following the built-in
    ///   layout until the user edits it. Undecodable data reads as the default
    ///   too, and stays stored until the next edit replaces it.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = defaults.data(forKey: Self.layoutKey)
            .flatMap { try? JSONDecoder().decode(RowLayout.self, from: $0) }
            ?? .default
    }

    /// Drops the stored value so the built-in defaults apply again.
    /// The assignment goes through `layout` so observers redraw; removing the
    /// key afterwards undoes the write it triggered, leaving storage in the
    /// same never-edited state as on a fresh install.
    func resetToDefault() {
        layout = .default
        defaults.removeObject(forKey: Self.layoutKey)
    }
}
