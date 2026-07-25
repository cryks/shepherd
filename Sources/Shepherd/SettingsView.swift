// UI for the Settings scene. General settings, row and notification templates,
// remote monitoring targets, and global hotkeys are separated into tabs. General
// owns only bindings to app-wide preferences;
// notification authorization and cleanup stay in NotificationSettingsCoordinator
// because toggling that preference has operating-system side effects. Remote
// editing passes only values that passed RemoteSourceConfiguration validation to
// FleetStore, and no SSH passwords or private keys are stored. Authentication,
// ProxyJump, and key selection are resolved by `/usr/bin/ssh` from
// `~/.ssh/config` and ssh-agent.
//
// SettingsWindowSizer owns the window's size, not SwiftUI: a TabView asks for
// the width its widest tab needs (the Display pane's split, around 900pt) no
// matter which tab is selected, so the compact tabs would open far too wide.
// The window adds 88pt of vertical chrome and none horizontally.

import SwiftUI

/// UserDefaults key for whether agent brand marks are shown in color.
/// The Display settings tab writes it and AgentRow reads it. Both reference it
/// via @AppStorage, so toggling is reflected immediately in the rows currently
/// on screen.
let colorAgentIconsKey = "ColorAgentIcons"

struct SettingsView: View {
    @Bindable var store: FleetStore
    @Bindable var notificationSettings: NotificationSettingsCoordinator
    @Bindable var updater: UpdaterModel

    @State private var selectedTab: SettingsTab = .general

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettingsView(
                store: store,
                notificationSettings: notificationSettings,
                updater: updater
            )
                .tabItem {
                    Label(tr("General", ja: "一般"), systemImage: "gearshape")
                }
                .tag(SettingsTab.general)

            DisplaySettingsView(store: store)
                .tabItem {
                    Label(tr("Display", ja: "表示"), systemImage: "text.alignleft")
                }
                .tag(SettingsTab.display)

            RemoteSourcesSettingsView(store: store)
                .tabItem {
                    Label(tr("Remotes", ja: "リモート"), systemImage: "network")
                }
                .tag(SettingsTab.remotes)

            HotkeySettingsView()
                .tabItem {
                    Label(tr("Hotkeys", ja: "ホットキー"), systemImage: "keyboard")
                }
                .tag(SettingsTab.hotkeys)
        }
        // A constant, flexible frame: SettingsWindowSizer owns the window's
        // size, and SwiftUI would fight it if the content's own sizing changed
        // per tab. The floor is the compact tabs' layout size; the Display tab
        // clips below its split's minimum, which the sizer's per-tab floor
        // prevents from persisting.
        .frame(
            minWidth: SettingsTab.compactSize.width,
            idealWidth: SettingsTab.compactSize.width,
            maxWidth: .infinity,
            minHeight: SettingsTab.compactSize.height,
            idealHeight: SettingsTab.compactSize.height,
            maxHeight: .infinity
        )
        .background(SettingsWindowSizer(tab: selectedTab))
        .task {
            updater.refresh()
            await notificationSettings.refresh()
        }
    }
}

/// The settings tabs, each with the content size it opens at. The window
/// animates between these sizes as tabs are selected; a size the reader drags
/// the window to is remembered per tab for the session.
enum SettingsTab: Hashable {
    case general
    case display
    case remotes
    case hotkeys

    /// Layout size the three form tabs are written against.
    static let compactSize = CGSize(width: 520, height: 500)

    var defaultSize: CGSize {
        switch self {
        case .display: CGSize(width: 820, height: 560)
        case .general, .remotes, .hotkeys: Self.compactSize
        }
    }

    /// Floor while this tab is selected. Display's is the width below which its
    /// editor-plus-preview split starts clipping its columns.
    var minimumSize: CGSize {
        switch self {
        case .display: CGSize(width: 760, height: 520)
        case .general, .remotes, .hotkeys: Self.compactSize
        }
    }
}

/// Drives the settings window's frame from the selected tab: on a tab change
/// the window animates to that tab's remembered or default size, keeping its
/// top-left corner still, and takes the tab's floor as its minimum content
/// size. SwiftUI is kept out of window sizing entirely (the content's own
/// sizing never changes), because its instant resize on tab selection is what
/// this animation replaces.
private struct SettingsWindowSizer: NSViewRepresentable {
    let tab: SettingsTab

