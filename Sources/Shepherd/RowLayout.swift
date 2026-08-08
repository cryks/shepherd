import Foundation
import Observation

struct RowLine: Codable, Equatable, Sendable, Identifiable {
    // Only for the settings editor's list and SwiftUI diffing; rendering
    // ignores it.
    var id: UUID
    var left: RowTemplate
    var leftStyle: RowTextStyle
    var right: RowTemplate
    var rightStyle: RowTextStyle
    // Wrap limit for the left side only. The right side stays on the first
    // line so status text can never make the row taller.
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

    // Tolerant of hand-written JSON: `id` is generated when absent, and
    // `maxLines` clamps absent or sub-1 values so layouts stored before
    // maxLines existed still render one line.
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

struct NotificationLine: Codable, Equatable, Sendable, Identifiable {
    // Only for the settings editor's list and SwiftUI diffing; rendering
    // ignores it.
    var id: UUID
    var template: RowTemplate

    init(id: UUID = UUID(), _ template: RowTemplate) {
        self.id = id
        self.template = template
    }

    // The bare-string form lets a hand-written body be a plain list of
    // templates instead of a list of objects.
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

// Rendered text-only, so `{agent_icon}` resolves empty. `{excerpt}` is read
// only after the status transition, which is why AttentionNoticeStager owns
// rendering these. A macOS banner has one title and one subtitle, so only the
// body is a list.
struct NotificationTemplates: Codable, Equatable, Sendable {
    var title: RowTemplate
    var subtitle: RowTemplate
    var body: [NotificationLine]

    init(title: RowTemplate, subtitle: RowTemplate, body: [NotificationLine]) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    // A single template under `body` predates the body becoming a list. Back
    // then the excerpt was appended by the delivery path, so the migration has
    // to add the `{excerpt}` line that now carries that placement.
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
    // Keyed by herdr's agent id (claude, codex, ...). An entry replaces `lines`
    // entirely for that agent; nothing is merged.
    var linesByAgent: [String: [RowLine]]
    var notification: NotificationTemplates

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

    func lines(forAgent agent: String?) -> [RowLine] {
        guard let agent, let override = linesByAgent[agent] else { return lines }
        return override
    }
}

// The sole writer of the layout preference. It keeps the layout parsed so rows
// never decode JSON during body evaluation, and @Observable makes an edit in
// the settings pane redraw every mounted row.
@Observable @MainActor
final class RowLayoutSetting {
    static let shared = RowLayoutSetting()

    static let layoutKey = "AgentRowLayout"

    var layout: RowLayout {
        didSet {
            guard let data = try? JSONEncoder().encode(layout) else { return }
            defaults.set(data, forKey: Self.layoutKey)
        }
    }

    private let defaults: UserDefaults

    // Reading a missing or undecodable value as the default, without writing it
    // back, keeps hand-edited defaults from breaking launch and leaves the app
    // following the built-in layout until the user edits it.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        layout = defaults.data(forKey: Self.layoutKey)
            .flatMap { try? JSONDecoder().decode(RowLayout.self, from: $0) }
            ?? .default
    }

    // The assignment is what notifies observers; removing the key afterwards
    // undoes the write it triggered, so storage returns to the never-edited
    // state of a fresh install.
    func resetToDefault() {
        layout = .default
        defaults.removeObject(forKey: Self.layoutKey)
    }
}
