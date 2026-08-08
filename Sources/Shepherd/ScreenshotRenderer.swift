// Headless rendering of the README screenshots. It reaches no real herdr or
// SSH and puts no window on screen, so a dev machine and CI produce the same
// image apart from font rendering. The fixtures feed the real polling and
// excerpt pipeline, so the image shows what the extractor actually produces.
// The README has an English and a Japanese edition, hence the two variants,
// and it pins the image width to the logical size, hence the 2x output.

import AppKit
import SwiftUI

@MainActor
enum ScreenshotRenderer {
    // Returning true tells the caller to exit main instead of launching the
    // app.
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
        // An NSWindow needs NSApplication, and .prohibited keeps the Dock icon
        // and the menu bar away.
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fatalError("出力ディレクトリ作成失敗: \(directory.path) \(error)")
        }

        // Pinned so the UserDefaults of the machine that runs this cannot leak
        // into the image. Excerpts are off by default while experimental, but
        // the screenshots feature them.
        LocalSectionTitleSetting.shared.style = .standard
        RowLayoutSetting.shared.layout = .default
        ExcerptSetting.shared.isEnabled = true
        let store = makeStore()
        store.start()
        waitForExcerpts(store, paneIDs: [
            SourcePaneID(sourceID: .local, paneID: "local:1"),
            SourcePaneID(sourceID: .local, paneID: "local:2"),
            SourcePaneID(sourceID: Fixtures.remoteID, paneID: "remote:1"),
        ])
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
        store.stop()
    }

    // Scripted reads resolve within a few ticks; the settled remote pane still
    // waits for its 125ms verification read. A timeout means a fixture no
    // longer matches the extractor, and failing loudly beats shipping a
    // screenshot with a Loading placeholder.
    private static func waitForExcerpts(
        _ store: FleetStore,
        paneIDs: [SourcePaneID]
    ) {
        let deadline = Date(timeIntervalSinceNow: 10)
        while Date() < deadline {
            let allAvailable = paneIDs.allSatisfy { paneID in
                if case .available? = store.agentExcerptState(for: paneID) {
                    return true
                }
                return false
            }
            if allAvailable { return }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
        fatalError("excerpt が時間内に出揃いませんでした")
    }

    // Two local workspaces plus one remote host is the smallest set that fits
    // all of working / blocked / done, both brand marks, the branch display,
    // the three excerpt kinds, and the connection headings into one image.
    private static func makeStore() -> FleetStore {
        let localPanes = [
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
        ]
        let localWorkspaces = [
            Workspace(workspaceId: "ws-shepherd", label: "shepherd", number: 1),
            Workspace(workspaceId: "ws-herdr", label: "herdr", number: 2),
        ]
        let localSnapshot = AgentSnapshot(
            agents: localPanes,
            workspaces: localWorkspaces,
            branches: Fixtures.localBranches,
            raw: rawSnapshot(agents: localPanes, workspaces: localWorkspaces)
        )
        let remotePanes = [
            Pane(
                agent: "claude",
                agentStatus: .done,
                paneId: "remote:1",
                workspaceId: "ws-webapp",
                terminalId: "term-3",
                terminalTitleStripped: "Add payment flow integration tests",
                tokens: nil
            )
        ]
        let remoteWorkspaces = [
            Workspace(workspaceId: "ws-webapp", label: "webapp", number: 1)
        ]
        let remoteSnapshot = AgentSnapshot(
            agents: remotePanes,
            workspaces: remoteWorkspaces,
            branches: Fixtures.remoteBranches,
            raw: rawSnapshot(agents: remotePanes, workspaces: remoteWorkspaces)
        )
        let remote = RemoteSourceConfiguration(
            id: Fixtures.remoteID,
            label: "devbox",
            sshAlias: "devbox"
        )
        return FleetStore(
            repository: RemoteSourceRepository(load: { [remote] }, save: { _ in }),
            localStore: endpointStore(
                snapshot: localSnapshot,
                branches: Fixtures.localBranches,
                screens: [
                    "local:1": Fixtures.claudeWorkingScreen,
                    "local:2": Fixtures.codexApprovalScreen,
                ]
            ),
            tunnelFactory: { configuration in
                StaticReadyTunnel(configuration: configuration)
            },
            remoteStoreFactory: { _, _ in
                endpointStore(
                    snapshot: remoteSnapshot,
                    branches: Fixtures.remoteBranches,
                    screens: ["remote:1": Fixtures.claudeCompletedScreen]
                )
            }
        )
    }

    // The raw records the templates read. Deriving them from the same Pane and
    // Workspace values the typed snapshot carries keeps the two views of a
    // fixture from drifting apart. Only the fields the built-in templates name
    // are present; AgentSnapshot adds the branch to each workspace record.
    private static func rawSnapshot(
        agents: [Pane],
        workspaces: [Workspace]
    ) -> HerdrRawSnapshot {
        HerdrRawSnapshot(
            agents: Dictionary(uniqueKeysWithValues: agents.map { pane in
                (pane.paneId, JSONValue.object([
                    "agent": pane.agent.map(JSONValue.string) ?? .null,
                    "agent_status": .string(pane.agentStatus.rawValue),
                    "pane_id": .string(pane.paneId),
                    "workspace_id": .string(pane.workspaceId),
                    "tab_id": .string(tabID(for: pane)),
                    "terminal_id": pane.terminalId.map(JSONValue.string) ?? .null,
                    "terminal_title_stripped":
                        pane.terminalTitleStripped.map(JSONValue.string) ?? .null,
                ]))
            }),
            workspaces: Dictionary(uniqueKeysWithValues: workspaces.map { workspace in
                (workspace.workspaceId, JSONValue.object([
                    "workspace_id": .string(workspace.workspaceId),
                    "label": workspace.label.map(JSONValue.string) ?? .null,
                    "number": .int(Int64(workspace.number)),
                ]))
            }),
            tabs: Dictionary(uniqueKeysWithValues: agents.map { pane in
                (tabID(for: pane), JSONValue.object([
                    "tab_id": .string(tabID(for: pane)),
                    "workspace_id": .string(pane.workspaceId),
                ]))
            })
        )
    }

    // Every herdr pane belongs to a tab, so the fixtures give each one a tab
    // of its own.
    private static func tabID(for pane: Pane) -> String {
        "tab-\(pane.paneId)"
    }

    // The long poll interval leaves the initial fetch as the only one during
    // rendering.
    private static func endpointStore(
        snapshot: AgentSnapshot,
        branches: [String: String],
        screens: [String: String]
    ) -> Store {
        let fetch = SnapshotFetch(
            session: HerdrSessionSnapshot(
                version: "screenshot",
                protocolVersion: Herdr.supportedProtocol,
                agents: Array(snapshot.panes.values),
                workspaces: Array(snapshot.workspaces.values)
            ),
            raw: snapshot.raw
        )
        let worktrees = WorktreeListResult(
            worktrees: branches.map { workspaceID, branch in
                WorktreeEntry(branch: branch, openWorkspaceId: workspaceID)
            }
        )
        let info: [String: AgentGetResult] = snapshot.panes.mapValues { pane in
            AgentGetResult(agent: HerdrAgentInfo(
                agent: pane.agent,
                agentStatus: pane.agentStatus,
                paneId: pane.paneId,
                workspaceId: pane.workspaceId,
                tabId: tabID(for: pane),
                terminalId: pane.terminalId ?? pane.paneId,
                revision: 1,
                stateChangeSeq: 1,
                agentSession: nil
            ))
        }
        let reads: [String: AgentReadResult] = snapshot.panes.mapValues { pane in
            AgentReadResult(read: PaneRead(
                paneId: pane.paneId,
                workspaceId: pane.workspaceId,
                tabId: tabID(for: pane),
                source: .visible,
                format: .text,
                text: screens[pane.paneId] ?? "",
                revision: 1,
                truncated: false
            ))
        }
        return Store(
            dataSource: StoreDataSource(
                snapshot: { fetch },
                worktrees: { _ in worktrees }
            ),
            agentReadDataSource: AgentReadDataSource(
                get: { target in
                    guard let result = info[target] else {
                        throw ScreenshotFixtureError.unknownPane(target)
                    }
                    return result
                },
                readVisible: { target in
                    guard let result = reads[target] else {
                        throw ScreenshotFixtureError.unknownPane(target)
                    }
                    return result
                }
            ),
            pollInterval: .seconds(60)
        )
    }

    private static func writePanelImage(store: FleetStore, to url: URL) {
        let hosting = NSHostingView(rootView: PanelScreenshot(store: store))
        hosting.appearance = NSAppearance(named: .aqua)
        // MenuPanel sets its own height from the list size it captures into
        // @State through onGeometryChange, so one standalone layout pass never
        // settles. Mounting it in an offscreen window and spinning the RunLoop
        // lets the measured size feed back until layout converges.
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

private enum ScreenshotFixtureError: Error {
    case unknownPane(String)
}

// Shared by both language variants: the screens are agent output, not UI copy.
// They reproduce only the structure each extractor parses, and the prose is
// invented for the shot.
private enum Fixtures {
    static let remoteID = HerdrSourceID.remote(
        uuid: UUID(uuidString: "9D2A7A80-0000-4000-8000-000000000001")!
    )

    static let localBranches = [
        "ws-shepherd": "main",
        "ws-herdr": "fix/pty-resize",
    ]

    static let remoteBranches = ["ws-webapp": "feature/checkout"]

    // The extractor takes the newest prose block while the spinner runs.
    static let claudeWorkingScreen = """
    ⏺ Bash(swift test --filter TunnelRetry)
      ⎿ All tests passed

    ⏺ Backoff now caps at 30s; adding jitter to the reconnect
      path next.

    ✻ Simmering… (42s · ↓ 3.1k tokens)

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """

    // The extractor takes the question above the choices.
    static let codexApprovalScreen = """
      Would you like to run the following command?

      $ swift test

    › 1. Yes, proceed (y)
      2. No, and tell Codex what to do differently (esc)

      Press enter to confirm or esc to cancel
    """

    // The extractor takes the final reply of a completed turn.
    static let claudeCompletedScreen = """
    ⏺ Bash(swift test --filter PaymentFlow)
      ⎿ All tests passed

    ⏺ All 42 payment flow tests pass; checkout retry edge
      cases are covered.

    ────────────────────────────────────────────────────────
    ❯
    ────────────────────────────────────────────────────────
      ? for shortcuts
    """
}

// The OS draws the real panel surface (material background, about 14pt rounded
// corners) as the MenuBarExtra window, which headless rendering never gets, so
// the background color, corner radius, and shadow stand in for it. The outer
// padding keeps the shadow from being clipped and stays transparent in the
// exported PNG.
private struct PanelScreenshot: View {
    let store: FleetStore

    var body: some View {
        MenuPanel(store: store, updater: nil)
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

// Ready from creation and starts no SSH process: it serves only the path where
// MonitoredSource publishes the remote snapshot once the tunnel reports ready.
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
