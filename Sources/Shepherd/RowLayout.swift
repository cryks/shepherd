// How an agent row is drawn and what a notification says, as a persisted
// value: an ordered list of lines (each a left and a right template with its
// own style), per-agent replacements of that list, and the notification
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
    /// How many lines the left side's text may wrap across before it
    /// truncates. The right side always stays on the first line, so status
    /// text cannot push the row taller. On the reserved {excerpt} line, menu
    /// rows keep this many lines of height in every state.
    var maxLines: Int

    init(
        id: UUID = UUID(),
        left: RowTemplate,
        leftStyle: RowTextStyle,
        right: RowTemplate,
        rightStyle: RowTextStyle,
        maxLines: Int = 1
    ) {
        self.id = id
        self.left = left
        self.leftStyle = leftStyle
        self.right = right
        self.rightStyle = rightStyle
        self.maxLines = maxLines
    }

    /// `id` is generated when the stored JSON omits it, so a hand-written
    /// layout only has to name the templates and their styles. `maxLines`
    /// reads absent or sub-1 values as 1, so a layout stored before lines
    /// had a count, and a hand-edited count of 0, both keep a single line.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        left = try container.decode(RowTemplate.self, forKey: .left)
        leftStyle = try container.decode(RowTextStyle.self, forKey: .leftStyle)
        right = try container.decode(RowTemplate.self, forKey: .right)
        rightStyle = try container.decode(RowTextStyle.self, forKey: .rightStyle)
        maxLines = max(
            1,
            try container.decodeIfPresent(Int.self, forKey: .maxLines) ?? 1
        )
    }
}

/// One line of a notification body.
struct NotificationLine: Codable, Equatable, Sendable, Identifiable {
    /// Identity for the settings editor's list and for SwiftUI diffing. It has
    /// no meaning to rendering.
    var id: UUID
    var template: RowTemplate

    init(id: UUID = UUID(), _ template: RowTemplate) {
        self.id = id
        self.template = template
    }

    /// Reads a bare template string as well as the keyed form, and generates
    /// `id` when it is absent, so a hand-written body can be a plain list of
    /// templates.
    init(from decoder: any Decoder) throws {
        if let source = try? decoder.singleValueContainer().decode(String.self) {
            id = UUID()
            template = RowTemplate(source)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        template = try container.decode(RowTemplate.self, forKey: .template)
    }
}

/// The fields of a notification, rendered text-only: `{agent_icon}` resolves
/// empty. `{excerpt}` holds the pane's excerpt, which is read after the status
/// transition, so AttentionNoticeStager is what renders these templates with a
/// value for it.
///
/// macOS gives a banner one title and one subtitle, so those stay single
/// templates. The body is a list: lines that render empty are dropped and the
/// rest are joined with newlines, which is how a body says nothing about a
/// branch when the pane has none.
struct NotificationTemplates: Codable, Equatable, Sendable {
    var title: RowTemplate
    var subtitle: RowTemplate
    var body: [NotificationLine]

    init(title: RowTemplate, subtitle: RowTemplate, body: [NotificationLine]) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// A single template under `body` is the form stored before the body became
    /// a list. It reads as that line followed by an `{excerpt}` line, because a
    /// body stored that way was delivered with the excerpt after it, and the
    /// list is now the only thing that says where the excerpt goes.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(RowTemplate.self, forKey: .title)
        subtitle = try container.decode(RowTemplate.self, forKey: .subtitle)
        if let lines = try? container.decode([NotificationLine].self, forKey: .body) {
            body = lines
        } else {
            body = [
                NotificationLine(try container.decode(RowTemplate.self, forKey: .body)),
                NotificationLine(RowTemplate("{excerpt}")),
            ]
        }
    }
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
            body: [
                NotificationLine(RowTemplate("{herdr.agent.agent}[ · {herdr.workspace.branch}]")),
                NotificationLine(RowTemplate("{excerpt}")),
            ]
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
