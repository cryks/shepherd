// ポップアウトウィンドウ。メニューバーパネルと同じ一覧 (SourceList) を通常の
// ウィンドウへ切り離し、作業中も群れ全体を出しっぱなしにできるようにする。
// 接続先ごと、その中で workspace ごとに親エージェントを一覧し、ローカル行は
// herdr の該当 pane へ駆けつけ、リモート行は監視専用で操作を持たない。
// このビューの表示/非表示が store.monitorWindowVisible の唯一の書き込み元。
//
// ウィンドウの外観はこのファイルが所有する: 標準の不透明なウィンドウ背景の
// 上に、SourceList (window スタイル) がセクションごとの角丸カードを浮かべる。
// タイトルバーは標準のまま使い、traffic lights との整列・ウィンドウのドラッグ・
// スクロール時の titlebar 区切りは AppKit に任せる。タイトル文字列だけは、
// 標準の window title 表示が持つ大きな leading インセット (macOS 26) を避ける
// ため removing: .title で消し、traffic lights 直後の navigation 位置へ自前の
// Text として置く (Window("Shepherd") のタイトルは Mission Control などの
// ウィンドウ一覧表示に残る)。右上には状態別エージェント数のチップを足す。

import SwiftUI

struct MonitorView: View {
    var store: FleetStore

    var body: some View {
        ScrollView {
            SourceList(sections: store.sourceSections, style: .window) { pane in
                store.focus(pane, sourceID: .local)
            }
        }
        .toolbar(removing: .title)
        .toolbar {
            // macOS 26 の toolbar は item を Liquid Glass の台座に載せるが、
            // タイトルと押せない表示専用のチップに操作部品の見た目は
            // 不釣り合いなので、両方とも sharedBackgroundVisibility で消す。
            if #available(macOS 26.0, *) {
                ToolbarItem(placement: .navigation) {
                    titleLabel
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) {
                    statusSummary
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .navigation) {
                    titleLabel
                }
                ToolbarItem(placement: .primaryAction) {
                    statusSummary
                }
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .onAppear { store.monitorWindowVisible = true }
        .onDisappear { store.monitorWindowVisible = false }
    }

    private var titleLabel: some View {
        Text("Shepherd")
            .font(.headline)
    }

    /// 状態別エージェント数のチップ列。件数 0 の状態は出さず、全状態が 0
    /// (エージェントなし・未接続) では何も描かない。並びはメニューバー集約
    /// (aggregateMenuBarState) と同じ重要度順: blocked → done → working。
    /// trailing 6pt は、toolbar 右端の既定余白だけではチップの capsule が
    /// ウィンドウ端に近すぎるための追い足し。
    private var statusSummary: some View {
        HStack(spacing: 6) {
            ForEach(statusCounts, id: \.status) { entry in
                HStack(spacing: 5) {
                    Circle()
                        .fill(entry.status.indicatorColor)
                        .frame(width: 7, height: 7)
                    Text("\(entry.count)")
                        .font(.caption.weight(.medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.quinary, in: Capsule())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(summaryLabel(for: entry))
            }
        }
        .padding(.trailing, 6)
    }

    /// ウィンドウに表示中のセクション (sourceSections) と同じ範囲の集計。
    /// 監視 OFF のリモートは一覧と同様にサマリへも入れない。
    /// idle / unknown は「動きのある状態」ではないため数えない。
    private var statusCounts: [(status: AgentStatus, count: Int)] {
        let statuses = store.sourceSections
            .flatMap(\.workspaceGroups)
            .flatMap(\.panes)
            .map(\.agentStatus)
        return [AgentStatus.blocked, .done, .working].compactMap { status in
            let count = statuses.count(where: { $0 == status })
            return count > 0 ? (status, count) : nil
        }
    }

    private func summaryLabel(for entry: (status: AgentStatus, count: Int)) -> String {
        switch entry.status {
        case .blocked:
            tr("\(entry.count) blocked", ja: "入力待ち \(entry.count)")
        case .done:
            tr("\(entry.count) done", ja: "完了 \(entry.count)")
        default:
            tr("\(entry.count) working", ja: "作業中 \(entry.count)")
        }
    }
}
