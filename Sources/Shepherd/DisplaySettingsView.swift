// The Display settings tab: an editor for RowLayout — the agent row's lines,
// the per-agent replacements of that list, and the three notification
// templates — beside a preview of the rows those templates produce.
//
// This pane is the only writer of RowLayoutSetting.shared.layout and the only
// place that reports variable names no resolver knows. It owns no herdr state:
// live records are read through FleetStore for the insertion menu's current
// values and for the Live preview, and the fixed sample comes from
// RowLayoutPreviewSample.
//
// The editor is one scrolling column beside the preview. The split is fixed:
// the preview keeps a constant width and the editor takes the rest, so
// widening the window widens the template fields. Template fields sit directly
// in the scroll view, not in a List: an NSTableView-backed list takes clicks
// for row handling before its field editor, which reads as text fields that
// ignore the click. Without a List there is no onMove either, so lines reorder
// with the arrow buttons on each line.
//
// Insertion into a template field targets the caret. While the field owns the
// window's field editor the edit goes through NSTextView, which keeps undo and
// the typing selection; once a menu popup has taken first responder away, the
// last caret the field saw is used to splice the source string instead.

import AppKit
import SwiftUI

/// Extra trailing inset for this pane's scrolling columns. An always-visible
/// (legacy) scroller draws over the content's trailing edge rather than beside
/// it, and without this inset it sits on the controls at that edge. Overlay
/// scrollers appear over the same gap only while scrolling and need none.
@MainActor
private var legacyScrollerInset: CGFloat {
    guard NSScroller.preferredScrollerStyle == .legacy else { return 0 }
    return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
}


struct DisplaySettingsView: View {
    let store: FleetStore

    /// Width of the preview column. Sized for a menu-width row (MenuPanel lays
    /// rows at 340pt) plus the card and column insets around it.
    private static let previewColumnWidth: CGFloat = 320

