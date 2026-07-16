// メニューバークリックで開くパネル (MenuBarExtra の .window スタイル)。
// NSMenu は複数行のアイテムを描画できないため、ネイティブメニューではなく
// SwiftUI ビューをそのまま出す。監視ウィンドウと同じ AgentRow を接続先と workspace
// の見出しで区切って並べ、下部に NSMenu のアイテムを模した操作項目
// (監視ウィンドウ開閉・設定・終了) を置く。パネルの開閉自体は MenuBarExtra が
// 管理し、ここでは行クリックなどの操作後に dismiss で明示的に閉じる。

import AppKit
import SwiftUI

struct MenuPanel: View {
    @Bindable var store: FleetStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var remoteMutationError: String?

    var body: some View {
        VStack(spacing: 0) {
            content
            VStack(spacing: 0) {
                Divider()
                footer
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                chromeHeight = height
            }
        }
        .frame(width: 340)
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                SourceList(
                    sections: store.sourceSections,
                    style: .menu,
                    onRemoteEnabledChange: setRemoteEnabled
                ) { pane in
                    store.focus(pane, sourceID: .local)
                    dismiss()
                }

                if let remoteMutationError {
                    Text(remoteMutationError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 17)
                        .padding(.bottom, 8)
                }
            }
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                listHeight = height
            }
        }
        .frame(height: min(max(listHeight, 56), maxListHeight))
        .background(PanelMaxHeightReader { height in
            panelMaxHeight = height
        })
    }

    /// リスト実寸。MenuBarExtra の window はビューの理想サイズでパネルの大きさを
    /// 決めるが、ScrollView は理想高さを持たず 0 に潰れるため、中身の実寸を
    /// 測って ScrollView の高さとして与える (上限を超えたらスクロール)。
    @State private var listHeight: CGFloat = 0

    /// パネル全体が取りうる最大高。パネル上端 (メニューバー直下) から
    /// screen.visibleFrame の底 (Dock を除いた画面下端) までの距離で、
    /// PanelMaxHeightReader が NSWindow から実測する。window に attach される前の
    /// 初回レイアウトでは nil。
    @State private var panelMaxHeight: CGFloat?

    /// リスト以外の部分 (区切り線 + footer) の実寸。パネル最大高からこれを
    /// 引いた残りがリストに割り当てられる。
    @State private var chromeHeight: CGFloat = 0

    /// リストの高さ上限。パネルが画面下端に届くまでリストを伸ばし、届いても
    /// 収まらない分は ScrollView のスクロールに任せる。パネル最大高が実測
    /// できるまでの初回レイアウトは、画面からはみ出さない保守的な固定値で開く
    /// (表示直後に実測値へ置き換わる)。
    private var maxListHeight: CGFloat {
        guard let panelMaxHeight else { return 440 }
        return max(panelMaxHeight - chromeHeight, 56)
    }

    private func setRemoteEnabled(_ id: HerdrSourceID, _ isEnabled: Bool) {
        do {
            try store.setRemoteEnabled(id: id, isEnabled: isEnabled)
            remoteMutationError = nil
        } catch {
            remoteMutationError = error.localizedDescription
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuItem(
                store.monitorWindowVisible
                    ? tr("Close Pop-Out Window", ja: "ポップアウトウィンドウを閉じる")
                    : tr("Pop Out as Window", ja: "ウィンドウとしてポップアウト")
            ) {
                if store.monitorWindowVisible {
                    dismissWindow(id: monitorWindowId)
                } else {
                    openWindow(id: monitorWindowId)
                    // LSUIElement アプリはウィンドウを開いても前面化しないので明示的に activate する。
                    NSApp.activate()
                }
                dismiss()
            }
            MenuSeparator()
            MenuItem(tr("Settings…", ja: "設定…")) {
                openSettings()
                // LSUIElement アプリはウィンドウを開いても前面化しないので明示的に activate する。
                NSApp.activate()
                dismiss()
            }
            MenuItem(tr("Quit Shepherd", ja: "Shepherd を終了")) {
                store.stop()
                NSApp.terminate(nil)
            }
        }
        // 横の余白は各 MenuItem がハイライトのインセットとして自前で持つ
        // (MenuSeparator をパネル全幅で引くため、ここでは縦だけ詰める)。
        .padding(.vertical, 5)
    }
}