    final class Coordinator {
        var appliedTab: SettingsTab?
        /// Content size each tab was last seen at, so a reader's resize
        /// survives leaving and revisiting the tab within one app run.
        var rememberedSizes: [SettingsTab: CGSize] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Reports the window it is added to. AppKit sets a view's window before
    /// the window is ordered front, so this is where the first size lands:
    /// applied any later, the window is already on screen at the size SwiftUI
    /// gave it, and the correction reads as a flash.
    final class SizerView: NSView {
        var onAttachToWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onAttachToWindow?(window)
        }
    }

    func makeNSView(context: Context) -> SizerView { SizerView() }

    func updateNSView(_ view: SizerView, context: Context) {
        let tab = tab
        let coordinator = context.coordinator
        // This pass runs before SwiftUI attaches the view, so the handler is
        // what sizes the window on the first open; from then on the window is
        // reachable here and a tab change goes through the animating path.
        view.onAttachToWindow = { window in apply(tab, to: window, coordinator) }
        guard let window = view.window else { return }
        // updateNSView must not mutate state during an update pass.
        DispatchQueue.main.async { apply(tab, to: window, coordinator) }
    }

    private func apply(_ tab: SettingsTab, to window: NSWindow, _ coordinator: Coordinator) {
        guard coordinator.appliedTab != tab else { return }
        // Sizes are measured and applied as deltas against contentLayoutRect,
        // the area below the tab toolbar. The frameRect/contentRect conversions
        // are styleMask-based and leave the toolbar out, so a frame computed
        // through them comes up a toolbar short and clips the pane's bottom.
        let current = window.contentLayoutRect.size
        if let previous = coordinator.appliedTab {
            coordinator.rememberedSizes[previous] = current
        }
        let animatesFromPreviousTab = coordinator.appliedTab != nil
        coordinator.appliedTab = tab
        window.contentMinSize = tab.minimumSize

        var target = coordinator.rememberedSizes[tab] ?? tab.defaultSize
        target.width = max(target.width, tab.minimumSize.width)
        target.height = max(target.height, tab.minimumSize.height)
        guard target != current else { return }

        var frame = window.frame
        frame.size.width += target.width - current.width
        frame.size.height += target.height - current.height

        guard animatesFromPreviousTab else {
            // The first size is set while the window is off screen and before
            // AppKit has placed it, so only the size is ours to set here.
            window.setFrame(frame, display: false)
            return
        }
        // The top edge stays put; frame origin is the bottom-left corner.
        frame.origin.y -= target.height - current.height
        NSAnimationContext.runAnimationGroup { animation in
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: FleetStore
    @Bindable var notificationSettings: NotificationSettingsCoordinator
    @Bindable var updater: UpdaterModel
    @Bindable private var language = LanguageSetting.shared
    @Bindable private var localTitle = LocalSectionTitleSetting.shared
    @Bindable private var excerpts = ExcerptSetting.shared
    @AppStorage(MenuBarIconPresentation.blinkEnabledKey) private var blinkMenuBarIcon = true
    @FocusState private var isLocalTitleFieldFocused: Bool

    var body: some View {
        Form {
            Section(tr("General", ja: "一般")) {
                Toggle(tr("Launch at login", ja: "ログイン時に起動"), isOn: $store.launchAtLogin)
                Picker(tr("Language", ja: "言語"), selection: $language.selection) {
                    ForEach(AppLanguage.allCases) { candidate in
                        Text(verbatim: candidate.displayName).tag(candidate)
                    }
                }
                Toggle(
                    tr("Automatically check for updates", ja: "アップデートを自動で確認"),
                    isOn: $updater.automaticallyChecksForUpdates
                )
            }

            Section(tr("Source list", ja: "ソース一覧")) {
                Picker(
                    tr("This Mac label with remotes", ja: "リモート存在時のローカル表記"),
                    selection: $localTitle.style
                ) {
                    ForEach(LocalSectionTitleStyle.allCases) { style in
                        Text(style.displayName).tag(style)
                    }
                }
                if localTitle.style == .custom {
                    TextField(
                        tr("Section title", ja: "セクション見出し"),
                        text: $localTitle.customTitle,
                        prompt: Text(LocalSectionTitleSetting.defaultTitle)
                    )
                    .focused($isLocalTitleFieldFocused)
                } else if localTitle.style == .hidden {
                    Text(tr(
                        "With remotes, agents on this Mac are listed without a section title.",
                        ja: "リモート存在時、この Mac のエージェントは見出しなしで並びます。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section(tr("Notifications", ja: "通知")) {
                Toggle(
                    tr(
                        "Blink the menu bar icon when attention is needed",
                        ja: "対応が必要なときにメニューバーアイコンを点滅"
                    ),
                    isOn: $blinkMenuBarIcon
                )
                Toggle(
                    tr(
                        "Send notifications when agents need attention",
                        ja: "エージェントに対応が必要なときに通知"
                    ),
                    isOn: Binding(
                        get: { notificationSettings.isEnabled },
                        set: { enabled in
                            Task { await notificationSettings.setEnabled(enabled) }
                        }
                    )
                )
                if showsNotificationSystemWarning {
                    notificationSystemWarning
                }
            }

            Section(tr("Excerpts (Experimental)", ja: "抜粋（試験機能）")) {
                Toggle(tr("Show excerpts", ja: "抜粋を表示"), isOn: $excerpts.isEnabled)
                Text(tr(
                    "Reads each Codex and Claude Code terminal in the background and shows the agent's latest message in the list and in notifications.",
                    ja: "Codex と Claude Code のターミナルをバックグラウンドで読み取り、エージェントの最新のメッセージを一覧と通知に表示します。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                Picker(
                    tr("Excerpt refresh interval", ja: "抜粋の取得間隔"),
                    selection: $excerpts.readInterval
                ) {
                    ForEach(ExcerptReadInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }
                .disabled(!excerpts.isEnabled)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // When the window is ordered front, AppKit makes the first editable
            // text field (the custom section-title field) the initial first
            // responder, which opens the pane with that field focused and its
            // text selected. SwiftUI's defaultFocus modifier cannot prevent
            // this: in a Settings scene it is ignored outright (verified on
            // macOS 26 with a probe app; even redirecting to another field has
            // no effect), and FocusState offers no "focus nothing" value at
            // window bringup. The responder assignment happens in the same
            // runloop turn as ordering the window front, so clearing one turn
            // later undoes it without racing it.
            DispatchQueue.main.async { isLocalTitleFieldFocused = false }
        }
    }

    /// Shepherd keeps the app preference ON after denial. This row exposes the
    /// separate macOS delivery gate without pretending the Toggle was reverted.
    private var showsNotificationSystemWarning: Bool {
        guard notificationSettings.isEnabled else { return false }
        if notificationSettings.authorizationError != nil { return true }
        let settings = notificationSettings.systemSettings
        switch settings.authorizationStatus {
        case .denied, .unknown:
            return true
        case .authorized, .provisional:
            return settings.alertSetting != .enabled
                || settings.notificationCenterSetting != .enabled
                || settings.alertStyle == .none
                || settings.alertStyle == .unknown
        case .notDetermined:
            return true
        }
    }

    private var notificationSystemWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(tr(
                    "macOS notification delivery is limited or disabled for Shepherd.",
                    ja: "Shepherd の macOS 通知が制限または無効になっています。"
                ))
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            .font(.caption)

            Button(tr(
                "Open Notification Settings…",
                ja: "通知設定を開く…"
            )) {
                notificationSettings.openSystemNotificationSettings()
            }
            .controlSize(.small)
        }
    }
}

private struct HotkeySettingsView: View {
    @Bindable private var hotkeys = HotkeySetting.shared

    var body: some View {
        Form {
            Section {
                LabeledContent(tr("Open or close the menu", ja: "メニューを開閉")) {
                    HotkeyRecorderField(combo: $hotkeys.menuPanelCombo)
                }
                LabeledContent(
                    tr("Open or close the pop-out window", ja: "ポップアウトウィンドウを開閉")
                ) {
                    HotkeyRecorderField(combo: $hotkeys.monitorWindowCombo)
                }
                Text(tr(
                    "These shortcuts work in any app while Shepherd is running. Include ⌘, ⌃, or ⌥; function keys can stand alone.",
                    ja: "Shepherd の起動中はどのアプリからでも使えるショートカットです。⌘・⌃・⌥ のいずれかを含めてください（ファンクションキーは単独でも使えます）。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RemoteSourcesSettingsView: View {
    let store: FleetStore

    @State private var selection: HerdrSourceID?
    @State private var editor: RemoteEditorContext?
    @State private var removalCandidate: RemoteSourceConfiguration?
    @State private var operationError: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.remoteConfigurations) { configuration in
                    remoteRow(configuration)
                        .tag(configuration.id)
                }
                .onMove { source, destination in
                    do {
                        try store.moveRemote(fromOffsets: source, toOffset: destination)
                        operationError = nil
                    } catch {
                        operationError = error.localizedDescription
                    }
                }
            }
            .overlay {
                if store.remoteConfigurations.isEmpty {
                    ContentUnavailableView {
                        Label(tr("No Remote Connections", ja: "リモート接続なし"), systemImage: "network")
                    } description: {
                        Text(tr(
                            "Add an SSH destination to monitor it alongside this Mac",
                            ja: "SSH 接続先を追加すると、この Mac と同時に監視します"
                        ))
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    editor = RemoteEditorContext(
                        mode: .add,
                        configuration: RemoteSourceConfiguration(label: "", sshAlias: "")
                    )
                } label: {
                    Label(tr("Add", ja: "追加"), systemImage: "plus")
                }

                Button {
                    guard let selectedConfiguration else { return }
                    editor = RemoteEditorContext(
                        mode: .edit,
                        configuration: selectedConfiguration
                    )
                } label: {
                    Label(tr("Edit", ja: "編集"), systemImage: "pencil")
                }
                .disabled(selectedConfiguration == nil)

                Button(role: .destructive) {
                    removalCandidate = selectedConfiguration
                } label: {
                    Label(tr("Delete", ja: "削除"), systemImage: "minus")
                }
                .disabled(selectedConfiguration == nil)

                Spacer()

                if let operationError {
                    Text(operationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
            .padding(10)
        }
        .sheet(item: $editor) { context in
            RemoteSourceEditor(context: context) { configuration in
                switch context.mode {
                case .add:
                    try store.addRemote(configuration)
                case .edit:
                    try store.updateRemote(configuration)
                }
            }
        }
        .alert(
            tr("Delete this remote connection?", ja: "リモート接続を削除しますか？"),
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            presenting: removalCandidate
        ) { configuration in
            Button(tr("Delete", ja: "削除"), role: .destructive) {
                do {
                    try store.removeRemote(id: configuration.id)
                    selection = nil
                    operationError = nil
                } catch {
                    operationError = error.localizedDescription
                }
                removalCandidate = nil
            }
            Button(tr("Cancel", ja: "キャンセル"), role: .cancel) {
                removalCandidate = nil
            }
        } message: { configuration in
            Text(tr(
                "This deletes the settings and SSH tunnel for \(configuration.displayName). The herdr on the remote host keeps running.",
                ja: "\(configuration.displayName) の設定と SSH tunnel を削除します。リモート側の herdr は停止しません。"
            ))
        }
    }

    private var selectedConfiguration: RemoteSourceConfiguration? {
        guard let selection else { return nil }
        return store.remoteConfigurations.first { $0.id == selection }
    }

    private func remoteRow(_ configuration: RemoteSourceConfiguration) -> some View {
        HStack(spacing: 10) {
            Toggle(
                "",
                isOn: Binding(
                    get: { configuration.isVisible },
                    set: { setRemoteVisible(configuration.id, $0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel(tr(
                "Show \(configuration.displayName)",
                ja: "\(configuration.displayName) を表示"
            ))

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.displayName)
                    .fontWeight(.semibold)
                Text(connectionDescription(configuration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(statusText(configuration))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(statusHelp(configuration))
        }
        .padding(.vertical, 3)
    }

    private func setRemoteVisible(_ id: HerdrSourceID, _ isVisible: Bool) {
        do {
            try store.setRemoteVisible(id: id, isVisible: isVisible)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func connectionDescription(_ configuration: RemoteSourceConfiguration) -> String {
        let endpoint: String
        if let sessionName = configuration.normalizedSessionName {
            endpoint = "\(configuration.sshAlias) · session \(sessionName)"
        } else {
            endpoint = "\(configuration.sshAlias) · default session"
        }
        return tr(
            "\(endpoint) · every \(configuration.pollInterval.displayName)",
            ja: "\(endpoint) · \(configuration.pollInterval.displayName)ごと"
        )
    }

    private func statusText(_ configuration: RemoteSourceConfiguration) -> String {
        guard configuration.isVisible else { return tr("Hidden", ja: "非表示") }
        guard configuration.isEnabled else { return tr("Off", ja: "オフ") }
        return store.monitoredSource(id: configuration.id)?.statusMessage
            ?? tr("Starting…", ja: "起動準備中…")
    }

    private func statusHelp(_ configuration: RemoteSourceConfiguration) -> String {
        guard configuration.isVisible,
              configuration.isEnabled,
              let source = store.monitoredSource(id: configuration.id) else {
            return statusText(configuration)
        }
        if let diagnostic = source.connectionDiagnostic {
            return "\(source.statusMessage)\n\(diagnostic)"
        }
        return source.statusMessage
    }
}

private struct RemoteEditorContext: Identifiable {
    enum Mode {
        case add
        case edit
    }

    let id = UUID()
    let mode: Mode
    let configuration: RemoteSourceConfiguration
}

private struct RemoteSourceEditor: View {
    let context: RemoteEditorContext
    let save: (RemoteSourceConfiguration) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var sshAlias: String
    @State private var sessionName: String
    @State private var pollInterval: RemotePollingInterval
    @State private var saveError: String?

    init(
        context: RemoteEditorContext,
        save: @escaping (RemoteSourceConfiguration) throws -> Void
    ) {
        self.context = context
        self.save = save
        _label = State(initialValue: context.configuration.label)
        _sshAlias = State(initialValue: context.configuration.sshAlias)
        _sessionName = State(initialValue: context.configuration.sessionName ?? "")
        _pollInterval = State(initialValue: context.configuration.pollInterval)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField(tr("Display name (optional)", ja: "表示名（省略可）"), text: $label)
                TextField(tr("SSH destination", ja: "SSH 接続先"), text: $sshAlias)
                TextField(tr("Herdr session (optional)", ja: "Herdr session（省略可）"), text: $sessionName)
                Picker(tr("Polling interval", ja: "更新間隔"), selection: $pollInterval) {
                    ForEach(RemotePollingInterval.allCases) { interval in
                        Text(interval.displayName).tag(interval)
                    }
                }

                Text(tr(
                    "The SSH destination accepts a Host from ~/.ssh/config or user@host. Credentials are managed by SSH and ssh-agent.",
                    ja: "SSH 接続先には ~/.ssh/config の Host 名か user@host を使えます。認証情報は SSH と ssh-agent が管理します。"
                ))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let validationMessage {
                    Text(validationMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button(tr("Cancel", ja: "キャンセル"), role: .cancel) {
                    dismiss()
                }
                Button(tr("Save", ja: "保存")) {
                    do {
                        try save(candidate.validated())
                        dismiss()
                    } catch {
                        saveError = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(candidate.validationError != nil)
            }
            .padding(12)
        }
        .frame(width: 440, height: 330)
    }

    private var candidate: RemoteSourceConfiguration {
        // Visibility is owned by the toggle in the settings list and monitoring
        // state by the menu panel checkbox; FleetStore.updateRemote preserves
        // the values as of just before saving. Here, validation uses the values
        // from when the editor was opened.
        RemoteSourceConfiguration(
            id: context.configuration.id,
            label: label,
            sshAlias: sshAlias,
            sessionName: sessionName,
            pollInterval: pollInterval,
            isVisible: context.configuration.isVisible,
            isEnabled: context.configuration.isEnabled
        )
    }

    private var validationMessage: String? {
        candidate.validationError?.localizedDescription
    }
}
