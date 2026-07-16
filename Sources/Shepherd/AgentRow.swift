// エージェント 1 匹分の行 (AgentRow) と、workspace ごとの見出し付き一覧
// (AgentGroupList)。監視ウィンドウとメニューバーパネルの両方で使う共通部品で、
// 行の構成や見出しの体裁を変える拡張はこのファイルだけで両方の表示に反映される。
// AgentRow は左に StatusIcons の丸 (メニューバー本体と同じ描画)、右に作業タイトルと
// サブ行 (エージェントのブランドマーク + ブランチ名) の 2 行 + ステータス文字列。
// ホバー時の強調だけは、行を置く面のネイティブ流儀に合わせるため HoverStyle で切り替える。
// ローカル source の行は agent.focus を持つ Button、リモート source の行は監視専用の
// 静的表示になる。どちらも同じ行レイアウトを共有し、操作できない行を disabled の
// 薄い表示にはしない。

import AppKit
import SwiftUI

/// workspace ごとの見出し (caption) + AgentRow の縦積み。スクロールや寸法の管理は
/// 持たないので、呼び出し側が ScrollView などで包む。行クリック時の動作
/// (pane フォーカスに加えてパネルを閉じるか等) は onFocus で呼び出し側が決める。
struct AgentGroupList: View {
    let sourceID: HerdrSourceID
    let groups: [(workspace: Workspace, panes: [Pane])]
    let hoverStyle: AgentRow.HoverStyle
    let onFocus: ((Pane) -> Void)?

    private var identifiedGroups: [IdentifiedWorkspaceGroup] {
        groups.map { group in
            IdentifiedWorkspaceGroup(
                id: SourceWorkspaceID(
                    sourceID: sourceID,
                    workspaceID: group.workspace.workspaceId
                ),
                workspace: group.workspace,
                panes: group.panes.map { pane in
                    IdentifiedPane(
                        id: SourcePaneID(sourceID: sourceID, paneID: pane.paneId),
                        pane: pane
                    )
                }
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(identifiedGroups) { group in
                Text(group.workspace.label ?? group.workspace.workspaceId)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                ForEach(group.panes) { identifiedPane in
                    AgentRow(
                        pane: identifiedPane.pane,
                        hoverStyle: hoverStyle,
                        onFocus: onFocus.map { action in
                            { action(identifiedPane.pane) }
                        }
                    )
                }
            }
        }
        // 横 5pt はハイライトが面の端から持つインセットで、MenuPanel 下部の
        // MenuItem と同じ値。見出し・行内の 12pt (テキストインセット) と合算した
        // 17pt が、面の端からのテキスト開始位置として全行で揃う。
        // 縦の余白は持たない。source 見出しとの間隔・セクション間・面の端までの
        // 距離は置かれる文脈で値が違うため、SourceList 側が所有する。
        .padding(.horizontal, 5)
    }

    private struct IdentifiedWorkspaceGroup: Identifiable {
        let id: SourceWorkspaceID
        let workspace: Workspace
        let panes: [IdentifiedPane]
    }

    private struct IdentifiedPane: Identifiable {
        let id: SourcePaneID
        let pane: Pane
    }
}

struct AgentRow: View {
    /// ホバー時の強調表示。同じ行を監視ウィンドウの List とメニューパネルに置くが、
    /// ネイティブでの選択表現が面ごとに違うため呼び出し側が選ぶ。
    enum HoverStyle {
        /// 監視ウィンドウの List 向け。控えめなグレー (quaternary) を敷くだけで前景色は変えない。
        case list
        /// メニューバーパネル向け。NSMenu の選択状態 (アクセント色背景 + 選択前景色) を
        /// 再現し、MenuPanel 下部の MenuItem と見た目を揃える。
        case menu
    }

    let pane: Pane
    let hoverStyle: HoverStyle
    /// 行クリック時の駆けつけ動作。nil は remote の監視専用行を表し、
    /// Button と hover feedback を作らない。
    let onFocus: (() -> Void)?

