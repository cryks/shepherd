// README 用スクリーンショットのヘッドレス描画。`Shepherd --render-screenshots <dir>`
// で起動されたときだけ動き、モックの FleetStore で実物の MenuPanel を組み立てて
// PNG に書き出したらプロセスを終える。herdr・SSH・UserDefaults の実設定には
// 依存せず、ウィンドウを画面へ表示しないため、開発機でも CI でも同じ絵が出る
// (フォントレンダリングの差だけ OS バージョンに依存する)。
//
// データはテストと同じ注入口で固定する: ローカルとリモートの Store へ
// .ready(AgentSnapshot) を直接与え、tunnel は常に ready を返すスタブにする。
// FleetStore.start() は呼ばないので poll も RPC も走らない。
//
// README は英語版と日本語版があるため、LanguageSetting を切り替えて
// menu-panel.png (英語) と menu-panel-ja.png (日本語) の 2 枚を書き出す。
// 出力は論理サイズの 2 倍の PNG で、README 側は width を論理サイズに固定して
// Retina でも縁が滲まないようにする。

import AppKit
import SwiftUI

@MainActor
enum ScreenshotRenderer {
    /// コマンドラインに `--render-screenshots <dir>` があればスクリーンショットを
    /// 書き出して true を返す。true のとき呼び出し側はアプリを起動せず main を抜ける。
    static func runIfRequested() -> Bool {
        let arguments = CommandLine.arguments
        guard let flagIndex = arguments.firstIndex(of: "--render-screenshots") else {
            return false
        }
        guard arguments.indices.contains(flagIndex + 1) else {
            FileHandle.standardError.write(
                Data("usage: Shepherd --render-screenshots <出力ディレクトリ>\n".utf8)
            )
            exit(1)
        }
        render(into: URL(fileURLWithPath: arguments[flagIndex + 1], isDirectory: true))
        return true
    }

    private static func render(into directory: URL) {
        // NSWindow を作るために NSApplication を初期化する。prohibited で
        // Dock アイコンもメニューバーも出さず、ウィンドウも orderFront しない。
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("出力ディレクトリ作成失敗: \(directory.path) \(error)")
        }

        // ローカル見出し (This Mac / この Mac) を既定表記に固定し、
        // 実行環境の UserDefaults に残った表示設定を絵へ持ち込まない。
        LocalSectionTitleSetting.shared.style = .standard
        let store = makeStore()
        let variants: [(language: AppLanguage, filename: String)] = [
            (.english, "menu-panel.png"),
            (.japanese, "menu-panel-ja.png"),
        ]
        for variant in variants {
            LanguageSetting.shared.selection = variant.language
            writePanelImage(
                store: store,
                to: directory.appendingPathComponent(variant.filename)
            )
        }
    }

    /// ローカル 2 workspace + リモート 1 台のモック。working / blocked / done の
    /// 3 状態、ブランドマーク 2 種 (claude, codex)、ブランチ表示、接続先見出しが
    /// 1 枚に収まる最小構成にする。
    private static func makeStore() -> FleetStore {
        let localSnapshot = AgentSnapshot(
            agents: [
                Pane(
                    agent: "claude",
                    agentStatus: .working,
                    paneId: "local:1",
                    workspaceId: "ws-shepherd",
                    terminalId: "term-1",
                    terminalTitleStripped: "Refactor tunnel retry backoff",
                    tokens: nil
                ),
                Pane(
                    agent: "codex",
                    agentStatus: .blocked,
                    paneId: "local:2",
                    workspaceId: "ws-herdr",
                    terminalId: "term-2",
                    terminalTitleStripped: "Approve: run swift test",
                    tokens: nil
                ),
            ],
            workspaces: [
                Workspace(workspaceId: "ws-shepherd", label: "shepherd", number: 1),
                Workspace(workspaceId: "ws-herdr", label: "herdr", number: 2),
            ],
            branches: [
                "ws-shepherd": "main",
                "ws-herdr": "fix/pty-resize",
            ]
        )
        let remoteSnapshot = AgentSnapshot(
            agents: [
                Pane(
                    agent: "claude",
                    agentStatus: .done,
                    paneId: "remote:1",
                    workspaceId: "ws-webapp",
                    terminalId: "term-3",
                    terminalTitleStripped: "Add payment flow integration tests",
                    tokens: nil
                )
            ],
            workspaces: [
                Workspace(workspaceId: "ws-webapp", label: "webapp", number: 1)
            ],
            branches: ["ws-webapp": "feature/checkout"]
        )
        let remote = RemoteSourceConfiguration(
            id: .remote(uuid: UUID(uuidString: "9D2A7A80-0000-4000-8000-000000000001")!),
            label: "devbox",
            sshAlias: "devbox"
        )
        return FleetStore(
            repository: RemoteSourceRepository(load: { [remote] }, save: { _ in }),
            localStore: Store(initialState: .ready(localSnapshot)),
            tunnelFactory: { configuration in
                StaticReadyTunnel(configuration: configuration)
            },
            remoteStoreFactory: { _, _ in Store(initialState: .ready(remoteSnapshot)) }
        )
    }

    private static func writePanelImage(store: FleetStore, to url: URL) {
        let hosting = NSHostingView(rootView: PanelScreenshot(store: store))
        hosting.appearance = NSAppearance(named: .aqua)
        // orderFront しないオフスクリーンウィンドウ。MenuPanel はリスト実寸を
        // onGeometryChange で @State に取り込んで自分の高さを決めるため、
        // ビュー単体の 1 回のレイアウトでは高さが確定しない。ウィンドウに載せて
        // RunLoop を回し、実寸反映 → 再レイアウトを収束させてから描画する。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 900),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        for _ in 0..<3 {
            hosting.setFrameSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        }
        window.setContentSize(hosting.fittingSize)
        hosting.layoutSubtreeIfNeeded()

        let bounds = hosting.bounds
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { fatalError("NSBitmapImageRep 作成失敗: \(url.lastPathComponent)") }
        rep.size = bounds.size
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fatalError("PNG 変換失敗: \(url.lastPathComponent)")
        }
        do {
            try png.write(to: url)
        } catch {
            fatalError("PNG 出力失敗: \(url.path) \(error)")
        }
    }
}

/// MenuPanel をパネル風の面に載せた撮影用構図。実物のパネル面 (素材背景と
/// 円換算約 14pt の角丸) は MenuBarExtra のウィンドウとして OS が描くため、
/// ヘッドレスでは背景色 + 同じ角丸 + 影で置き換える。外周の padding は
/// 影が切れずに収まる余白で、書き出した PNG では透明になる。
private struct PanelScreenshot: View {
    let store: FleetStore

    var body: some View {
        MenuPanel(store: store)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5)
            )
            .compositingGroup()
            .shadow(color: .black.opacity(0.22), radius: 16, y: 6)
            .padding(30)
    }
}

/// 生成時から ready を返すスタブ tunnel。SSH process は起動せず、
/// MonitoredSource が tunnel ready を前提に remote snapshot を公開する経路だけを満たす。
@MainActor
private final class StaticReadyTunnel: RemoteTunnelManaging {
    let configuration: RemoteSourceConfiguration
    let localSocketPath = "/dev/null"
    let state: RemoteTunnelState
    var onStateChange: ((RemoteTunnelState) -> Void)?

    init(configuration: RemoteSourceConfiguration) {
        self.configuration = configuration
        state = .ready(localSocketPath: localSocketPath)
    }

    func start() {
        onStateChange?(state)
    }

    func stop() {}
}
