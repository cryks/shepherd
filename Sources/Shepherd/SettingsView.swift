// Settings シーンの UI。一般設定とリモート監視先をタブで分ける。
// リモート編集は RemoteSourceConfiguration の validation を通った値だけを
// FleetStore へ渡し、SSH の password や秘密鍵は保存しない。認証・ProxyJump・鍵の
// 選択は `/usr/bin/ssh` が `~/.ssh/config` と ssh-agent から解決する。

import SwiftUI

/// エージェントのブランドマークをカラー表示するかの UserDefaults キー。
/// SettingsView が書き、AgentRow が読む。両者とも @AppStorage で参照するので
/// 切り替えは開いている行の表示へ即時反映される。
let colorAgentIconsKey = "ColorAgentIcons"

struct SettingsView: View {
    @Bindable var store: FleetStore

    var body: some View {
        TabView {
            GeneralSettingsView(store: store)
                .tabItem {
                    Label(tr("General", ja: "一般"), systemImage: "gearshape")
                }

            RemoteSourcesSettingsView(store: store)
                .tabItem {
                    Label(tr("Remotes", ja: "リモート"), systemImage: "network")
                }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettingsView: View {
    @Bindable var store: FleetStore
    @Bindable private var language = LanguageSetting.shared
    @Bindable private var localTitle = LocalSectionTitleSetting.shared
    @AppStorage(colorAgentIconsKey) private var colorAgentIcons = false
    @AppStorage(MenuBarIconPresentation.blinkEnabledKey) private var blinkMenuBarIcon = true

    var body: some View {
        Form {
            Toggle(tr("Launch at login", ja: "ログイン時に起動"), isOn: $store.launchAtLogin)
            Toggle(
                tr("Show agent icons in color", ja: "エージェントアイコンをカラーで表示"),
                isOn: $colorAgentIcons
            )
            Toggle(
                tr(
                    "Blink the menu bar icon when attention is needed",
                    ja: "対応が必要なときにメニューバーアイコンを点滅"
                ),
                isOn: $blinkMenuBarIcon
            )
            Picker(tr("This Mac label", ja: "この Mac の表記"), selection: $localTitle.style) {
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
            } else if localTitle.style == .hidden {
                Text(tr(
                    "Agents on this Mac are listed without a section title.",
                    ja: "この Mac のエージェントは見出しなしで一覧に並びます。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Picker(tr("Language", ja: "言語"), selection: $language.selection) {
                ForEach(AppLanguage.allCases) { candidate in
                    Text(verbatim: candidate.displayName).tag(candidate)
                }
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
        // 表示状態は設定一覧のトグルが、監視状態はメニューパネルの checkbox が所有し、
        // FleetStore.updateRemote が保存直前の値を維持する。ここでは editor を開いた
        // 時点の値で validation する。
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
