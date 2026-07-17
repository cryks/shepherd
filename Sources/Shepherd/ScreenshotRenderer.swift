// Headless rendering of the README screenshots. Runs only when launched as
// `Shepherd --render-screenshots <dir>`: it assembles the real MenuPanel with a
// mock FleetStore, writes it out as PNGs, then exits the process. It depends on
// no real herdr, SSH, or UserDefaults configuration and never shows a window on
// screen, so a dev machine and CI produce the same image (only font rendering
// differs by OS version).
//
// Data is pinned through the same injection points as the tests: the local and
// remote Stores are given .ready(AgentSnapshot) directly, and the tunnel is a
// stub that always reports ready. FleetStore.start() is never called, so no
// poll or RPC runs.
//
// The README has English and Japanese editions, so we toggle LanguageSetting
// and write two images: menu-panel.png (English) and menu-panel-ja.png
// (Japanese). Output PNGs are 2x the logical size; the README pins the width to
// the logical size so edges stay crisp on Retina displays.

import AppKit
import SwiftUI

@MainActor
enum ScreenshotRenderer {
    /// If the command line contains `--render-screenshots <dir>`, writes the
    /// screenshots and returns true. When true, the caller skips launching the
    /// app and exits main.
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
        // Initialize NSApplication so we can create an NSWindow. With
        // .prohibited, no Dock icon or menu bar appears, and the window is
        // never ordered front.
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("出力ディレクトリ作成失敗: \(directory.path) \(error)")
        }

        // Pin the local heading (This Mac / この Mac) to the default wording so
        // display settings left in the running environment's UserDefaults don't
        // leak into the image.
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

    /// Mock with 2 local workspaces + 1 remote host. The smallest configuration
    /// that fits, in a single image, the three states working / blocked / done,
    /// two brand marks (claude, codex), branch display, and connection headings.
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
        // An offscreen window that is never ordered front. MenuPanel determines
        // its own height by capturing the list's actual size into @State via
        // onGeometryChange, so a single standalone layout pass of the view does
        // not settle the height. We mount it in a window and spin the RunLoop so
        // the measured size feeds back and re-layout converges before drawing.
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

/// Composition for the shot: MenuPanel placed on a panel-like surface. The real
/// panel surface (material background and roughly 14pt rounded corners) is
/// drawn by the OS as the MenuBarExtra's window, so headless rendering
/// substitutes a background color + the same corner radius + a shadow. The
/// outer padding is the margin that keeps the shadow from being clipped and is
/// transparent in the exported PNG.
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

/// Stub tunnel that reports ready from creation. It launches no SSH process and
/// satisfies only the path where MonitoredSource publishes the remote snapshot
/// on the assumption that the tunnel is ready.
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
