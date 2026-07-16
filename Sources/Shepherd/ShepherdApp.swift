// エントリポイント。LSUIElement (Dock 非表示) の常駐アプリとして、
// ローカル + 複数リモートを束ねる FleetStore をメニューバー項目・監視ウィンドウ・
// 設定の 3 シーンで共有する。
// 監視ウィンドウはメニューから明示的に開くもので、起動時に自動で開かない・
// 復元もしない (defaultLaunchBehavior / restorationBehavior で抑止)。
// 設定シーンも MenuPanel の「設定…」からだけ開く。

import AppKit
import Observation
import SwiftUI

/// macOS の終了経路 (メニュー、logout、terminate) を FleetStore の stop へ、
/// システムスリープ・復帰を poll の suspend / resume へ橋渡しする。終了時は
/// managed SSH process と一時 Unix socket をアプリ終了前に片付ける。
@MainActor
final class ShepherdApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: FleetStore?
    weak var menuBarBlinkClock: MenuBarBlinkClock?

    /// スリープ通知の観測 token。スリープ・復帰は NSWorkspace.shared.notificationCenter
    /// だけが配送するため、NotificationCenter.default ではなくそちらへ登録する。
    /// delegate はアプリと同寿命なので解除はしない。
    private var sleepObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_: Notification) {
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // queue: .main 指定なので main thread 配送で、assumeIsolated が成立する。
                MainActor.assumeIsolated {
                    self?.store?.suspendPolling()
                }
            },
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.store?.resumePolling()
                }
            },
        ]
    }

    func applicationWillTerminate(_: Notification) {
        menuBarBlinkClock?.stop()
        store?.stop()
    }
}

/// プロセスのエントリポイント。--render-screenshots (README 用スクリーンショットの
/// ヘッドレス描画) だけ ScreenshotRenderer へ分岐し、それ以外は SwiftUI の
/// App ライフサイクルを開始する。
@main
enum ShepherdMain {
    static func main() {
        // static main は main thread で呼ばれるが MainActor 隔離の宣言を持たないため、
        // assumeIsolated で ScreenshotRenderer (@MainActor) へ渡す。
        let didRenderScreenshots = MainActor.assumeIsolated {
            ScreenshotRenderer.runIfRequested()
        }
        guard !didRenderScreenshots else { return }
        ShepherdApp.main()
    }
}

struct ShepherdApp: App {
    @NSApplicationDelegateAdaptor(ShepherdApplicationDelegate.self)
    private var applicationDelegate
    @State private var store: FleetStore
    @State private var menuBarBlinkClock: MenuBarBlinkClock

    init() {
        let store = FleetStore()
        let menuBarBlinkClock = MenuBarBlinkClock {
            // 設定も tick ごとに読む。OFF へ切り替えた後は次の tick で表示フェーズへ戻る。
            MenuBarIconPresentation.blinkEnabled()
                && MenuBarIconPresentation.shouldBlink(store.menuBarState)
        }
        store.start()
        menuBarBlinkClock.start()
        _store = State(initialValue: store)
        _menuBarBlinkClock = State(initialValue: menuBarBlinkClock)
        applicationDelegate.store = store
        applicationDelegate.menuBarBlinkClock = menuBarBlinkClock
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            MenuBarIcon(store: store, blinkClock: menuBarBlinkClock)
        }
        .menuBarExtraStyle(.window)

        // ポップアウトウィンドウ。MonitorView が containerBackground で全面
        // material を敷き、toolbar item (状態サマリ) を足す。タイトルバーは
        // 標準のままで、タイトルと traffic lights の整列は AppKit に任せる。
        Window("Shepherd", id: monitorWindowId) {
            MonitorView(store: store)
        }
        .defaultSize(width: 380, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(store: store)
        }
    }
}

/// 監視ウィンドウのシーン ID。openWindow / dismissWindow で参照する。
let monitorWindowId = "monitor"

/// `MenuBarExtra` のラベルより長く生存し、点滅フェーズを 0.8 秒ごとに進める。
/// ラベルに付けた `task` は status item への変換後に継続実行されないため、App が
/// このクロックを所有する。非点滅状態では `blinkVisible` を書き換えず、quiet / working
/// の間にメニューバーを周期的に再描画しない。
@Observable @MainActor
final class MenuBarBlinkClock {
    /// true は表示フェーズ。点滅対象外、開始前、stop 後も true を保つ。
    private(set) var blinkVisible = true