    @Bindable private var layoutSetting = RowLayoutSetting.shared
    @AppStorage(colorAgentIconsKey) private var colorAgentIcons = false
    /// Sampled when the tab appears rather than read during body evaluation: the
    /// catalog is built from snapshots that change on every poll, and observing
    /// them here would rebuild the whole editor — text fields included — twice a
    /// second while someone is typing in it.
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
            // Ordering the window front, and selecting this tab, both leave
            // AppKit's first-responder choice on the first template field,
            // opening the pane with a template selected. defaultFocus is
            // ignored in a Settings scene, so the choice is undone one runloop
            // turn later, after the turn that made it.
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
                        "Notifications are text only: {excerpt} and {agent_icon} stay empty, and the excerpt is appended to the body.",
                        ja: "通知はテキストのみです。{excerpt} と {agent_icon} は空になり、抜粋は本文の末尾に付きます。"
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
                    TemplateField(
                        label: tr("Body", ja: "本文"),
                        labelWidth: Self.notificationLabelWidth,
                        template: $layoutSetting.layout.notification.body,
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

    /// One titled section of the editor column: a header row holding the title
    /// and its Restore Defaults link, the carded content, and a caption footer.
    /// The card is the same quinary rounded surface the preview column uses.
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

/// Which part of the layout a pending "Restore Defaults" confirmation covers.
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

/// The editable line list: one editor per line reordered with its arrow
/// buttons, plus the button that appends a line.
private struct RowLineList: View {
    @Binding var lines: [RowLine]
    let catalog: TemplateVariableCatalog

    var body: some View {
        ForEach($lines) { $line in
            RowLineEditor(
                line: $line,
                catalog: catalog,
                onMoveUp: move(line.id, by: -1),
                onMoveDown: move(line.id, by: +1),
                onDelete: { lines.removeAll { $0.id == line.id } }
            )
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

    /// Action swapping a line with its neighbor; nil at the end of travel, which
    /// disables the button.
    private func move(_ id: UUID, by delta: Int) -> (() -> Void)? {
        guard let index = lines.firstIndex(where: { $0.id == id }),
              lines.indices.contains(index + delta) else { return nil }
        return { lines.swapAt(index, index + delta) }
    }
}

/// One line: its left and right template with a style each, the arrow buttons
/// ordering it, and the button that removes it. A line whose two sides both
/// render empty is dropped by the row itself, so there is nothing to warn
/// about here.
private struct RowLineEditor: View {
    @Binding var line: RowLine
    let catalog: TemplateVariableCatalog
    let onMoveUp: (() -> Void)?
    let onMoveDown: (() -> Void)?
    let onDelete: () -> Void

    private static let sideLabelWidth: CGFloat = 34

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
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

            orderButton(tr("Move Up", ja: "上へ"), systemImage: "chevron.up", action: onMoveUp)
            orderButton(tr("Move Down", ja: "下へ"), systemImage: "chevron.down", action: onMoveDown)

            Button(role: .destructive, action: onDelete) {
                Label(tr("Delete Line", ja: "行を削除"), systemImage: "trash")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
    }

    private func orderButton(
        _ label: String,
        systemImage: String,
        action: (() -> Void)?
    ) -> some View {
        Button { action?() } label: {
            Label(label, systemImage: systemImage)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(action == nil)
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

// MARK: - Template field

/// One template text field with its variable-insertion menu and the inline list
/// of names no resolver knows.
private struct TemplateField: View {
    let label: String
    let labelWidth: CGFloat
    @Binding var template: RowTemplate
    let catalog: TemplateVariableCatalog

    @FocusState private var isFocused: Bool
    /// UTF-16 offset of the caret as of the last text, focus, or selection
    /// change; nil until the field has been focused once, in which case an
    /// insertion appends. A reference type: the caret moves on every keystroke
    /// and click, and recording it must not re-render the field.
    private final class CaretBox {
        var location: Int?
    }
    @State private var caret = CaretBox()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: labelWidth, alignment: .leading)

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
                    .padding(.leading, labelWidth + 6)
            }
        }
        .onChange(of: template) { rememberCaret() }
        .onChange(of: isFocused) { if isFocused { rememberCaret() } }
        // A click or an arrow key moves the caret without changing the text, and
        // the field editor posts this for every such move. Without it, insertion
        // would fall back to wherever the caret last happened to be recorded.
        .onReceive(NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)) { _ in
            rememberCaret()
        }
    }

    private var unknownNames: [String] {
        catalog.unknownNames(in: template)
    }

    /// Builds the insertion menu at click time, not during body evaluation:
    /// every field carrying a built menu of every variable made tab switches
    /// and each keystroke pay for menus nobody had opened. An NSMenu also
    /// leaves the window's first responder alone, so insertion after picking
    /// an entry usually takes the caret-preserving field-editor path.
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

    /// Inserts `{name}` at the caret.
    ///
    /// The field editor path is tried first: it is the same edit a keystroke
    /// would make, so undo and the selection survive. It is unavailable once the
    /// menu popup has taken first responder, and then the source string is
    /// spliced at the last caret this field saw and the selection is put back on
    /// the next runloop turn, after SwiftUI has pushed the new text into the
    /// field editor.
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

/// Menu item carrying its action as a closure. The item is its own target, so
/// the closure lives exactly as long as the menu holding it.
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
    /// herdr's agent id (claude, codex, ...). Empty while adding.
    let agent: String
    let lines: [RowLine]
    /// Adding rather than editing: the agent id is editable and checked against
    /// the ids already overridden.
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

/// The variable names the insertion menu offers and the unknown-name check
/// treats as defined, each with the value it currently resolves to where one is
/// available.
///
/// The two namespaces are checked differently. The Shepherd names are a closed
/// set. A `herdr.<scope>.<path>` name addresses a field of a record, and herdr
/// keeps adding fields, so a path counts as defined when it is one of the
/// documented fields, sits under `tokens.` (those keys come from hooks and are
/// legitimately absent), or resolves in a record a live agent reports right now.
@MainActor
struct TemplateVariableCatalog {
    struct Entry: Identifiable {
        let name: String
        /// Value from the representative live record, absent when no agent is
        /// being monitored or the field is not a herdr record field.
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

    /// The documented names with no values, for use before any snapshot has
    /// been sampled.
    static let empty = TemplateVariableCatalog()

    /// Builds the catalog from every source currently ready.
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

    /// Builds the catalog over the given records. Menu values come from one
    /// representative pane — the focused one if herdr reports one, else the
    /// lowest pane id — so the menu shows a coherent record rather than a mix of
    /// fields from different agents. With no records the names are still listed,
    /// without values.
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

    /// Names referenced by `template` that no resolver defines, deduplicated and
    /// in source order, each wrapped in braces so the message reads like the
    /// text the user typed.
    func unknownNames(in template: RowTemplate) -> [String] {
        var seen: Set<String> = []
        var unknown: [String] = []
        for name in template.variableNames where seen.insert(name).inserted {
            guard !isDefined(name) else { continue }
            unknown.append("{\(name)}")
        }
        return unknown
    }

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

    /// Splits `herdr.<scope>.<path>` into its scope and the remaining dotted
    /// path. Anything else — another prefix, an unknown scope, no path — is not
    /// a herdr name and is reported as unknown.
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

    /// Token keys live agents and their workspaces report right now. They are
    /// defined by hooks, so they exist only as long as something reports them
    /// and cannot be listed ahead of time.
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

    /// Keeps a menu entry to one readable line; long values (a title, a path)
    /// would otherwise stretch the popup across the screen.
    private static func abbreviated(_ text: String) -> String {
        let limit = 42
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}

// MARK: - Preview column

/// The rows the current templates produce, on the fixed sample or on the agents
/// being monitored. Rows are built with `onFocus: nil`, which is the same static,
/// non-hovering row a remote gets in the menu.
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

    /// The AgentRow the menu draws, minus interaction: `onFocus: nil` is what a
    /// remote row gets, so the preview never highlights on hover. The excerpt
    /// line is reserved as the menu reserves it, which is the surface these
    /// templates are tuned against.
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

    /// One entry per ready source that has agents, in the order the menu lists
    /// them. Only the ids are carried; the row context is read per row so the
    /// preview follows the endpoint's current snapshot.
    private var liveSections: [LiveSection] {
        store.sourceSections.compactMap { section -> LiveSection? in
            guard let source = section.source, source.availableSnapshot != nil else { return nil }
            // workspaceGroups is herdr's display order, so the preview lists
            // panes exactly as the menu does.
            let panes = source.workspaceGroups.flatMap { $0.panes }
            guard !panes.isEmpty else { return nil }
            return LiveSection(
                id: section.id,
                paneIDs: panes.map { SourcePaneID(sourceID: section.id, paneID: $0.paneId) }
            )
        }
    }
}
