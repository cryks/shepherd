// The values one agent resolves its templates against: the typed pane, the
// verbatim herdr records for that pane's agent / workspace / tab, the excerpt
// currently displayable for it, and the label naming its endpoint.
//
// This file owns the variable namespace, in one place, because a row and a
// notification must resolve the same name to the same value. Two layers share
// it: `herdr.agent.` / `herdr.workspace.` / `herdr.tab.` walk the raw records
// under herdr's own snake_case keys, and unprefixed names are Shepherd-derived
// (a stripped title, a shortened cwd, the excerpt, the source label, the brand
// mark, the status glyph) and never merge into the herdr layer. A name outside
// both layers resolves to nil, which the template layer renders as empty.
//
// A context performs no lookup of its own: FleetStore.rowContext(for:)
// assembles it from the endpoint's current snapshot. A context built from a
// pane alone carries no raw records, and then every `herdr.*` name resolves
// empty rather than failing.

import AppKit
import Foundation

/// Everything one row needs to resolve template variables.
struct AgentRowContext: Equatable, Sendable {
    /// The pane as the typed model sees it. The status icon slot and the
    /// `status` style preset read it directly, outside any template.
    let pane: Pane
    /// This pane's `agents[]` element of session.snapshot.
    let rawAgent: JSONValue?
    /// The `workspaces[]` element of the pane's own workspace, carrying the
    /// branch Store injected under `branch`. Linked worktrees are merged into a
    /// single display group above this layer, and that merge never reaches this
    /// record.
    let rawWorkspace: JSONValue?
    /// The `tabs[]` element whose id is the pane's `tab_id`.
    let rawTab: JSONValue?
    /// Text for `{excerpt}`. nil whenever no excerpt is displayable: the
    /// preference is off, the agent has no supported grammar, or the read is
    /// still loading or produced nothing.
    let excerpt: String?
    /// Text for `{source}`. nil when no remote is visible, so a label naming
    /// the only endpoint there is never reaches a row or a notification.
    let sourceLabel: String?

    init(
        pane: Pane,
        rawAgent: JSONValue? = nil,
        rawWorkspace: JSONValue? = nil,
        rawTab: JSONValue? = nil,
        excerpt: String? = nil,
        sourceLabel: String? = nil
    ) {
        self.pane = pane
        self.rawAgent = rawAgent
        self.rawWorkspace = rawWorkspace
        self.rawTab = rawTab
        self.excerpt = excerpt
        self.sourceLabel = sourceLabel
    }

    /// Resolves one template variable name. Returns nil for names the language
    /// does not define, which templates render as empty.
    @MainActor
    func templateValue(for name: String) -> TemplateValue? {
        resolve(name, textOnly: false)
    }

    /// Resolution for a context with no place to draw an image and no excerpt
    /// of its own: `{agent_icon}` and `{excerpt}` return nil, so they neither
    /// print nor satisfy a `{a|b}` alternative nor keep a `[...]` group. Every
    /// other name resolves exactly as in a row. Notification templates render
    /// through this; AttentionNoticeStager appends the excerpt to the body.
    @MainActor
    func textTemplateValue(for name: String) -> TemplateValue? {
        resolve(name, textOnly: true)
    }

    @MainActor
    private func resolve(_ name: String, textOnly: Bool) -> TemplateValue? {
        if let path = Self.path(of: name, under: "herdr.agent.") {
            return Self.value(rawAgent?.value(at: path))
        }
        if let path = Self.path(of: name, under: "herdr.workspace.") {
            return Self.value(rawWorkspace?.value(at: path))
        }
        if let path = Self.path(of: name, under: "herdr.tab.") {
            return Self.value(rawTab?.value(at: path))
        }

        switch name {
        case "title":
            return .text(strippedTitle)
        case "cwd_short":
            guard let cwd else { return nil }
            return .text(Self.abbreviatingHome(cwd))
        case "cwd_name":
            guard let cwd else { return nil }
            return .text(URL(fileURLWithPath: cwd).lastPathComponent)
        case "excerpt":
            guard !textOnly, let excerpt else { return nil }
            return .text(excerpt)
        case "source":
            guard let sourceLabel else { return nil }
            return .text(sourceLabel)
        case "agent_icon":
            guard !textOnly else { return nil }
            return agentIcon
        case "status_emoji":
            return .text(Self.statusEmoji(pane.agentStatus))
        default:
            return nil
        }
    }

    /// Dotted path below `prefix`, or nil when the name belongs to another
    /// layer. `herdr.agent.` with nothing after it yields an empty path, which
    /// addresses the record itself and has no text form.
    private static func path(of name: String, under prefix: String) -> [Substring]? {
        guard name.hasPrefix(prefix) else { return nil }
        return name.dropFirst(prefix.count).split(separator: ".")
    }

    private static func value(_ json: JSONValue?) -> TemplateValue? {
        guard let text = json?.templateText else { return nil }
        return .text(text)
    }

    /// While Codex waits for input it retitles its terminal to
    /// "[ ! ] Action Required | <task>", blinking the bracketed glyph between
    /// "!" and ".". herdr's stripped title keeps that decoration; the status
    /// icon and the notification glyph already carry the blocked state, so
    /// `{title}` keeps only the task part. The anchor makes it a prefix rule: a
    /// title that merely quotes the phrase is left alone.
    private static let codexActionRequiredPrefix = #/^\[ . \] Action Required \| /#

    /// `{title}`. Empty when herdr has no title yet and when the title was
    /// nothing but the Codex prefix; a template that wants a fallback writes
    /// `{title|herdr.agent.agent}`.
    private var strippedTitle: String {
        guard var title = pane.terminalTitleStripped else { return "" }
        title.replace(Self.codexActionRequiredPrefix, with: "")
        return title
    }

    /// Working directory backing `{cwd_short}` and `{cwd_name}`. Read from the
    /// raw record because the typed Pane does not carry it.
    private var cwd: String? {
        guard case .string(let cwd)? = rawAgent?["cwd"], !cwd.isEmpty else { return nil }
        return cwd
    }

    /// Replaces the home directory with `~`. The comparison is made against
    /// home plus a separator, so a sibling directory whose name merely starts
    /// with the home directory's name keeps its full path.
    private static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    /// `{agent_icon}`. nil for a pane with no detected agent and for an agent
    /// with no mark asset, so `{agent_icon|herdr.agent.agent}` falls through to
    /// the agent name. The style the row draws it in is the row's choice; both
    /// variants ship together, so mono answers the existence question.
    @MainActor
    private var agentIcon: TemplateValue? {
        guard let agent = pane.agent, AgentIcons.icon(for: agent) != nil else { return nil }
        return .icon(agent: agent)
    }

    /// `{status_emoji}`. The color family matches the menu bar icons and
    /// AgentStatus.indicatorColor; idle and unknown share one glyph because a
    /// notification only ever shows blocked or done.
    private static func statusEmoji(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: "🔴"
        case .done: "🟢"
        case .working: "🟡"
        case .idle, .unknown: "⚪"
        }
    }
}
