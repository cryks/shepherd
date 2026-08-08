import AppKit
import Foundation

struct AgentRowContext: Equatable, Sendable {
    let pane: Pane
    let rawAgent: JSONValue?
    // The pane's own workspace record. Linked worktrees are merged into one
    // display group above this layer, and that merge never reaches it.
    let rawWorkspace: JSONValue?
    let rawTab: JSONValue?
    let excerpt: String?
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

    @MainActor
    func templateValue(for name: String) -> TemplateValue? {
        resolve(name, textOnly: false)
    }

    // For contexts with no place to draw an image and no excerpt of their own:
    // `{agent_icon}` and `{excerpt}` return nil so they neither print nor
    // satisfy a `{a|b}` alternative nor keep a `[...]` group. Notifications
    // render through this, and AttentionNoticeStager renders once more with the
    // pane's excerpt supplied.
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

    private static func path(of name: String, under prefix: String) -> [Substring]? {
        guard name.hasPrefix(prefix) else { return nil }
        return name.dropFirst(prefix.count).split(separator: ".")
    }

    private static func value(_ json: JSONValue?) -> TemplateValue? {
        guard let text = json?.templateText else { return nil }
        return .text(text)
    }

    // While Codex waits for input it retitles its terminal to
    // "[ ! ] Action Required | <task>", blinking the bracketed glyph between
    // "!" and ".". The status icon and the notification glyph already carry the
    // blocked state, so only the task part is kept. The anchor makes it a
    // prefix rule, leaving a title that merely quotes the phrase alone.
    private static let codexActionRequiredPrefix = #/^\[ . \] Action Required \| /#

    // Empty for a missing title and for a title that was nothing but the Codex
    // prefix; a template wanting a fallback writes `{title|herdr.agent.agent}`.
    private var strippedTitle: String {
        guard var title = pane.terminalTitleStripped else { return "" }
        title.replace(Self.codexActionRequiredPrefix, with: "")
        return title
    }

    // Read from the raw record because the typed Pane does not carry it.
    private var cwd: String? {
        guard case .string(let cwd)? = rawAgent?["cwd"], !cwd.isEmpty else { return nil }
        return cwd
    }

    // Compared against home plus a separator, so a sibling directory whose name
    // merely starts with the home directory's name keeps its full path.
    private static func abbreviatingHome(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard !home.isEmpty else { return path }
        if path == home { return "~" }
        let prefix = home.hasSuffix("/") ? home : home + "/"
        guard path.hasPrefix(prefix) else { return path }
        return "~/" + path.dropFirst(prefix.count)
    }

    // nil lets `{agent_icon|herdr.agent.agent}` fall through to the agent name.
    // Both style variants ship together, so the default one answers whether a
    // mark exists at all.
    @MainActor
    private var agentIcon: TemplateValue? {
        guard let agent = pane.agent, AgentIcons.icon(for: agent) != nil else { return nil }
        return .icon(agent: agent)
    }

    // The hues match the menu bar icons and indicatorColor. idle and unknown
    // share a glyph because a notification only ever shows blocked or done.
    private static func statusEmoji(_ status: AgentStatus) -> String {
        switch status {
        case .blocked: "🔴"
        case .done: "🟢"
        case .working: "🟡"
        case .idle, .unknown: "⚪"
        }
    }
}
