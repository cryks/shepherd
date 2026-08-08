import AppKit
import SwiftUI

// A legacy (always-visible) scroller draws over the content's trailing edge
// rather than beside it, so it would sit on the controls there. Overlay
// scrollers need no inset.
@MainActor
private var legacyScrollerInset: CGFloat {
    guard NSScroller.preferredScrollerStyle == .legacy else { return 0 }
    return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
}


struct DisplaySettingsView: View {
    let store: FleetStore

    // Sized for a menu-width row (MenuPanel lays rows at 340pt) plus the card
    // and column insets around it.
    private static let previewColumnWidth: CGFloat = 320

    @Bindable private var layoutSetting = RowLayoutSetting.shared
    @AppStorage(colorAgentIconsKey) private var colorAgentIcons = false
    // Sampled on appear instead of read during body evaluation: the catalog
    // comes from snapshots that change on every poll, so observing it here
    // would rebuild the editor, text fields included, twice a second.
    @State private var catalog = TemplateVariableCatalog.empty
    @State private var overrideEditor: AgentOverrideEditorContext?
    @State private var overrideRemovalCandidate: String?
    @State private var restoreTarget: RestoreTarget?

    var body: some View {
        HStack(spacing: 0) {
            editor(catalog: catalog)
            Divider()
            RowLayoutPreviewColumn(store: store)
                .frame(width: Self.previewColumnWidth)
        }
        .onAppear {
            catalog = TemplateVariableCatalog(store: store)
            // AppKit makes the first template field the initial first
            // responder when the window comes front or this tab is selected.
            // defaultFocus is ignored in a Settings scene, so the choice is
            // undone one runloop turn after the turn that made it.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .sheet(item: $overrideEditor) { context in
            AgentOverrideEditor(
                context: context,
                catalog: catalog,
                existingAgents: Set(layoutSetting.layout.linesByAgent.keys)
            ) { agent, lines in
                layoutSetting.layout.linesByAgent[agent] = lines
            }
        }
        .alert(
            restoreTarget?.confirmationTitle ?? "",
            isPresented: Binding(
                get: { restoreTarget != nil },
                set: { if !$0 { restoreTarget = nil } }
            ),
            presenting: restoreTarget
        ) { target in
            Button(tr("Restore", ja: "戻す"), role: .destructive) {
                restore(target)
                restoreTarget = nil
            }
            Button(tr("Cancel", ja: "キャンセル"), role: .cancel) {
                restoreTarget = nil
            }
        } message: { target in
            Text(target.confirmationMessage)
        }
        .alert(
            tr("Delete this override?", ja: "この上書きを削除しますか？"),
            isPresented: Binding(
                get: { overrideRemovalCandidate != nil },
                set: { if !$0 { overrideRemovalCandidate = nil } }
            ),
            presenting: overrideRemovalCandidate
        ) { agent in
            Button(tr("Delete", ja: "削除"), role: .destructive) {
                layoutSetting.layout.linesByAgent.removeValue(forKey: agent)
                overrideRemovalCandidate = nil
            }
            Button(tr("Cancel", ja: "キャンセル"), role: .cancel) {
                overrideRemovalCandidate = nil
            }
        } message: { agent in
            Text(tr(
                "\(agent) goes back to the rows above.",
                ja: "\(agent) は上の行に戻ります。"
            ))
        }
    }

    // MARK: - Editor column

    // Fields sit in a ScrollView, not a List: an NSTableView-backed list takes
    // clicks for row handling before its field editor sees them, which reads
    // as text fields that ignore the click.
    private func editor(catalog: TemplateVariableCatalog) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                editorSection(tr("Icons", ja: "アイコン")) {
                    Toggle(
                        tr("Show agent icons in color", ja: "エージェントアイコンをカラーで表示"),
                        isOn: $colorAgentIcons
                    )
                }

                editorSection(tr("Rows", ja: "行"), restore: .rows) {
                    RowLineList(lines: $layoutSetting.layout.lines, catalog: catalog)
                }