/// NSMenu のアイテムを模したボタン。パネルが .window スタイルで NSMenu を使えない
/// ため、ホバー中の表示をネイティブメニューの選択状態 (アクセント色背景 + 選択前景色)
/// に揃えて、メニュー項目として読めるようにする。
/// 寸法は macOS 26 のネイティブ NSMenu の実測に合わせる: ハイライトはパネル端から
/// 5pt インセット、テキストはハイライト左端からさらに 12pt、アイテム高さ約 24pt。
/// ハイライトの角丸 9pt は、MenuBarExtra の window パネルを OS が円換算で約 14pt の
/// 角丸で描く (NSMenu の約 10pt より大きい) のに対し、インセット 5pt を引いた同心値。
/// 同心だと 2 つの角の曲線間の距離がどこでも 5pt に保たれ、パネルの角とハイライトの
/// 角が平行に見える。スタイルは OS がパネルの角に使う連続角丸 (裾が緩やかに立ち上がる
/// カーブ) と曲線族を揃えるため .continuous にする。
private struct MenuItem: View {
    let title: String
    let action: () -> Void

    @State private var isHighlighted = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            isHighlighted
                ? Color(nsColor: .selectedMenuItemTextColor)
                : Color.primary
        )
        .background(
            isHighlighted
                ? Color(nsColor: .selectedContentBackgroundColor)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .padding(.horizontal, 5)
        .onHover { isHighlighted = $0 }
    }
}

/// NSMenu のセパレータ相当。ネイティブ NSMenu の区切り線はインセットなしで
/// メニュー全幅に引かれるため、横パディングを持たない。
private struct MenuSeparator: View {
    var body: some View {
        Divider()
            .padding(.vertical, 5)
    }
}

/// パネルをホストする NSWindow から「パネルが画面下端まで伸びたときの最大高」を
/// 実測して通知する。MenuBarExtra の window パネルは上端がメニューバー直下に
/// 固定され下方向にだけ伸びるため、window 上端 (frame.maxY) から
/// screen.visibleFrame の底 (Dock を除いた画面下端) までがパネルの取りうる高さに
/// なる。SwiftUI から window には触れないので NSViewRepresentable で拾う。
private struct PanelMaxHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> WindowObservingView {
        let view = WindowObservingView()
        view.onMaxHeightChange = onChange
        return view
    }

    func updateNSView(_ view: WindowObservingView, context: Context) {}
}

/// window への attach と移動を監視して最大高を報告する NSView。
/// viewDidMoveToWindow の時点ではパネルの位置決めが済んでいないことがあるため
/// 1 tick 遅らせて frame を読む。加えて didMove / didChangeScreen を購読するのは、
/// メニューバーが複数ディスプレイにあると同じ window が別スクリーンへ移動して
/// 再表示されるためで、開き直しのたびに移動先のスクリーンで計算し直す。
/// パネルが下に伸びるときも origin が動いて didMove が届くが、上端 (maxY) は
/// 変わらないので報告値は同じになり、再レイアウトのループにはならない。
private final class WindowObservingView: NSView {
    var onMaxHeightChange: ((CGFloat) -> Void)?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        for name in [NSWindow.didMoveNotification, NSWindow.didChangeScreenNotification] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    self?.reportMaxHeight()
                }
            )
        }
        DispatchQueue.main.async { [weak self] in
            self?.reportMaxHeight()
        }
    }

    private func reportMaxHeight() {
        guard let window, let screen = window.screen else { return }
        onMaxHeightChange?(window.frame.maxY - screen.visibleFrame.minY)
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