    /// init で固定し、task の再開時にも同じ周期を使う。
    @ObservationIgnored private let phaseDuration: Duration
    /// 各 tick で最新の fleet 集約状態を読む。クロック自身は集約状態を保持しない。
    @ObservationIgnored private let shouldBlink: @MainActor () -> Bool
    /// nil は開始前または stop 後。非 nil の間は 1 本だけ sleep loop を所有する。
    @ObservationIgnored private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - phaseDuration: 表示・非表示の各フェーズを維持する時間。
    ///   - shouldBlink: tick 時点の集約状態が点滅対象かを返す。
    init(
        phaseDuration: Duration = MenuBarIconPresentation.blinkPhaseDuration,
        shouldBlink: @escaping @MainActor () -> Bool
    ) {
        self.phaseDuration = phaseDuration
        self.shouldBlink = shouldBlink
    }

    /// 点滅 tick を開始する。重複呼び出しでは既存 task を維持する。
    func start() {
        guard task == nil else { return }
        let phaseDuration = phaseDuration
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: phaseDuration)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                if shouldBlink() {
                    blinkVisible.toggle()
                } else if !blinkVisible {
                    blinkVisible = true
                }
            }
        }
    }

    /// tick を停止して表示フェーズへ戻す。アプリ終了時の task cancellation に使う。
    func stop() {
        task?.cancel()
        task = nil
        blinkVisible = true
    }
}

/// メニューバーに常駐するアイコン。ここが Shepherd の主表示で、
/// エージェント群の状態を 1 つの丸で表す:
///   - 点滅する赤●: blocked あり (入力待ち)
///   - 点滅する緑●: done あり (未閲覧の完了)
///   - 黄○: working あり            - 無色○: 全員 idle
///   - 破線○: ready の監視先が 0 件 (未接続 / protocol 不一致を含む)
/// 5 状態とも同一ジオメトリ (18pt キャンバス・外径 14pt) の自前描画で、
/// 状態によって丸の大きさが変わって見えないようにする。SF Symbols は
/// メニューバーでテンプレート描画になって色が剥がされるうえ、字形の
/// 視覚サイズも自前描画と揃わないため使わない。無色の 2 状態だけ
/// isTemplate = true にして、メニューバーの明暗に追従させる。
/// 点滅は、非表示フェーズで全透明の blinkHidden へ NSImage ごと差し替えて表す。
/// MenuBarExtra のラベルは NSStatusItem のボタンへ変換され、ビューの opacity の
/// 変化がステータス項目の描画に反映されないため、状態色の切り替えで実際に
/// 効いている「画像コンテンツの差し替え」と同じ経路に乗せる。
/// 各状態の NSImage 自体は書き換えないため、メニュー内と監視ウィンドウの
/// AgentRow は静止表示のまま。
struct MenuBarIcon: View {
    var store: FleetStore
    var blinkClock: MenuBarBlinkClock
    /// 点滅の有効設定。Settings の Toggle と同じキーを観測するので、OFF への
    /// 切り替えは次の tick を待たず即座に丸の表示へ戻す。
    @AppStorage(MenuBarIconPresentation.blinkEnabledKey) private var blinkEnabled = true

    var body: some View {
        Image(nsImage: image)
    }

    private var image: NSImage {
        if !MenuBarIconPresentation.showsStatusShape(
            for: store.menuBarState,
            blinkEnabled: blinkEnabled,
            blinkVisible: blinkClock.blinkVisible
        ) {
            // 全透明でもキャンバスが同一なので、ステータス項目の幅とクリック領域は残る。
            StatusIcons.blinkHidden
        } else {
            switch store.menuBarState {
            case .disconnected:
                StatusIcons.disconnected
            case .quiet:
                StatusIcons.quiet
            case .working:
                StatusIcons.working
            case .done:
                StatusIcons.done
            case .blocked:
                StatusIcons.blocked
            }
        }
    }
}

