// Verifies source qualification of endpoint IDs, normalization/validation of remote SSH
// settings, and the JSON persistence contract in UserDefaults. No SSH process or runtime
// socket is created; only settings that persist across restarts are covered.

import Foundation
import XCTest
@testable import Shepherd

final class EndpointConfigurationTests: XCTestCase {
    func testUserDefaults往復で順序と安定IDを維持する() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = RemoteSourceRepository.userDefaults(defaults)
        let firstID = HerdrSourceID.remote(
            uuid: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        )
        let secondID = HerdrSourceID.remote(
            uuid: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        )
        let configurations = [
            RemoteSourceConfiguration(
                id: firstID,
                label: "Build",
                sshAlias: "build-box",
                sessionName: "agents",
                pollInterval: .halfSecond,
                isVisible: true,
                isEnabled: true
            ),
            RemoteSourceConfiguration(
                id: secondID,
                label: "Research",
                sshAlias: "research@example.com",
                sessionName: nil,
                pollInterval: .tenSeconds,
                isVisible: false,
                isEnabled: false
            ),
        ]

        try repository.save(configurations)
        let firstLoad = repository.load()
        let secondLoad = repository.load()

        XCTAssertEqual(firstLoad, configurations, "保存した設定の順序と値が変わっている")
        XCTAssertEqual(secondLoad.map(\.id), [firstID, secondID], "再読込で source ID が再発行された")
    }

    func testPoll周期未指定の保存値は二秒を使う() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = RemoteSourceRepository.userDefaults(defaults)
        defaults.set(
            Data(
                #"[{"id":"remote:44444444-4444-4444-4444-444444444444","label":"Remote","sshAlias":"workbox","sessionName":null,"isEnabled":true}]"#.utf8
            ),
            forKey: RemoteSourceRepository.userDefaultsKey
        )

        XCTAssertEqual(repository.load().first?.pollInterval, .twoSeconds)
    }

    func test表示フラグ未指定の保存値は表示ONを使う() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = RemoteSourceRepository.userDefaults(defaults)
        defaults.set(
            Data(
                #"[{"id":"remote:55555555-5555-5555-5555-555555555555","label":"Remote","sshAlias":"workbox","sessionName":null,"isEnabled":false}]"#.utf8
            ),
            forKey: RemoteSourceRepository.userDefaultsKey
        )

        XCTAssertEqual(repository.load().first?.isVisible, true)
    }

    func testPoll周期PresetをDurationへ変換する() {
        XCTAssertEqual(RemotePollingInterval.halfSecond.duration, .milliseconds(500))
        XCTAssertEqual(RemotePollingInterval.oneSecond.duration, .seconds(1))
        XCTAssertEqual(RemotePollingInterval.twoSeconds.duration, .seconds(2))
        XCTAssertEqual(RemotePollingInterval.fiveSeconds.duration, .seconds(5))
        XCTAssertEqual(RemotePollingInterval.tenSeconds.duration, .seconds(10))
    }

    func test壊れた永続データは空配列へ戻す() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let repository = RemoteSourceRepository.userDefaults(defaults)

        defaults.set(
            Data(#"[{"id":"remote:not-a-uuid"}"#.utf8),
            forKey: RemoteSourceRepository.userDefaultsKey
        )
        XCTAssertTrue(repository.load().isEmpty, "壊れた JSON を部分的な設定として読んだ")

        let unsafe = RemoteSourceConfiguration(
            label: "Unsafe",
            sshAlias: "-oProxyCommand=unexpected",
            sessionName: nil
        )
        defaults.set(
            try JSONEncoder().encode([unsafe]),
            forKey: RemoteSourceRepository.userDefaultsKey
        )
        XCTAssertTrue(repository.load().isEmpty, "validation に失敗する保存値を接続設定として読んだ")
    }

    func test表示名とセッション名を正規化する() throws {
        let configuration = RemoteSourceConfiguration(
            label: "  Build agents  \n",
            sshAlias: "  build-box  ",
            sessionName: "  nightly.v2  "
        )

        XCTAssertEqual(configuration.label, "Build agents")
        XCTAssertEqual(configuration.sshAlias, "build-box")
        XCTAssertEqual(configuration.displayName, "Build agents")
        XCTAssertEqual(configuration.normalizedSessionName, "nightly.v2")
        XCTAssertNoThrow(try configuration.validated())

        let fallback = RemoteSourceConfiguration(
            label: " \n ",
            sshAlias: "workbox",
            sessionName: " \t "
        )
        XCTAssertEqual(fallback.displayName, "workbox", "空ラベルが SSH alias へフォールバックしない")
        XCTAssertNil(fallback.normalizedSessionName, "空 session が既定 session の nil にならない")
    }

    func testHerdrSessionGrammar外の名前を拒否する() {
        for name in ["agents", "nightly.v2", "agent_1", "agent-1", "0"] {
            let configuration = RemoteSourceConfiguration(
                label: "Remote",
                sshAlias: "workbox",
                sessionName: name
            )
            XCTAssertNil(configuration.validationError, "許可される session 名を拒否した: \(name)")
        }

        for name in [".", "..", "agent/name", "agent name", "日本語"] {
            let configuration = RemoteSourceConfiguration(
                label: "Remote",
                sshAlias: "workbox",
                sessionName: name
            )
            XCTAssertEqual(
                configuration.validationError,
                .invalidSessionName(name),
                "grammar 外の session 名を受け入れた: \(name)"
            )
        }
    }

    func testSSHの引数に見える危険なAliasを拒否する() {
        let empty = RemoteSourceConfiguration(label: "Remote", sshAlias: " \n ")
        XCTAssertEqual(empty.validationError, .emptySSHAlias)

        for alias in ["-oProxyCommand=unexpected", "work box", "work\nbox", "work\u{0000}box"] {
            let configuration = RemoteSourceConfiguration(label: "Remote", sshAlias: alias)
            XCTAssertEqual(
                configuration.validationError,
                .unsafeSSHAlias(configuration.sshAlias),
                "危険な SSH alias を受け入れた"
            )
        }

        let reservedID = RemoteSourceConfiguration(
            id: .local,
            label: "Remote",
            sshAlias: "workbox"
        )
        XCTAssertEqual(reservedID.validationError, .invalidSourceID, "local の予約 ID を remote 設定へ使えた")
    }

    func test同じPaneとWorkspaceのIDをSourceごとに区別する() {
        let remote = HerdrSourceID.remote(
            uuid: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        )
        let localPane = SourcePaneID(sourceID: .local, paneID: "w1:p1")
        let remotePane = SourcePaneID(sourceID: remote, paneID: "w1:p1")
        let localWorkspace = SourceWorkspaceID(sourceID: .local, workspaceID: "w1")
        let remoteWorkspace = SourceWorkspaceID(sourceID: remote, workspaceID: "w1")

        XCTAssertNotEqual(localPane, remotePane, "pane ID だけで異なる source が衝突した")
        XCTAssertEqual(Set([localPane, remotePane]).count, 2)
        XCTAssertNotEqual(localWorkspace, remoteWorkspace, "workspace ID だけで異なる source が衝突した")
        XCTAssertEqual(Set([localWorkspace, remoteWorkspace]).count, 2)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "io.github.cryks.shepherd.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