    @State private var isHovered = false
    @AppStorage(colorAgentIconsKey) private var colorAgentIcons = false

    var body: some View {
        Group {
            if let onFocus {
                Button(action: onFocus) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 12)
        // 前景色はここで一括して切り替える。subtitle の .secondary や template 描画の
        // マークは階層スタイルとしてこの色から派生するため、menu の反転に個別対応が要らない。
        .foregroundStyle(isMenuHighlighted ? Color(nsColor: .selectedMenuItemTextColor) : Color.primary)
        .background(
            hoverBackground,
            in: RoundedRectangle(cornerRadius: hoverCornerRadius, style: .continuous)
        )
        .onHover { isHovered = onFocus == nil ? false : $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(nsImage: StatusIcons.icon(for: pane.agentStatus))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pane.displayTitle)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Spacer()
                    Text(pane.agentStatus.rawValue)
                        .font(.caption)
                        // ネイティブメニューは選択中の文字を選択前景色へ一律に反転するので、
                        // menu のホバー中だけステータスの意味色を外して親の前景色に従える。
                        .foregroundStyle(
                            isMenuHighlighted
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(pane.agentStatus.indicatorColor)
                        )
                }
                subtitle
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
    }

    /// menu 流儀のホバー中か。前景色の反転はこの状態だけで行い、
    /// list 流儀は背景を敷くだけで文字色を通常表示のまま保つ。
    private var isMenuHighlighted: Bool { isHovered && hoverStyle == .menu }

    private var hoverBackground: AnyShapeStyle {
        guard isHovered else { return AnyShapeStyle(.clear) }
        switch hoverStyle {
        case .list: return AnyShapeStyle(.quaternary)
        case .menu: return AnyShapeStyle(Color(nsColor: .selectedContentBackgroundColor))
        }
    }

    /// menu は MenuPanel の MenuItem (半径 9 = パネル外形の角丸約 14pt − インセット 5pt
    /// の同心値) と角丸を合わせ、同一パネル内でハイライトの形を揃える。
    private var hoverCornerRadius: CGFloat {
        switch hoverStyle {
        case .list: 6
        case .menu: 9
        }
    }

    /// サブ行。マークアセットを持つ agent は「ブランドマーク + ブランチ名」で示し、
    /// agent 名の文字列はホバーの tooltip に退避する。branch が無い pane
    /// (非 git・detached HEAD・取得失敗) はマークだけを出す。マークが無い agent は
    /// displaySubtitle のテキスト表示のまま。
    /// マークの塗りは設定 (colorAgentIconsKey) で切り替える。mono は黒塗りアセットを
    /// template 描画してサブ行の secondary 前景色とダークモードに追従させ、
    /// color はブランド色を残すため original 描画にする。
    @ViewBuilder
    private var subtitle: some View {
        let style: AgentIconStyle = colorAgentIcons ? .color : .mono
        if let agent = pane.agent, let mark = AgentIcons.icon(for: agent, style: style) {
            HStack(spacing: 4) {
                Image(nsImage: mark)
                    .renderingMode(style == .mono ? .template : .original)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                if let branch = pane.branch {
                    Text(branch)
                }
            }
            .help(agent)
        } else {
            Text(pane.displaySubtitle)
        }
    }

}

extension AgentStatus {
    /// 状態の意味色。AgentRow のステータス文字列と、ポップアウトウィンドウの
    /// ヘッダーサマリのドットが共用する。メニューバー丸 (StatusIcons) の
    /// systemYellow / systemGreen / systemRed と同系色で、視覚言語を揃える。
    var indicatorColor: Color {
        switch self {
        case .working: .yellow
        case .blocked: .red
        case .done: .green
        case .idle: .secondary
        case .unknown: .gray.opacity(0.5)
        }
    }
}