/// メニューバーのステータス項目だけが使う点滅規則。
/// 1 フェーズ 0.8 秒で表示と非表示を入れ替える。
/// 点滅そのものの有効・無効はユーザー設定 (blinkEnabledKey) で切り替えられる。
enum MenuBarIconPresentation {
    static let blinkPhaseDuration: Duration = .milliseconds(800)

    /// 点滅設定の UserDefaults キー。SettingsView の Toggle が書き、
    /// MenuBarIcon (@AppStorage) と ShepherdApp のクロック閉包 (blinkEnabled(in:)) が読む。
    static let blinkEnabledKey = "MenuBarBlinkEnabled"

    /// 保存済みの点滅設定。未保存 (キー欠落) は true (点滅する) に倒す。
    /// @AppStorage を使えない非 View 文脈 (クロック閉包) 用の直読み。
    nonisolated static func blinkEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: blinkEnabledKey) as? Bool ?? true
    }

    static func shouldBlink(_ state: MenuBarState) -> Bool {
        switch state {
        case .done, .blocked:
            return true
        case .disconnected, .quiet, .working:
            return false
        }
    }

    /// 状態の丸を描くフェーズなら true、点滅の非表示フェーズ (全透明画像に
    /// 差し替えるフェーズ) なら false。blinkEnabled が false のときと非点滅状態は
    /// blinkVisible に関係なく表示し、点滅設定が有効な done / blocked だけを
    /// タイマーが書き換えるフェーズに従わせる。
    static func showsStatusShape(
        for state: MenuBarState,
        blinkEnabled: Bool,
        blinkVisible: Bool
    ) -> Bool {
        !blinkEnabled || !shouldBlink(state) || blinkVisible
    }
}

/// メニューバー本体とメニュー内のエージェント行が共用する丸アイコン。
/// 全状態が同一ジオメトリなので、どこに並べても大きさが揃う。
/// 画像自体は静止画で、メニューバーの点滅は MenuBarIcon が blinkHidden への
/// 差し替えで行う。
enum StatusIcons {
    static let disconnected = circleImage(filled: false, dashed: true, template: true)
    static let quiet = circleImage(filled: false, template: true)
    static let working = circleImage(color: .systemYellow, filled: false)
    static let done = circleImage(color: .systemGreen, filled: true)
    static let blocked = circleImage(color: .systemRed, filled: true)

    /// 点滅の非表示フェーズ専用の全透明画像。他の状態と同じ 18pt キャンバスなので、
    /// 差し替えてもステータス項目の幅とクリック領域が変わらない。
    static let blinkHidden = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in true }

    /// エージェント個別のステータス表示。idle は無色 ○、unknown は破線 ○ に割り当てる。
    static func icon(for status: AgentStatus) -> NSImage {
        switch status {
        case .working: working
        case .blocked: blocked
        case .done: done
        case .idle: quiet
        case .unknown: disconnected
        }
    }

    /// 18pt キャンバス中央に外径 14pt の丸を描く。すべての状態でまず同じ
    /// リング (線幅 1.5、線幅の半分だけ内側に寄せて外径を揃える) を描き、
    /// filled のときはリングの内側に間隔 1.5pt を空けた塗り丸を重ねて
    /// 二重丸 (SF Symbols の circle.inset.filled 相当) にする。
    private static func circleImage(
        color: NSColor = .black,
        filled: Bool,
        dashed: Bool = false,
        template: Bool = false
    ) -> NSImage {
        let lineWidth: CGFloat = 1.5
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 2 + lineWidth / 2, dy: 2 + lineWidth / 2))
            if dashed {
                var pattern: [CGFloat] = [2.5, 2.0]
                ring.setLineDash(&pattern, count: pattern.count, phase: 0)
            }
            color.setStroke()
            ring.lineWidth = lineWidth
            ring.stroke()
            if filled {
                // リング内縁 (外径 14 - 線幅 1.5×2 = 11) からさらに 1.5pt 空けた塗り丸。
                let dot = NSBezierPath(ovalIn: rect.insetBy(dx: 5, dy: 5))
                color.setFill()
                dot.fill()
            }
            return true
        }
        image.isTemplate = template
        return image
    }
}