                editorSection(
                    tr("Per-agent", ja: "エージェント別"),
                    restore: .overrides,
                    footer: tr(
                        "An agent listed here uses its own lines instead of the rows above.",
                        ja: "ここに並ぶエージェントは、上の行の代わりに専用の行を使います。"
                    )
                ) {
                    overrideRows
                }

                editorSection(
                    tr("Notifications", ja: "通知"),
                    restore: .notifications,
                    footer: tr(
                        "Notifications are text only, so {agent_icon} stays empty. A body line that renders empty is left out.",
                        ja: "通知はテキストのみなので {agent_icon} は空になります。空になった本文の行は出ません。"
                    )
                ) {
                    TemplateField(
                        label: tr("Title", ja: "タイトル"),
                        labelWidth: Self.notificationLabelWidth,
                        template: $layoutSetting.layout.notification.title,
                        catalog: catalog
                    )
                    TemplateField(
                        label: tr("Subtitle", ja: "サブタイトル"),
                        labelWidth: Self.notificationLabelWidth,
                        template: $layoutSetting.layout.notification.subtitle,
                        catalog: catalog
                    )
                    NotificationBodyList(
                        lines: $layoutSetting.layout.notification.body,
                        labelWidth: Self.notificationLabelWidth,
                        catalog: catalog
                    )
                }
            }
            .padding(14)
            .padding(.trailing, legacyScrollerInset)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
    }

    private func editorSection(
        _ title: String,
        restore: RestoreTarget? = nil,
        footer: String? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let restore {
                    Button(tr("Restore Defaults", ja: "初期状態に戻す")) {
                        restoreTarget = restore
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let notificationLabelWidth: CGFloat = 74

    @ViewBuilder
    private var overrideRows: some View {
        ForEach(layoutSetting.layout.linesByAgent.keys.sorted(), id: \.self) { agent in
            HStack(spacing: 8) {
                Text(verbatim: agent)
                Text(lineCount(layoutSetting.layout.linesByAgent[agent]?.count ?? 0))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    overrideEditor = AgentOverrideEditorContext(
                        agent: agent,
                        lines: layoutSetting.layout.linesByAgent[agent] ?? [],
                        isNew: false
                    )
                } label: {
                    Label(tr("Edit", ja: "編集"), systemImage: "pencil")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)

                Button(role: .destructive) {
                    overrideRemovalCandidate = agent
                } label: {
                    Label(tr("Delete", ja: "削除"), systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }

        Button {
            overrideEditor = AgentOverrideEditorContext(
                agent: "",
                lines: layoutSetting.layout.lines,
                isNew: true
            )
        } label: {
            Label(tr("Add Agent", ja: "エージェントを追加"), systemImage: "plus")
        }
        .buttonStyle(.borderless)
    }

    private func lineCount(_ count: Int) -> String {
        tr(count == 1 ? "1 line" : "\(count) lines", ja: "\(count) 行")
    }

    private func restore(_ target: RestoreTarget) {
        switch target {
        case .rows:
            layoutSetting.layout.lines = RowLayout.default.lines
        case .overrides:
            layoutSetting.layout.linesByAgent = RowLayout.default.linesByAgent
        case .notifications:
            layoutSetting.layout.notification = RowLayout.default.notification
        }
    }
}

private enum RestoreTarget: String, Identifiable {
    case rows
    case overrides
    case notifications

    var id: String { rawValue }

    @MainActor var confirmationTitle: String {
        switch self {
        case .rows:
            tr("Restore the default rows?", ja: "行を初期状態に戻しますか？")
        case .overrides:
            tr("Delete every per-agent override?", ja: "エージェント別の上書きをすべて削除しますか？")
        case .notifications:
            tr(
                "Restore the default notification templates?",
                ja: "通知のテンプレートを初期状態に戻しますか？"
            )
        }
    }

    @MainActor var confirmationMessage: String {
        switch self {
        case .rows, .notifications:
            tr("Your edits are discarded.", ja: "編集内容は破棄されます。")
        case .overrides:
            tr("Every agent goes back to the rows above.", ja: "すべてのエージェントが上の行に戻ります。")
        }
    }
}

// MARK: - Line list

private struct RowLineList: View {
    @Binding var lines: [RowLine]
    let catalog: TemplateVariableCatalog

    @State private var reorder = RowReorder<UUID>()

    var body: some View {
        ForEach($lines) { $line in
            RowLineEditor(
                line: $line,
                grabber: RowGrabber(
                    id: line.id,
                    order: lines.map(\.id),
                    reorder: reorder,
                    move: { lines.move(fromOffsets: $0, toOffset: $1) }
                ),
                catalog: catalog,
                onDelete: { lines.removeAll { $0.id == line.id } }
            )
            .reorderableRow(reorder, id: line.id)
            if line.id != lines.last?.id {
                Divider()
            }
        }

        Button {
            lines.append(
                RowLine(
                    left: RowTemplate(""),
                    leftStyle: .body,
                    right: RowTemplate(""),
                    rightStyle: .body
                )
            )
        } label: {
            Label(tr("Add Line", ja: "行を追加"), systemImage: "plus")
        }
        .buttonStyle(.borderless)
    }
}

private struct RowLineEditor: View {
    @Binding var line: RowLine
    let grabber: RowGrabber<UUID>
    let catalog: TemplateVariableCatalog
    let onDelete: () -> Void

    private static let sideLabelWidth: CGFloat = 34

    var body: some View {
        HStack(spacing: 8) {
            // The grabber drags the whole line, so its hit strip spans both
            // template rows.
            grabber
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 6) {
                side(
                    label: tr("Left", ja: "左"),
                    template: $line.left,
                    style: $line.leftStyle
                )
                side(
                    label: tr("Right", ja: "右"),
                    template: $line.right,
                    style: $line.rightStyle
                )
            }

            // Five lines already outruns the 240-character excerpt cap at menu
            // width, so a larger count would only reserve blank height.
            Stepper(value: $line.maxLines, in: 1...5) {
                Text(lineCountLabel)
            }
            .fixedSize()
            .help(tr(
                "Lines the left side may wrap across",
                ja: "左側を折り返して表示する行数"
            ))

            Button(role: .destructive, action: onDelete) {
                Label(tr("Delete Line", ja: "行を削除"), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private var lineCountLabel: String {
        line.maxLines == 1
            ? tr("1 line", ja: "1行")
            : tr("\(line.maxLines) lines", ja: "\(line.maxLines)行")
    }

    private func side(
        label: String,
        template: Binding<RowTemplate>,
        style: Binding<RowTextStyle>
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            TemplateField(
                label: label,
                labelWidth: Self.sideLabelWidth,
                template: template,
                catalog: catalog
            )
            Picker("", selection: style) {
                ForEach(RowTextStyle.allCases, id: \.self) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .labelsHidden()
            .frame(width: 104)
        }
    }
}

extension RowTextStyle {
    @MainActor var displayName: String {
        switch self {
        case .heading: tr("Heading", ja: "見出し")
        case .body: tr("Body", ja: "本文")
        case .subdued: tr("Subdued", ja: "控えめ")
        case .monospace: tr("Monospace", ja: "等幅")
        case .status: tr("Status", ja: "状態")
        }
    }
}

// MARK: - Notification body

private struct NotificationBodyList: View {
    @Binding var lines: [NotificationLine]
    let labelWidth: CGFloat
    let catalog: TemplateVariableCatalog

    @State private var reorder = RowReorder<UUID>()

    private var label: String { tr("Body", ja: "本文") }

    var body: some View {
        ForEach($lines) { $line in
            HStack(spacing: 6) {
                // Only the first line carries the label, to line up with the
                // Title and Subtitle labels above.
                Text(line.id == lines.first?.id ? label : "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)

                RowGrabber(
                    id: line.id,
                    order: lines.map(\.id),
                    reorder: reorder,
                    move: { lines.move(fromOffsets: $0, toOffset: $1) }
                )

                TemplateField(
                    label: label,
                    labelWidth: nil,
                    template: $line.template,
                    catalog: catalog
                )

                Button(role: .destructive) {
                    lines.removeAll { $0.id == line.id }
                } label: {
                    Label(tr("Delete Line", ja: "行を削除"), systemImage: "trash")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            .reorderableRow(reorder, id: line.id)
        }

        Button {
            lines.append(NotificationLine(RowTemplate("")))
        } label: {
            Label(tr("Add Line", ja: "行を追加"), systemImage: "plus")
        }
        .buttonStyle(.borderless)
        .padding(.leading, labelWidth + 6)
    }
}

// MARK: - Template field

private struct TemplateField: View {
    let label: String
    // nil draws no label, for a field whose caller places the label elsewhere
    // in the row.
    let labelWidth: CGFloat?
    @Binding var template: RowTemplate
    let catalog: TemplateVariableCatalog

    @FocusState private var isFocused: Bool
    // UTF-16 caret offset; nil until the field has been focused once, in which
    // case an insertion appends. A reference type because the caret moves on
    // every keystroke and click, and recording it must not re-render the field.
    private final class CaretBox {
        var location: Int?
    }
    @State private var caret = CaretBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let labelWidth {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                }

                TextField(
                    label,
                    text: Binding(
                        get: { template.source },
                        set: { template = RowTemplate($0) }
                    )
                )
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .focused($isFocused)

                Button(action: presentVariableMenu) {
                    Image(systemName: "curlybraces")
                }
                .buttonStyle(.borderless)
                .help(tr("Insert a variable", ja: "変数を挿入"))
            }

            if !unknownNames.isEmpty {
                Text(unknownNamesWarning)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, labelWidth.map { $0 + 6 } ?? 0)
            }
        }
        .onChange(of: template) { rememberCaret() }
        .onChange(of: isFocused) { if isFocused { rememberCaret() } }
        // A click or an arrow key moves the caret without changing the text;
        // the field editor posts this for every such move. Without it, an
        // insertion would land wherever the caret was last recorded.
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { _ in
            rememberCaret()
        }
    }

    private var unknownNames: [String] {
        catalog.unknownNames(in: template)
    }

    // Built at click time, not during body evaluation: a menu per field made
    // tab switches and keystrokes pay for menus nobody opened. An NSMenu also
    // leaves the window's first responder alone, so insertion afterwards
    // usually takes the caret-preserving field-editor path.
    private func presentVariableMenu() {
        let menu = NSMenu()
        for group in catalog.groups {
            let groupItem = NSMenuItem(title: group.title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: group.title)
            for entry in group.entries {
                submenu.addItem(InsertionMenuItem(title: entry.menuLabel) {
                    insert(entry.name)
                })
            }
            groupItem.submenu = submenu
            menu.addItem(groupItem)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    // The field editor path is tried first because it is the same edit a
    // keystroke would make, so undo and the selection survive. It is
    // unavailable once a menu popup has taken first responder, and the string
    // is spliced at the last known caret instead.
    private func insert(_ name: String) {
        let snippet = "{\(name)}"
        if isFocused, let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            let range = editor.selectedRange()
            if editor.shouldChangeText(in: range, replacementString: snippet) {
                editor.insertText(snippet, replacementRange: range)
                return
            }
        }

        var source = template.source
        let offset = min(caret.location ?? source.utf16.count, source.utf16.count)
        source.insert(
            contentsOf: snippet,
            at: String.Index(utf16Offset: offset, in: source)
        )
        template = RowTemplate(source)

        let restored = NSRange(location: offset + snippet.utf16.count, length: 0)
        caret.location = restored.location
        isFocused = true
        // One turn later, after SwiftUI has pushed the new text into the field
        // editor; setting the range before that loses it.
        DispatchQueue.main.async {
            (NSApp.keyWindow?.firstResponder as? NSTextView)?.setSelectedRange(restored)
        }
    }

    private var unknownNamesWarning: String {
        let heading = unknownNames.count == 1 ? "Unknown variable" : "Unknown variables"
        return tr(
            "\(heading): \(unknownNames.joined(separator: ", "))",
            ja: "不明な変数: \(unknownNames.joined(separator: "、"))"
        )
    }

    private func rememberCaret() {
        guard isFocused,
              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { return }
        caret.location = editor.selectedRange().location
    }
}

// The item is its own target, so the closure lives exactly as long as the menu
// holding it.
private final class InsertionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("InsertionMenuItem is never decoded")
    }

    @objc private func run() {
        handler()
    }
}

// MARK: - Per-agent override editor

private struct AgentOverrideEditorContext: Identifiable {
    let id = UUID()
    // herdr's agent id (claude, codex, ...). Empty while adding.
    let agent: String
    let lines: [RowLine]
    let isNew: Bool
}

private struct AgentOverrideEditor: View {
    let context: AgentOverrideEditorContext
    let catalog: TemplateVariableCatalog
    let existingAgents: Set<String>
    let save: (String, [RowLine]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var agent: String
    @State private var lines: [RowLine]

    init(
        context: AgentOverrideEditorContext,
        catalog: TemplateVariableCatalog,
        existingAgents: Set<String>,
        save: @escaping (String, [RowLine]) -> Void
    ) {
        self.context = context
        self.catalog = catalog
        self.existingAgents = existingAgents
        self.save = save
        _agent = State(initialValue: context.agent)
        _lines = State(initialValue: context.lines)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Text(tr("Agent", ja: "エージェント"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 74, alignment: .leading)
                        TextField("", text: $agent, prompt: Text(verbatim: "codex"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .disabled(!context.isNew)
                    }
                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    Text(tr(
                        "These lines replace the rows for this agent.",
                        ja: "このエージェントでは、これらの行が行の設定を置き換えます。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    Text(tr("Lines", ja: "行"))
                        .font(.headline)
                        .padding(.top, 4)
                    RowLineList(lines: $lines, catalog: catalog)
                }
                .padding(14)
                .padding(.trailing, legacyScrollerInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            Divider()

            HStack {
                Spacer()
                Button(tr("Cancel", ja: "キャンセル"), role: .cancel) {
                    dismiss()
                }
                Button(tr("Save", ja: "保存")) {
                    save(trimmedAgent, lines)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
            .padding(12)
        }
        .frame(width: 620, height: 460)
    }

    private var trimmedAgent: String {
        agent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: String? {
        if trimmedAgent.isEmpty {
            return tr("Enter an agent id", ja: "エージェント ID を入力してください")
        }
        if context.isNew, existingAgents.contains(trimmedAgent) {
            return tr(
                "\(trimmedAgent) already has an override",
                ja: "\(trimmedAgent) の上書きはすでにあります"
            )
        }
        return nil
    }
}

// MARK: - Variable catalog

@MainActor
struct TemplateVariableCatalog {
    struct Entry: Identifiable {
        let name: String
        // Absent when no agent is monitored, or when the name is not a herdr
        // record field.
        let value: String?

        var id: String { name }

        var menuLabel: String {
            guard let value, !value.isEmpty else { return name }
            return "\(name) — \(value)"
        }
    }

    struct Group: Identifiable {
        let title: String
        let entries: [Entry]

        var id: String { title }
    }

    let groups: [Group]

    private let agentRecords: [JSONValue]
    private let workspaceRecords: [JSONValue]
    private let tabRecords: [JSONValue]

    static let empty = TemplateVariableCatalog()

    init(store: FleetStore) {
        // Records arrive in dictionaries, so they are ordered by id to keep the
        // representative record and the token key list stable.
        func ordered(_ records: [String: JSONValue]) -> [JSONValue] {
            records.keys.sorted().compactMap { records[$0] }
        }
        let snapshots = store.activeSources.compactMap(\.availableSnapshot)
        self.init(
            agents: snapshots.flatMap { ordered($0.raw.agents) },
            workspaces: snapshots.flatMap { ordered($0.raw.workspaces) },
            tabs: snapshots.flatMap { ordered($0.raw.tabs) }
        )
    }

    // Menu values come from one representative pane — the focused one, else the
    // lowest pane id — so the menu shows a coherent record rather than a mix of
    // fields from different agents.
    init(agents: [JSONValue] = [], workspaces: [JSONValue] = [], tabs: [JSONValue] = []) {
        agentRecords = agents
        workspaceRecords = workspaces
        tabRecords = tabs

        func member(_ record: JSONValue?, _ key: String) -> JSONValue? {
            guard let record else { return nil }
            return record[key]
        }
        let agent = agents.first { $0["focused"] == JSONValue.bool(true) } ?? agents.first
        let workspace = member(agent, "workspace_id").flatMap { id in
            workspaces.first { $0["workspace_id"] == id }
        }
        let tab = member(agent, "tab_id").flatMap { id in
            tabs.first { $0["tab_id"] == id }
        }

        func entries(_ paths: [String], _ record: JSONValue?, prefix: String) -> [Entry] {
            paths.map { path in
                let text = record?.value(at: path.split(separator: "."))?.templateText ?? nil
                return Entry(name: prefix + path, value: text.map(Self.abbreviated))
            }
        }

        var built: [Group] = [
            Group(
                title: tr("Shepherd", ja: "Shepherd"),
                entries: Self.shepherdNames.map { Entry(name: $0, value: nil) }
            ),
            Group(
                title: tr("herdr · agent", ja: "herdr · エージェント"),
                entries: entries(Self.agentPaths, agent, prefix: "herdr.agent.")
            ),
            Group(
                title: tr("herdr · workspace", ja: "herdr · ワークスペース"),
                entries: entries(Self.workspacePaths, workspace, prefix: "herdr.workspace.")
            ),
            Group(
                title: tr("herdr · tab", ja: "herdr · タブ"),
                entries: entries(Self.tabPaths, tab, prefix: "herdr.tab.")
            ),
        ]

        let tokens = Self.tokenEntries(agents: agents, workspaces: workspaces)
        if !tokens.isEmpty {
            built.append(Group(title: tr("Tokens", ja: "トークン"), entries: tokens))
        }
        groups = built
    }

    // Names come back in braces so the warning shows them as they were typed.
    func unknownNames(in template: RowTemplate) -> [String] {
        var seen: Set<String> = []
        var unknown: [String] = []
        for name in template.variableNames where seen.insert(name).inserted {
            guard !isDefined(name) else { continue }
            unknown.append("{\(name)}")
        }
        return unknown
    }

    // Shepherd names are a closed set, but herdr keeps adding record fields, so
    // a herdr path also counts as defined when a live record resolves it.
    // Agent and workspace token keys come from hooks and are legitimately
    // absent, so they are accepted without a record; tabs carry no tokens.
    private func isDefined(_ name: String) -> Bool {
        if Self.shepherdNames.contains(name) { return true }
        guard let (scope, path) = Self.split(name) else { return false }
        if path.hasPrefix("tokens."), scope != .tab { return true }
        if Self.documentedPaths(scope).contains(path) { return true }
        let components = path.split(separator: ".")
        return records(scope).contains { $0.value(at: components) != nil }
    }

    private func records(_ scope: Scope) -> [JSONValue] {
        switch scope {
        case .agent: agentRecords
        case .workspace: workspaceRecords
        case .tab: tabRecords
        }
    }

    private enum Scope: String {
        case agent
        case workspace
        case tab
    }

    private static func split(_ name: String) -> (Scope, String)? {
        let parts = name.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0] == "herdr",
              let scope = Scope(rawValue: String(parts[1])),
              !parts[2].isEmpty else { return nil }
        return (scope, String(parts[2]))
    }

    private static func documentedPaths(_ scope: Scope) -> [String] {
        switch scope {
        case .agent: agentPaths
        case .workspace: workspacePaths
        case .tab: tabPaths
        }
    }

    private static let shepherdNames = [
        "title",
        "cwd_short",
        "cwd_name",
        "excerpt",
        "source",
        "agent_icon",
        "status_emoji",
    ]

    private static let agentPaths = [
        "agent",
        "display_agent",
        "agent_status",
        "terminal_title_stripped",
        "title",
        "cwd",
        "foreground_cwd",
        "focused",
        "revision",
        "pane_id",
        "workspace_id",
        "tab_id",
        "terminal_id",
        "state_labels.working",
        "agent_session.value",
    ]

    private static let workspacePaths = [
        "workspace_id",
        "label",
        "branch",
        "pane_count",
        "worktree.repo_name",
        "worktree.repo_root",
        "worktree.checkout_path",
    ]

    private static let tabPaths = [
        "tab_id",
        "label",
        "number",
    ]

    // Token keys are defined by hooks, so they exist only while something
    // reports them and cannot be listed ahead of time.
    private static func tokenEntries(
        agents: [JSONValue],
        workspaces: [JSONValue]
    ) -> [Entry] {
        func keyed(_ records: [JSONValue], prefix: String) -> [Entry] {
            var values: [String: String] = [:]
            for record in records {
                guard case .object(let members)? = record["tokens"] else { continue }
                for (key, value) in members {
                    guard let text = value.templateText else { continue }
                    values[key] = text
                }
            }
            return values.keys.sorted().map { key in
                Entry(name: prefix + key, value: values[key].map(abbreviated))
            }
        }
        return keyed(agents, prefix: "herdr.agent.tokens.")
            + keyed(workspaces, prefix: "herdr.workspace.tokens.")
    }

    // A long value (a title, a path) would stretch the popup across the screen.
    private static func abbreviated(_ text: String) -> String {
        let limit = 42
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

// MARK: - Preview column

private struct RowLayoutPreviewColumn: View {
    let store: FleetStore

    private enum Mode: String, CaseIterable, Identifiable {
        case sample
        case live

        var id: String { rawValue }

        @MainActor var displayName: String {
            switch self {
            case .sample: tr("Sample", ja: "サンプル")
            case .live: tr("Live", ja: "実際の状態")
            }
        }
    }

    @State private var mode: Mode = .sample

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { candidate in
                    Text(candidate.displayName).tag(candidate)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)

            Divider()

            ScrollView {
                Group {
                    switch mode {
                    case .sample: sampleRows
                    case .live: liveRows
                    }
                }
                .padding(.trailing, legacyScrollerInset)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var sampleRows: some View {
        card {
            ForEach(RowLayoutPreviewSample.entries) { entry in
                row(context: entry.context, excerptState: entry.excerptState)
            }
        }
    }

    @ViewBuilder
    private var liveRows: some View {
        if liveSections.isEmpty {
            ContentUnavailableView {
                Label(tr("No Agents", ja: "エージェントなし"), systemImage: "terminal")
            } description: {
                Text(tr(
                    "Start an agent in herdr, or use the sample",
                    ja: "herdr でエージェントを起動するか、サンプルを使ってください"
                ))
            }
            .padding(.top, 40)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(liveSections) { section in
                    card {
                        ForEach(section.paneIDs, id: \.self) { paneID in
                            if let context = store.rowContext(for: paneID) {
                                row(
                                    context: context,
                                    excerptState: store.agentExcerptState(for: paneID)
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    // `onFocus: nil` is what a remote row gets, so the preview never highlights
    // on hover. The excerpt line is reserved as the menu reserves it, since the
    // menu is the surface these templates are tuned against.
    private func row(context: AgentRowContext, excerptState: AgentExcerptState?) -> some View {
        AgentRow(
            context: context,
            hoverStyle: .menu,
            excerptState: excerptState,
            reservesExcerptLine: true,
            onFocus: nil
        )
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(10)
    }

    private struct LiveSection: Identifiable {
        let id: HerdrSourceID
        let paneIDs: [SourcePaneID]
    }

    // Only ids are carried; the row context is read per row so the preview
    // follows the endpoint's current snapshot.
    private var liveSections: [LiveSection] {
        store.sourceSections.compactMap { section -> LiveSection? in
            guard let source = section.source, source.availableSnapshot != nil else { return nil }
            // workspaceGroups carries herdr's display order, so the preview
            // lists panes exactly as the menu does.
            let panes = source.workspaceGroups.flatMap { $0.panes }
            guard !panes.isEmpty else { return nil }
            return LiveSection(
                id: section.id,
                paneIDs: panes.map { SourcePaneID(sourceID: section.id, paneID: $0.paneId) }
            )
        }
    }
}
