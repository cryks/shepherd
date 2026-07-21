// Pins the argv and stdin contract that RemoteTunnel passes to `/usr/bin/ssh`.
// status feeds a fixed resolver script to the remote `/bin/sh -s`, while the long-lived
// tunnel closes stdin to `/dev/null`. Covers non-interactive authentication, multiplexing
// disablement, session grammar, managed binary paths, and stream-local socket delimiting.

import XCTest
@testable import Shepherd

final class SSHCommandBuilderTests: XCTestCase {
    func testBuildsDefaultSessionStatusCommandWithFixedResolverInput() throws {
        let command = try SSHCommandBuilder.status(for: makeConfiguration())

        XCTAssertEqual(command.executablePath, "/usr/bin/ssh")
        XCTAssertEqual(
            command.arguments,
            discoveryOptions + [
                "--", "workbox", "/bin/sh", "-s", "--", "default",
            ]
        )
        XCTAssertEqual(command.environmentOverrides, ["LC_ALL": "C"])
        XCTAssertTrue(command.capturesStandardOutput)
        XCTAssertNotNil(command.standardInput)
        XCTAssertFalse(command.arguments.contains("herdr"))
        XCTAssertTrue(command.arguments.contains("-T"))
        XCTAssertFalse(command.arguments.contains("-n"))
        XCTAssertFalse(command.arguments.contains("StdinNull=yes"))
        XCTAssertFalse(command.arguments.contains("ClearAllForwardings=yes"))

        let script = try XCTUnwrap(command.standardInput).utf8String
        XCTAssertTrue(script.contains("command -v herdr"))
        XCTAssertTrue(script.contains(#"run_status "$home/.local/bin/herdr""#))
        XCTAssertTrue(script.contains("/opt/homebrew/bin/herdr"))
        XCTAssertTrue(script.contains("/home/linuxbrew/.linuxbrew/bin/herdr"))
        XCTAssertTrue(script.contains("/mise/installs/herdr/*/bin/herdr"))
        XCTAssertTrue(script.contains("/mise/installs/github-ogulcancelik-herdr/*/herdr"))
        XCTAssertTrue(script.contains(#"run_status "$home/.nix-profile/bin/herdr""#))
        XCTAssertTrue(script.contains("/etc/profiles/per-user/$user/bin/herdr"))
        XCTAssertTrue(script.contains("/nix/var/nix/profiles/default/bin/herdr"))
        XCTAssertTrue(script.contains("/run/current-system/sw/bin/herdr"))
        XCTAssertTrue(script.contains("/*/mise/shims/herdr"))
        XCTAssertTrue(script.contains("expected_protocol=\(Herdr.supportedProtocol)"))
        XCTAssertTrue(script.contains(#""$candidate" "--session=$session" status server --json"#))
        XCTAssertFalse(script.contains("curl"))
        XCTAssertFalse(script.contains("mkdir "))
        XCTAssertFalse(script.contains("chmod "))
        XCTAssertFalse(script.contains("mv "))
    }

    func testKeepsNamedSessionOutOfResolverScript() throws {
        let defaultCommand = try SSHCommandBuilder.status(for: makeConfiguration())
        let namedCommand = try SSHCommandBuilder.status(
            for: makeConfiguration(sessionName: "work.2_test-1")
        )

        XCTAssertEqual(
            Array(namedCommand.arguments.suffix(6)),
            [
                "--", "workbox", "/bin/sh", "-s", "--", "work.2_test-1",
            ]
        )
        XCTAssertEqual(namedCommand.standardInput, defaultCommand.standardInput)
        XCTAssertFalse(
            try XCTUnwrap(namedCommand.standardInput).utf8String.contains("work.2_test-1")
        )
    }

    func testPassesLeadingHyphenSessionAfterRemoteShellOptionTerminator() throws {
        let command = try SSHCommandBuilder.status(
            for: makeConfiguration(sessionName: "-work")
        )

        XCTAssertEqual(
            Array(command.arguments.suffix(6)),
            ["--", "workbox", "/bin/sh", "-s", "--", "-work"]
        )
    }

    func testBuildsOwnedStreamLocalForward() throws {
        let command = try SSHCommandBuilder.tunnel(
            for: makeConfiguration(sessionName: "agents"),
            localSocketPath: "/tmp/shepherd/private/herdr.sock",
            remoteSocketPath: "/home/me/.config/herdr/sessions/agents/herdr.sock"
        )

        XCTAssertEqual(command.executablePath, "/usr/bin/ssh")
        XCTAssertEqual(
            command.arguments,
            ["-N"] + tunnelConnectionOptions + [
                "-o", "ClearAllForwardings=no",
                "-o", "ExitOnForwardFailure=yes",
                "-o", "StreamLocalBindUnlink=yes",
                "-o", "StreamLocalBindMask=0177",
                "-L",
                "/tmp/shepherd/private/herdr.sock:/home/me/.config/herdr/sessions/agents/herdr.sock",
                "--", "workbox",
            ]
        )
        XCTAssertNil(command.standardInput)
        XCTAssertFalse(command.capturesStandardOutput)
        XCTAssertTrue(command.arguments.contains("-T"))
        XCTAssertTrue(command.arguments.contains("-n"))
        XCTAssertTrue(command.arguments.contains("ControlMaster=no"))
        XCTAssertTrue(command.arguments.contains("ControlPersist=no"))
        XCTAssertTrue(command.arguments.contains("ClearAllForwardings=no"))
    }

    func testCommandRunnerWritesResolverInputAndClosesIt() async throws {
        let command = RemoteProcessCommand(
            executablePath: "/bin/sh",
            arguments: ["-s"],
            standardInput: Data("printf 'stdin-ok\\n'\n".utf8),
            environmentOverrides: [:],
            capturesStandardOutput: true
        )

        let result = try await FoundationRemoteTunnelCommandRunner().run(
            command,
            timeout: .seconds(2)
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.standardOutput, Data("stdin-ok\n".utf8))
    }

    func testResolverFindsDotLocalBinaryOutsideNoninteractivePATH() async throws {
        let fixture = try makeResolverFixture(homeName: "managed home")
        defer { fixture.remove() }
        let managedBinary = fixture.home.appendingPathComponent(".local/bin/herdr")
        try writeFakeHerdr(at: managedBinary, protocolVersion: Herdr.supportedProtocol)

        let result = try await runResolver(fixture: fixture, sessionName: "default")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(
            result.standardOutput,
            Data(#"{"running":true,"socket":"/tmp/herdr.sock","session":null}"#.utf8)
                + Data("\n".utf8)
        )
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(log.contains("status client --json"))
        XCTAssertTrue(log.contains("status server --json"))
        XCTAssertFalse(log.contains("--session="))
    }

    func testResolverSkipsMiseShimAndUsesVersionedInstall() async throws {
        let fixture = try makeResolverFixture(homeName: "mise-home")
        defer { fixture.remove() }
        let shim = fixture.root.appendingPathComponent("mise/shims/herdr")
        let managedBinary = fixture.home.appendingPathComponent(
            ".local/share/mise/installs/herdr/0.7.5/bin/herdr"
        )
        try writeFakeHerdr(at: shim, protocolVersion: Herdr.supportedProtocol)
        try writeFakeHerdr(at: managedBinary, protocolVersion: Herdr.supportedProtocol)

        let result = try await runResolver(
            fixture: fixture,
            sessionName: "agents",
            additionalPATH: shim.deletingLastPathComponent()
        )

        XCTAssertEqual(result.status, 0)
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertFalse(log.contains(shim.path))
        XCTAssertTrue(log.contains(managedBinary.path))
        XCTAssertTrue(log.contains("--session=agents status server --json"))
    }

    func testResolverRejectsProtocolPrefixAndFallsBack() async throws {
        let fixture = try makeResolverFixture(homeName: "protocol-home")
        defer { fixture.remove() }
        let pathBinary = fixture.bin.appendingPathComponent("herdr")
        let managedBinary = fixture.home.appendingPathComponent(".local/bin/herdr")
        try writeFakeHerdr(
            at: pathBinary,
            protocolVersion: Herdr.supportedProtocol * 10
        )
        try writeFakeHerdr(at: managedBinary, protocolVersion: Herdr.supportedProtocol)

        let result = try await runResolver(fixture: fixture, sessionName: nil)

        XCTAssertEqual(result.status, 0)
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(log.contains("\(pathBinary.path) status client --json"))
        XCTAssertFalse(log.contains("\(pathBinary.path) status server --json"))
        XCTAssertTrue(log.contains("\(managedBinary.path) status server --json"))
    }

    func testResolverTreatsMetacharactersInHOMEAsPathData() async throws {
        let fixture = try makeResolverFixture(
            homeName: "home 'quoted';$(touch${IFS}${MARKER})"
        )
        defer { fixture.remove() }
        let managedBinary = fixture.home.appendingPathComponent(".local/bin/herdr")
        try writeFakeHerdr(at: managedBinary, protocolVersion: Herdr.supportedProtocol)

        let result = try await runResolver(fixture: fixture, sessionName: "-work")

        XCTAssertEqual(result.status, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.marker.path))
        let log = try String(contentsOf: fixture.log, encoding: .utf8)
        XCTAssertTrue(log.contains(managedBinary.path))
        XCTAssertTrue(log.contains("--session=-work status server --json"))
    }

    func testRejectsHerdrReservedAndNonASCIISessionNames() {
        for sessionName in [".", "..", "work/name", "作業"] {
            XCTAssertThrowsError(
                try SSHCommandBuilder.status(
                    for: makeConfiguration(sessionName: sessionName)
                ),
                "sessionName=\(sessionName)"
            ) { error in
                XCTAssertEqual(
                    error as? RemoteSourceValidationError,
                    .invalidSessionName(sessionName)
                )
            }
        }
    }

    func testRejectsAliasThatCouldBecomeAnOptionOrSecondArgument() {
        for alias in ["-F", "work box", "work\nbox"] {
            XCTAssertThrowsError(
                try SSHCommandBuilder.status(
                    for: makeConfiguration(sshAlias: alias)
                ),
                "sshAlias=\(alias)"
            )
        }
    }

    func testRejectsAmbiguousOrRelativeForwardPaths() {
        XCTAssertThrowsError(
            try SSHCommandBuilder.tunnel(
                for: makeConfiguration(),
                localSocketPath: "relative/herdr.sock",
                remoteSocketPath: "/home/me/.config/herdr/herdr.sock"
            )
        ) { error in
            XCTAssertEqual(
                error as? SSHCommandBuilderError,
                .invalidLocalSocketPath("relative/herdr.sock")
            )
        }

        XCTAssertThrowsError(
            try SSHCommandBuilder.tunnel(
                for: makeConfiguration(),
                localSocketPath: "/tmp/shepherd.sock",
                remoteSocketPath: "/home/me/config:copy/herdr.sock"
            )
        ) { error in
            XCTAssertEqual(
                error as? SSHCommandBuilderError,
                .invalidRemoteSocketPath("/home/me/config:copy/herdr.sock")
            )
        }
    }

    private func makeConfiguration(
        sshAlias: String = "workbox",
        sessionName: String? = nil
    ) -> RemoteSourceConfiguration {
        RemoteSourceConfiguration(
            id: .remote(uuid: UUID(uuidString: "305eb460-e4b8-4ea3-b8a3-1229de790c99")!),
            label: "Work",
            sshAlias: sshAlias,
            sessionName: sessionName
        )
    }

    private var discoveryOptions: [String] {
        ["-T"] + connectionPolicyOptions
    }

    private var tunnelConnectionOptions: [String] {
        [
            "-T",
            "-n",
        ] + connectionPolicyOptions + [
            "-o", "StdinNull=yes",
        ]
    }

    private var connectionPolicyOptions: [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ConnectTimeout=10",
            "-o", "ConnectionAttempts=1",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "ControlPersist=no",
            "-o", "ForkAfterAuthentication=no",
            "-o", "RemoteCommand=none",
            "-o", "RequestTTY=no",
        ]
    }
}

private extension SSHCommandBuilderTests {
    func makeResolverFixture(homeName: String) throws -> ResolverFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shepherd-resolver-\(UUID())", isDirectory: true)
        let home = root.appendingPathComponent(homeName, isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let log = root.appendingPathComponent("herdr.log")
        let marker = root.appendingPathComponent("injected")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: bin,
            withIntermediateDirectories: true
        )
        try writeExecutable(
            at: bin.appendingPathComponent("uname"),
            source: "#!/bin/sh\nprintf 'TestOS\\n'\n"
        )
        return ResolverFixture(root: root, home: home, bin: bin, log: log, marker: marker)
    }

    func writeFakeHerdr(at url: URL, protocolVersion: Int) throws {
        try writeExecutable(
            at: url,
            source: """
            #!/bin/sh
            printf '%s %s\\n' "$0" "$*" >> "$HERDR_TEST_LOG"
            if [ "$1" = status ] && [ "$2" = client ] && [ "$3" = --json ]; then
                printf '%s\\n' '{"version":"test","protocol":\(protocolVersion),"binary":"fake"}'
                exit 0
            fi
            case "$1" in
                --session=*) shift ;;
            esac
            if [ "$1" = status ] && [ "$2" = server ] && [ "$3" = --json ]; then
                printf '%s\\n' '{"running":true,"socket":"/tmp/herdr.sock","session":null}'
                exit 0
            fi
            exit 64
            """ + "\n"
        )
    }

    func writeExecutable(at url: URL, source: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    func runResolver(
        fixture: ResolverFixture,
        sessionName: String?,
        additionalPATH: URL? = nil
    ) async throws -> RemoteProcessResult {
        let sshCommand = try SSHCommandBuilder.status(
            for: makeConfiguration(sessionName: sessionName)
        )
        let session = try XCTUnwrap(sshCommand.arguments.last)
        let path = [additionalPATH?.path, fixture.bin.path]
            .compactMap { $0 }
            .joined(separator: ":")
        let localCommand = RemoteProcessCommand(
            executablePath: "/bin/sh",
            arguments: ["-s", "--", session],
            standardInput: sshCommand.standardInput,
            environmentOverrides: [
                "HOME": fixture.home.path,
                "USER": "shepherd-test-user",
                "PATH": path,
                "HERDR_TEST_LOG": fixture.log.path,
                "MARKER": fixture.marker.path,
            ],
            capturesStandardOutput: true
        )
        return try await FoundationRemoteTunnelCommandRunner().run(
            localCommand,
            timeout: .seconds(2)
        )
    }
}

private struct ResolverFixture {
    let root: URL
    let home: URL
    let bin: URL
    let log: URL
    let marker: URL

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private extension Data {
    var utf8String: String {
        String(decoding: self, as: UTF8.self)
    }
}
