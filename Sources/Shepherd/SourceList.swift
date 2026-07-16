// メニューパネルとポップアウトウィンドウが共有する複数接続先の一覧。リモートが
// 1 つでも表示されている間は見出しで接続先を区切り、リモートは監視 OFF でも
// 同じ見出しを残す。ローカルの見出しは、接続先がローカルだけのとき、または
// LocalSectionTitleSetting の hidden 設定のときに省き、agent 行を直接並べる。
// ローカルだけに onFocus を渡し、リモート行は同じ情報密度のまま監視専用表示にする。
//
// 同じセクション列を Style で 2 通りに描き分ける:
// - menu: パネル面へ直接行を並べる NSMenu の流儀。見出しは headline で、
//   リモート見出しに監視 ON/OFF の checkbox を載せる (OFF は checkbox が
//   表すため本文を描かない)。
// - window: ウィンドウ背景の上にセクション本文を角丸カードとして一段浮かせる
//   設定アプリ風。checkbox は載せず、監視 OFF はカード内の 1 行で表す。

import SwiftUI

struct SourceList: View {
    /// 置かれる面ごとの体裁。行ホバーの表現 (AgentRow.HoverStyle) も面に従う。
    enum Style {
        case menu
        case window

        var hoverStyle: AgentRow.HoverStyle {
            switch self {
            case .menu: .menu
            case .window: .list
            }
        }
    }

    let sections: [FleetSourceSection]
    let style: Style
    let onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)?
    let onLocalFocus: (Pane) -> Void

    init(
        sections: [FleetSourceSection],
        style: Style,
        onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)? = nil,
        onLocalFocus: @escaping (Pane) -> Void
    ) {
        self.sections = sections
        self.style = style
        self.onRemoteEnabledChange = onRemoteEnabledChange
        self.onLocalFocus = onLocalFocus
    }

    /// 見出しの有無: リモート section が 1 つもない一覧はローカルのみで、見出しが
    /// 接続先の区別という役目を持たないため出さない。リモートがあるときは各 section
    /// の headerTitle に従う (ローカルの hidden 設定だけが nil を返す)。
    private var hasRemoteSections: Bool {
        sections.contains(where: \.isRemote)
    }

    var body: some View {
        switch style {
        case .menu: menuLayout
        case .window: windowLayout
        }
    }

    // MARK: - menu

    private var menuLayout: some View {
        // MenuPanel は中身の実寸から window 高さを決めるため、遅延 stack ではなく
        // 全 source を測れる VStack を使う。表示件数は Herdr の親 agent 数に限られる。
        // spacing 16 はセクション末尾の行の下 3pt と合算して 19pt。workspace 見出しの
        // 区切り (11pt) より一段広く取り、接続先の切れ目を workspace の切れ目より
        // 強く見せる。
        let showsFirstHeader = hasRemoteSections && sections.first?.headerTitle != nil
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(sections) { section in
                MenuSourceSection(
                    section: section,
                    headerTitle: hasRemoteSections ? section.headerTitle : nil,
                    onRemoteEnabledChange: onRemoteEnabledChange,
                    onLocalFocus: onLocalFocus
                )
            }
        }
        // 実効の上余白は 12pt に揃える: 先頭 section (常にローカル) が見出しを出すときは
        // 見出し自身が上余白を持たないのでそのまま 12pt、見出しなしでは先頭が workspace
        // 見出し (上 6pt 持ち) になるので 6pt を足して合計 12pt。この 12pt はメニュー
        // パネルの外形角丸 (約 12pt) の湾曲が及ぶ範囲を先頭のテキストが抜けるための値
        // でもある。下 8pt はセクション末尾の行の下 3pt と合算した 11pt が実効の余白で、
        // 上端 12pt とほぼ対称になる。
        .padding(.top, showsFirstHeader ? 12 : 6)
        .padding(.bottom, 8)
    }

    // MARK: - window

    private var windowLayout: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(sections) { section in
                WindowSourceSection(
                    section: section,
                    headerTitle: hasRemoteSections ? section.headerTitle : nil,
                    onLocalFocus: onLocalFocus
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

// MARK: - メニューパネル用セクション

private struct MenuSourceSection: View {
    let section: FleetSourceSection
    /// 見出し行の文字列。nil は見出しなし (接続先がローカルのみ、またはローカルの
    /// hidden 設定)。リモート section は checkbox を見出しに載せるため、リモートが
    /// 存在する間は呼び出し側が常に非 nil を渡す。
    let headerTitle: String?
    let onRemoteEnabledChange: ((HerdrSourceID, Bool) -> Void)?
    let onLocalFocus: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let headerTitle {
                header(title: headerTitle)
                    .padding(.horizontal, 17)
                    // 監視オフでは本文行がなく見出しがセクション末尾になるため、
                    // 行下と同じ 3pt を持たせてセクション間隔 16pt との合算 19pt を保つ。
                    .padding(.bottom, section.state == .disabled ? 3 : 0)
            }

            if section.state == .ready {
                if section.workspaceGroups.isEmpty {
                    stateMessage(tr("No agents", ja: "エージェントがいません"))
                } else {
                    AgentGroupList(
                        sourceID: section.id,
                        groups: section.workspaceGroups,
                        hoverStyle: .menu,
                        onFocus: section.isRemote ? nil : onLocalFocus
                    )
                }
            } else if let message = section.statusMessage {
                stateMessage(message)
            }
        }
    }

    @ViewBuilder
    private func header(title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            if let configuration = section.configuration,
               let onRemoteEnabledChange {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { configuration.isEnabled },
                        set: { onRemoteEnabledChange(configuration.id, $0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .accessibilityLabel(tr(
                    "Monitor \(configuration.displayName)",
                    ja: "\(configuration.displayName) の監視"
                ))
            }
        }
    }

    private func stateMessage(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 17)
            // AgentGroupList の縦リズムに合わせる: 見出しからは VStack spacing 2 と
            // 合算で 8pt (workspace 見出しと同じ)、セクション境界へは行と同じ 3pt を
            // 出してセクション間隔 16pt に足す。
            .padding(.top, 6)
            .padding(.bottom, 3)
    }
}

