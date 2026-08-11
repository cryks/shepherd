import AppKit
import SwiftUI

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
        // The frame stays constant across tabs: SettingsWindowSizer owns the
        // window's size, and SwiftUI would fight it if the content sized
        // itself per tab. The Display tab clips below the floor here, which
        // the sizer's per-tab minimum keeps from persisting.
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

enum SettingsTab: Hashable {
    case general
    case display
    case remotes
    case hotkeys

    // Layout size the three form tabs are written against.
    static let compactSize = CGSize(width: 520, height: 500)

    var defaultSize: CGSize {
        switch self {
        case .display: CGSize(width: 820, height: 560)
        case .general, .remotes, .hotkeys: Self.compactSize
        }
    }

    // Display's width is where its editor-plus-preview split starts clipping
    // its columns.
    var minimumSize: CGSize {
        switch self {
        case .display: CGSize(width: 760, height: 520)
        case .general, .remotes, .hotkeys: Self.compactSize
        }
    }
}

// AppKit sizes the window instead of SwiftUI: a TabView asks for the width its
// widest tab needs (the Display split) whichever tab is selected, so the
// compact tabs would open far too wide, and SwiftUI's resize on tab selection
// is instant where this animates.
private struct SettingsWindowSizer: NSViewRepresentable {
    let tab: SettingsTab

    final class Coordinator {
        var appliedTab: SettingsTab?
        // Kept so a resize survives leaving and revisiting a tab within one
        // app run.
        var rememberedSizes: [SettingsTab: CGSize] = [:]
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // AppKit sets a view's window before the window is ordered front, so this
    // is where the first size lands. Applied any later, the window is already
    // on screen at SwiftUI's size and the correction reads as a flash.
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
        // The first pass runs before SwiftUI attaches the view, so the handler
        // is what sizes the window on the first open; afterwards the window is
        // reachable here and a tab change takes the animating path.
        view.onAttachToWindow = { window in apply(tab, to: window, coordinator) }
        guard let window = view.window else { return }
        // updateNSView must not mutate state during an update pass.
        DispatchQueue.main.async { apply(tab, to: window, coordinator) }
    }

    private func apply(_ tab: SettingsTab, to window: NSWindow, _ coordinator: Coordinator) {
        guard coordinator.appliedTab != tab else { return }
        // Sizes are deltas against contentLayoutRect, the area below the tab
        // toolbar. The frameRect/contentRect conversions are styleMask-based
        // and leave the toolbar out, so a frame computed through them comes up
        // a toolbar short and clips the pane's bottom.
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
            // The window is still off screen and unplaced, so only its size is
            // ours to set here.
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
    @Bindable private var notificationSounds = NotificationSoundSetting.shared
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
                Picker(
                    tr("Sound when blocked", ja: "入力待ち時の通知音"),
                    selection: $notificationSounds.blockedSound
                ) {
                    soundChoiceOptions
                }
                .disabled(!notificationSettings.isEnabled)
                .onChange(of: notificationSounds.blockedSound) { _, choice in
                    Self.previewSound(choice)
                }
                Picker(
                    tr("Sound when done", ja: "完了時の通知音"),
                    selection: $notificationSounds.doneSound
                ) {
                    soundChoiceOptions
                }
                .disabled(!notificationSettings.isEnabled)
                .onChange(of: notificationSounds.doneSound) { _, choice in
                    Self.previewSound(choice)
                }
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
            // AppKit makes the first editable text field the initial first
            // responder when the window is ordered front. defaultFocus cannot
            // stop this — a Settings scene ignores it outright (checked on
            // macOS 26) — and FocusState has no "focus nothing" value. The
            // assignment lands in the same runloop turn that orders the window
            // front, so clearing one turn later undoes it without racing it.
            DispatchQueue.main.async { isLocalTitleFieldFocused = false }
        }
    }

    @ViewBuilder private var soundChoiceOptions: some View {
        Text(tr("None", ja: "なし")).tag(NotificationSoundChoice.none)
        Text(tr("Default", ja: "デフォルト")).tag(NotificationSoundChoice.systemDefault)
        Divider()
        ForEach(NotificationSoundSetting.systemSoundNames, id: \.self) { name in
            Text(verbatim: name).tag(NotificationSoundChoice.named(name))
        }
    }

    // Named sounds only: the file behind the systemDefault notification sound
    // is not exposed, so there is nothing to play for it.
    private static func previewSound(_ choice: NotificationSoundChoice) {
        guard case .named(let name) = choice else { return }
        NSSound(named: name)?.play()
    }

    // The app preference stays on after macOS denies delivery, so this warning
    // reports the separate system-side block instead of reverting the Toggle.
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
    @State private var reorder = RowReorder<HerdrSourceID>()

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.remoteConfigurations) { configuration in
                    remoteRow(configuration)
                        .tag(configuration.id)
                        .reorderableRow(reorder, id: configuration.id)
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
            RowGrabber(
                id: configuration.id,
                order: store.remoteConfigurations.map(\.id),
                reorder: reorder,
                move: moveRemote
            )

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

    private func moveRemote(fromOffsets source: IndexSet, toOffset destination: Int) {
        do {
            try store.moveRemote(fromOffsets: source, toOffset: destination)
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
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
        // Visibility belongs to the toggle in the settings list and monitoring
        // state to the menu panel checkbox. FleetStore.updateRemote keeps the
        // values as of just before saving, so the stale ones carried here only
        // feed validation.
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