// MARK: - ポップアウトウィンドウ用セクション

/// セクション本文を角丸カードに包む。見出しはカードの外側のラベルで、
/// カードの中は menu と同じ AgentGroupList (workspace 見出し + 行)。
/// checkbox を持たないため、監視 OFF はカード内の「監視オフ」1 行で示す。
private struct WindowSourceSection: View {
    let section: FleetSourceSection
    /// 見出し行の文字列。nil は見出しなし (接続先がローカルのみ、またはローカルの
    /// hidden 設定) で、カードだけを描く。
    let headerTitle: String?
    let onLocalFocus: (Pane) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let headerTitle {
                // カード外のラベル。カード内テキストより一段小さく・薄くして、
                // カード (中身) との階層差を付ける。横 4pt はカードの角丸の
                // 湾曲とテキスト左端の視覚揃えのための微調整。
                Text(headerTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }

            if section.state == .ready {
                if section.workspaceGroups.isEmpty {
                    card { stateMessage(tr("No agents", ja: "エージェントがいません")) }
                } else {
                    card {
                        AgentGroupList(
                            sourceID: section.id,
                            groups: section.workspaceGroups,
                            hoverStyle: .list,
                            onFocus: section.isRemote ? nil : onLocalFocus
                        )
                    }
                }
            } else if section.state == .disabled {
                // menu では見出しの checkbox が OFF を表すが、window に checkbox は
                // ないため状態文字列 (「監視オフ」) を本文として出す。
                card { stateMessage(MonitoredSourceState.disabled.message) }
            } else if let message = section.statusMessage {
                card { stateMessage(message) }
            }
        }
    }

    /// ウィンドウ背景から一段浮いた本文の面。quinary の塗りにヘアラインの縁を
    /// 重ねて、ライト・ダークどちらの外観でも輪郭が残るようにする。
    private func card(@ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quinary,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
        )
    }

    private func stateMessage(_ message: String) -> some View {
        Text(message)
            .font(.callout)
            .foregroundStyle(.secondary)
            // AgentGroupList の行テキストと同じ左端 (5 + 12 = 17pt)。
            .padding(.horizontal, 17)
            .padding(.vertical, 4)
    }
}
