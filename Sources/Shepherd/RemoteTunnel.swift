// リモート Herdr の JSON API socket を、Shepherd が所有する OpenSSH process と
// ローカル Unix socket へ写す層。接続先の永続設定は RemoteSourceConfiguration が
// 所有し、このファイルは次の実行時資源を所有する。
//
// - SSH 経由の `herdr status server --json` による remote socket path の発見
// - 発見した path の UserDefaults cache。ready 前の接続失敗時だけ破棄する
// - 所有者だけが入れる一時 directory と、その中の転送 socket
// - 1 接続先につき 1 本の `ssh -N -L local_socket:remote_socket` process
// - process 終了後の再接続と指数 backoff
//
// Herdr socket API は agent.focus や server.stop も実行できる full-control API なので、
// TCP port へ公開しない。ローカル socket path はユーザー入力を受け取らず、mkdtemp が
// mode 0700 で作った directory の下だけを使う。SSH は multiplex と background 化を
// command line で無効にし、Shepherd が起動した process と forward の寿命を一致させる。

import Darwin
import Foundation

// MARK: - EndpointMonitor が使う公開境界

/// リモート接続 1 件の tunnel を開始・停止し、状態遷移を MainActor で通知する境界。
/// `stop()` は監督 task を cancel し、その task の cancellation handler が所有する SSH
/// process を終了する。呼び出し直後に `.stopped` を公開するが、process の reap と stale
/// socket の除去は背後で完了するため、同じ instance を直ちに `start()` した場合は前の
/// task の終了後に再開する。
@MainActor
protocol RemoteTunnelManaging: AnyObject {
    var configuration: RemoteSourceConfiguration { get }
    var localSocketPath: String { get }
    var state: RemoteTunnelState { get }
    var onStateChange: ((RemoteTunnelState) -> Void)? { get set }

    func start()
    func stop()
}

/// SSH tunnel と remote Herdr 発見処理を合わせた接続状態。
/// `.ready` は local listener の生成だけでなく、その listener 越しの ping 応答まで
/// 完了した状態を表す。Herdr protocol の対応可否は ping を読む上位の monitor が判定する。
enum RemoteTunnelState: Equatable, Sendable {
    case stopped
    case discovering(attempt: Int)
    case connecting(attempt: Int)
    case ready(localSocketPath: String)
    case retrying(failure: RemoteTunnelFailure, delay: Duration)
    case failed(failure: RemoteTunnelFailure)
}

/// 設定 UI とログが、失敗した段階・原因・終了 status を構造化して読めるエラー。
/// `diagnostic` は SSH stderr または decoder/probe error を制御文字除去後 4 KiB に制限した
/// 文字列で、秘密鍵や socket payload は含めない。
struct RemoteTunnelFailure: Error, Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case discovery
        case forwarding
    }

    enum Kind: String, Equatable, Sendable {
        case sshLaunch
        case authentication
        case hostKey
        case unreachable
        case remoteHerdrMissing
        case remoteHerdrStopped
        case malformedStatus
        case invalidRemoteSocket
        case forwardingRejected
        case timeout
        case unexpectedExit
    }

    let phase: Phase
    let kind: Kind
    let exitStatus: Int32?
    let diagnostic: String

    /// 不正 remote path と、private directory 内を通常 file が占有した状態では process を
    /// 起動しない。それ以外はネットワーク、認証 agent、Herdr process の外部変化で
    /// 復旧できるため再試行する。
    var isRetryable: Bool {
        kind != .invalidRemoteSocket
    }
}

/// remote Herdr socket path を接続先設定ごとに保存する境界。
/// path は認証情報ではなく SSH 転送先だが、設定変更後の誤接続を避けるため load 時に
/// stable ID、SSH alias、session の 3 項目が一致する entry だけを返す。
struct RemoteSocketPathCache: Sendable {
    let load: @Sendable (RemoteSourceConfiguration) -> String?
    let store: @Sendable (String?, RemoteSourceConfiguration) -> Void

    static let live = userDefaults(.standard)

    static let disabled = RemoteSocketPathCache(
        load: { _ in nil },
        store: { _, _ in }
    )

    /// app 再起動後も使う UserDefaults 実装。複数 source の read-modify-write は lock 内で
    /// 行い、別 source の entry を同時更新で失わない。
    static func userDefaults(_ defaults: UserDefaults) -> RemoteSocketPathCache {
        let storage = UserDefaultsRemoteSocketPathStorage(defaults: defaults)
        return RemoteSocketPathCache(
            load: { configuration in storage.load(for: configuration) },
            store: { path, configuration in storage.store(path, for: configuration) }
        )
    }

    static let userDefaultsKey = "RemoteHerdrSocketPaths"
}

private struct RemoteSocketPathCacheEntry: Codable {
    let sshAlias: String
    let sessionName: String?
    let socketPath: String

    func matches(_ configuration: RemoteSourceConfiguration) -> Bool {
        sshAlias == configuration.sshAlias
            && sessionName == configuration.normalizedSessionName
    }
}

private final class UserDefaultsRemoteSocketPathStorage: @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func load(for configuration: RemoteSourceConfiguration) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries()[configuration.id.rawValue],
              entry.matches(configuration) else {
            return nil
        }
        return entry.socketPath
    }

    func store(_ path: String?, for configuration: RemoteSourceConfiguration) {
        lock.lock()
        defer { lock.unlock() }
        var values = entries()
        if let path {
            values[configuration.id.rawValue] = RemoteSocketPathCacheEntry(
                sshAlias: configuration.sshAlias,
                sessionName: configuration.normalizedSessionName,
                socketPath: path
            )
        } else {
            values.removeValue(forKey: configuration.id.rawValue)
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: RemoteSocketPathCache.userDefaultsKey)
    }

    private func entries() -> [String: RemoteSocketPathCacheEntry] {
        guard let data = defaults.data(forKey: RemoteSocketPathCache.userDefaultsKey),
              let values = try? JSONDecoder().decode(
                [String: RemoteSocketPathCacheEntry].self,
                from: data
              ) else {
            return [:]
        }
        return values
    }
}

/// リモート設定を検証し、private socket workspace と監督 task を所有する本番実装。
/// instance は RemoteSourceConfiguration の 1 件に対応し、設定変更時は新しい instance と
/// 入れ替える。これにより旧 SSH process と新設定の callback が同じ状態へ混ざらない。
@MainActor
final class RemoteTunnelManager: RemoteTunnelManaging {
    let configuration: RemoteSourceConfiguration
    let localSocketPath: String
    private(set) var state: RemoteTunnelState = .stopped
    var onStateChange: ((RemoteTunnelState) -> Void)?

    private let runtimeDirectoryPath: String?
    private let commandRunner: any RemoteTunnelCommandRunning
    private let probe: RemoteTunnelProbe
    private let fileSystem: RemoteTunnelFileSystem
    private let schedule: RemoteTunnelSchedule
    private let remoteSocketPathCache: RemoteSocketPathCache

    private var supervisionTask: Task<Void, Never>?
    private var wantsRunning = false
    private var generation: UInt64 = 0

    /// `/usr/bin/ssh` と POSIX Unix socket probe を使う production initializer。
    /// 設定 validation または private runtime directory の作成に失敗した場合は、SSH process を
    /// 起動する前に error を投げる。
    init(configuration: RemoteSourceConfiguration) throws {
        let configuration = try configuration.validated()
        let workspace = try PrivateTunnelSocketWorkspace.create()

        self.configuration = configuration
        localSocketPath = workspace.socketPath
        runtimeDirectoryPath = workspace.directoryPath
        commandRunner = FoundationRemoteTunnelCommandRunner()
        probe = .live
        fileSystem = .live
        schedule = .live
        remoteSocketPathCache = .live
    }

    /// Process・時間・filesystem・ping を差し替えるテスト境界。
    /// localSocketPath は production と同じ検査を command builder で受けるが、この initializer は
    /// test が用意した directory を所有しないため削除しない。
    init(
        configuration: RemoteSourceConfiguration,
        localSocketPath: String,
        commandRunner: any RemoteTunnelCommandRunning,
        probe: RemoteTunnelProbe,
        fileSystem: RemoteTunnelFileSystem,
        schedule: RemoteTunnelSchedule,
        remoteSocketPathCache: RemoteSocketPathCache = .disabled
    ) throws {
        self.configuration = try configuration.validated()
        self.localSocketPath = localSocketPath
        runtimeDirectoryPath = nil
        self.commandRunner = commandRunner
        self.probe = probe
        self.fileSystem = fileSystem
        self.schedule = schedule
        self.remoteSocketPathCache = remoteSocketPathCache
    }

    func start() {
        guard configuration.isVisible, configuration.isEnabled else { return }
        wantsRunning = true
        startSupervisionIfNeeded()
    }

    func stop() {
        wantsRunning = false
        supervisionTask?.cancel()
        fileSystem.removeSocket(localSocketPath)
        transition(to: .stopped)
    }

    private func startSupervisionIfNeeded() {
        guard wantsRunning, supervisionTask == nil else { return }

        generation &+= 1
        let generation = generation
        let engine = RemoteTunnelEngine(
            configuration: configuration,
            localSocketPath: localSocketPath,
            commandRunner: commandRunner,
            probe: probe,
            fileSystem: fileSystem,
            schedule: schedule,
            remoteSocketPathCache: remoteSocketPathCache
        )

        supervisionTask = Task { [weak self] in
            await engine.run { [weak self] newState in
                await self?.receive(newState, generation: generation)
            }
            self?.supervisionDidFinish(generation: generation)
        }
    }

    private func receive(_ newState: RemoteTunnelState, generation: UInt64) {
        guard self.generation == generation, wantsRunning else { return }
        transition(to: newState)
    }

    private func supervisionDidFinish(generation: UInt64) {
        guard self.generation == generation else { return }
        supervisionTask = nil
        fileSystem.removeSocket(localSocketPath)

        if case .failed = state {
            wantsRunning = false
            return
        }
        if wantsRunning {
            startSupervisionIfNeeded()
        } else {
            transition(to: .stopped)
        }
    }

    private func transition(to newState: RemoteTunnelState) {
        guard state != newState else { return }
        state = newState
        onStateChange?(newState)
    }

    deinit {
        supervisionTask?.cancel()
        fileSystem.removeSocket(localSocketPath)
        if let runtimeDirectoryPath {
            _ = Darwin.rmdir(runtimeDirectoryPath)
        }
    }
}

// MARK: - SSH argv

/// Foundation.Process へ渡す executable・argv・stdin・環境差分。
/// `standardInput` は remote shell へ固定 script を渡す短命の discovery command だけが
/// 持ち、それ以外は nil のまま `/dev/null` を使う。`environmentOverrides` は親 process の
/// 環境へ上書きし、PATH や SSH_AUTH_SOCK を落とさない。
struct RemoteProcessCommand: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
    let standardInput: Data?
    let environmentOverrides: [String: String]
    let capturesStandardOutput: Bool
}

enum SSHCommandBuilderError: Error, Equatable {
    case invalidLocalSocketPath(String)
    case invalidRemoteSocketPath(String)
}

/// local shell を介さず `/usr/bin/ssh` の argv を組み立てる純粋関数群。
/// OpenSSH は remote command の argv 境界を保存せず接続先の login shell へ渡すため、
/// 動的な command token は RemoteSourceConfiguration が Herdr の ASCII grammar で検証した
/// session 名だけにする。binary 候補は remote から文字列として取り出さず、stdin で
/// 渡した固定 script 内で引用符付きのまま実行する。
enum SSHCommandBuilder {
    private static let executablePath = "/usr/bin/ssh"

    /// remote Herdr server の絶対 socket path を取得する一発 command。
    static func status(
        for configuration: RemoteSourceConfiguration
    ) throws -> RemoteProcessCommand {
        let configuration = try configuration.validated()
        let sessionName = configuration.normalizedSessionName ?? "default"
        return RemoteProcessCommand(
            executablePath: executablePath,
            arguments: discoveryOptions + [
                "--", configuration.sshAlias, "/bin/sh", "-s", "--", sessionName,
            ],
            standardInput: Data(remoteHerdrStatusScript.utf8),
            environmentOverrides: ["LC_ALL": "C"],
            capturesStandardOutput: true
        )
    }

    /// 発見済み remote socket を private local socket へ forward する常駐 command。
    static func tunnel(
        for configuration: RemoteSourceConfiguration,
        localSocketPath: String,
        remoteSocketPath: String
    ) throws -> RemoteProcessCommand {
        let configuration = try configuration.validated()
        guard isValidForwardSocketPath(localSocketPath) else {
            throw SSHCommandBuilderError.invalidLocalSocketPath(localSocketPath)
        }
        guard isValidForwardSocketPath(remoteSocketPath) else {
            throw SSHCommandBuilderError.invalidRemoteSocketPath(remoteSocketPath)
        }

        return RemoteProcessCommand(
            executablePath: executablePath,
            arguments: tunnelOptions + [
                "-L", forwardSpecification(
                    localSocketPath: localSocketPath,
                    remoteSocketPath: remoteSocketPath
                ),
                "--", configuration.sshAlias,
            ],
            standardInput: nil,
            environmentOverrides: ["LC_ALL": "C"],
            capturesStandardOutput: false
        )
    }

    /// GUI から prompt を受けられないことと、process の寿命を supervisor が所有することを
    /// command line で固定する。ProxyJump、IdentityFile、IdentityAgent などの接続情報は
    /// OpenSSH config から読む。
    private static let connectionPolicyOptions = [
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

    /// resolver script を SSH stdin へ渡すため、`-n` と `StdinNull=yes` は付けない。
    private static let discoveryOptions = ["-T"] + connectionPolicyOptions

    /// `ClearAllForwardings=no` は command line の `-L` を有効に保つ。
    /// app 専用 directory の stale socket だけを unlink し、socket mode も所有者へ限定する。
    private static let tunnelOptions = [
        "-N",
        "-T",
        "-n",
    ] + connectionPolicyOptions + [
        "-o", "StdinNull=yes",
        "-o", "ClearAllForwardings=no",
        "-o", "ExitOnForwardFailure=yes",
        "-o", "StreamLocalBindUnlink=yes",
        "-o", "StreamLocalBindMask=0177",
    ]

    private static func forwardSpecification(
        localSocketPath: String,
        remoteSocketPath: String
    ) -> String {
        "\(localSocketPath):\(remoteSocketPath)"
    }

    /// Herdr 0.7.4 の remote candidate を含む既知の managed install を読み取り専用で探す。
    /// `command -v` の結果と HOME/USER から作った path はすべて `"$candidate"` で
    /// 実行し、remote の値を shell source として再解釈しない。mise shim は非対話
    /// shell で tool version を解決できない場合があるため除外し、install 実体を探す。
    /// CLI は完全一致の version ではなく Shepherd が読める protocol で選ぶ。server 側の
    /// protocol 判定は tunnel 後の ping が所有し、この script は install/update を行わない。
    private static let remoteHerdrStatusScript = """
    set -u
    session=$1
    home=${HOME:-}
    user=${USER:-}
    expected_protocol=\(Herdr.supportedProtocol)
    protocol_field=\"\\\"protocol\\\":$expected_protocol\"

    run_status() {
        candidate=$1
        [ -n "$candidate" ] && [ -x "$candidate" ] || return 1

        client_status=$("$candidate" status client --json 2>/dev/null) || return 1
        # JSON number の直後を comma または object 終端に限定し、16 を 160 と誤認しない。
        case "$client_status" in
            *"$protocol_field,"*|*"$protocol_field}"*) ;;
            *) return 1 ;;
        esac

        # default namespace は named session ではないため、Herdr へ --session を渡さない。
        if [ "$session" = default ]; then
            "$candidate" status server --json
        else
            "$candidate" "--session=$session" status server --json
        fi
    }

    path_candidate=$(command -v herdr 2>/dev/null || :)
    case "$path_candidate" in
        /*/mise/shims/herdr) ;;
        /*) run_status "$path_candidate" && exit 0 ;;
    esac

    if [ -n "$home" ]; then
        run_status "$home/.local/bin/herdr" && exit 0
    fi

    case "$(uname -s 2>/dev/null || :)" in
        Darwin)
            run_status /opt/homebrew/bin/herdr && exit 0
            run_status /usr/local/bin/herdr && exit 0
            ;;
        Linux)
            run_status /home/linuxbrew/.linuxbrew/bin/herdr && exit 0
            ;;
    esac

    if [ -n "$home" ]; then
        for candidate in \\
            "$home"/.local/share/mise/installs/herdr/*/bin/herdr \\
            "$home"/.local/share/mise/installs/github-ogulcancelik-herdr/*/herdr
        do
            run_status "$candidate" && exit 0
        done
        run_status "$home/.nix-profile/bin/herdr" && exit 0
    fi

    if [ -n "$user" ]; then
        run_status "/etc/profiles/per-user/$user/bin/herdr" && exit 0
    fi
    run_status /nix/var/nix/profiles/default/bin/herdr && exit 0
    run_status /run/current-system/sw/bin/herdr && exit 0

    printf '%s\\n' 'no compatible herdr executable found in known remote locations' >&2
    exit 127
    """

    /// OpenSSH の stream-local `local:remote` grammar では colon が区切り文字になる。
    /// 絶対 path 以外と制御文字を拒否し、argv へ曖昧な forwarding 指定を作らない。
    private static func isValidForwardSocketPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains(":") else { return false }
        return path.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
        }
    }
}

// MARK: - Private socket workspace

enum PrivateTunnelSocketWorkspaceError: Error, Equatable {
    case createDirectory(Int32)
    case socketPathTooLong
}

/// manager 1 instance 専用の runtime directory と local listener path。
/// directory は mkdtemp の mode 0700 なので、OpenSSH の StreamLocalBindMask 設定にかかわらず
/// ほかの user は listener へ到達できない。random path は別 Shepherd process との衝突も避ける。
private struct PrivateTunnelSocketWorkspace {
    let directoryPath: String
    let socketPath: String

    static func create() throws -> PrivateTunnelSocketWorkspace {
        let preferredBase = FileManager.default.temporaryDirectory.path
        if let workspace = try create(under: preferredBase, rejectLongPath: true) {
            return workspace
        }
        // TMPDIR が長すぎる環境だけ、短い /tmp の private random directory へ退避する。
        if let workspace = try create(under: "/tmp", rejectLongPath: false) {
            return workspace
        }
        throw PrivateTunnelSocketWorkspaceError.socketPathTooLong
    }

    private static func create(
        under basePath: String,
        rejectLongPath: Bool
    ) throws -> PrivateTunnelSocketWorkspace? {
        var template = Array("\(basePath)/shepherd-tunnel.XXXXXX".utf8CString)
        let result = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress)
        }
        guard let result else {
            throw PrivateTunnelSocketWorkspaceError.createDirectory(errno)
        }

        let directoryPath = String(cString: result)
        _ = chmod(directoryPath, S_IRWXU)
        let socketPath = directoryPath + "/herdr.sock"
        let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard socketPath.utf8.count < sunPathCapacity else {
            _ = Darwin.rmdir(directoryPath)
            if rejectLongPath { return nil }
            throw PrivateTunnelSocketWorkspaceError.socketPathTooLong
        }
        return PrivateTunnelSocketWorkspace(
            directoryPath: directoryPath,
            socketPath: socketPath
        )
    }
}

enum RemoteTunnelFileSystemError: Error, Equatable {
    case occupiedByNonSocket(String)
    case unlinkFailed(String, Int32)
}

/// Unix socket file の存在判定と除去を監督 loop から分離するテスト境界。
/// live 実装は symlink や通常 file を unlink せず、app 所有 directory の想定が崩れた場合に
/// SSH 起動を止める。
struct RemoteTunnelFileSystem: Sendable {
    var prepareSocket: @Sendable (String) throws -> Void
    var socketExists: @Sendable (String) -> Bool
    var removeSocket: @Sendable (String) -> Void

    static let live = RemoteTunnelFileSystem(
        prepareSocket: { path in
            var status = stat()
            guard lstat(path, &status) == 0 else {
                if errno == ENOENT { return }
                throw RemoteTunnelFileSystemError.unlinkFailed(path, errno)
            }
            guard status.st_mode & S_IFMT == S_IFSOCK else {
                throw RemoteTunnelFileSystemError.occupiedByNonSocket(path)
            }
            guard unlink(path) == 0 else {
                throw RemoteTunnelFileSystemError.unlinkFailed(path, errno)
            }
        },
        socketExists: { path in
            var status = stat()
            return lstat(path, &status) == 0 && status.st_mode & S_IFMT == S_IFSOCK
        },
        removeSocket: { path in
            var status = stat()
            guard lstat(path, &status) == 0, status.st_mode & S_IFMT == S_IFSOCK else {
                return
            }
            _ = unlink(path)
        }
    )
}

// MARK: - Status discovery and ping

/// Herdr 0.7.4 の `status server --json` から tunnel に必要な field だけを読む。
/// version/protocol の互換性は上位 monitor が forwarded ping から判定する。
private struct RemoteHerdrServerStatus: Decodable {
    let running: Bool
    let socket: String?
    let session: String?
}

enum RemoteHerdrStatusParserError: Error, Equatable {
    case noStatusJSON
}

enum RemoteHerdrStatusParser {
    /// 非対話 shell の banner が stdout に混ざる host を許容し、末尾から最初に decode できる
    /// 1 行を status とする。Herdr CLI は JSON を 1 行で出す契約なので複数行 JSON は扱わない。
    static func parse(_ data: Data) throws -> (running: Bool, socket: String?, session: String?) {
        let decoder = JSONDecoder()
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
            if let status = try? decoder.decode(RemoteHerdrServerStatus.self, from: Data(line)) {
                return (status.running, status.socket, status.session)
            }
        }
        throw RemoteHerdrStatusParserError.noStatusJSON
    }
}

/// forwarded socket が listener 作成だけでなく Herdr API まで到達することを検査する依存。
struct RemoteTunnelProbe: Sendable {
    var ping: @Sendable (String) async throws -> Void

    static let live = RemoteTunnelProbe { socketPath in
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    try pingHerdrSocket(path: socketPath)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

private enum RemoteTunnelProbeError: Error {
    case socket(Int32)
    case setSocketOption(Int32)
    case pathTooLong
    case connect(Int32)
    case write(Int32)
    case read(Int32)
    case responseTooLarge
    case connectionClosed
    case invalidResponse
}

private struct TunnelProbeResponse: Decodable {
    struct Result: Decodable {
        let version: String
        let protocolVersion: Int

        enum CodingKeys: String, CodingKey {
            case version
            case protocolVersion = "protocol"
        }
    }

    struct RPCError: Decodable {
        let code: String
        let message: String
    }

    let result: Result?
    let error: RPCError?
}

/// 2 秒の read/write timeout と 64 KiB 上限を持つ一発 ping。
/// protocol mismatch でも tunnel 自体は成立しているため、result の protocol 値は比較しない。
private func pingHerdrSocket(path: String) throws {
    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw RemoteTunnelProbeError.socket(errno) }
    defer { Darwin.close(fileDescriptor) }

    // probe と SSH tunnel の終了が競合して peer が先に閉じても、write の EPIPE を
    // process-wide SIGPIPE にせず、この接続試行の error として supervisor へ返す。
    var noSigPipe: Int32 = 1
    let noSigPipeResult = withUnsafePointer(to: &noSigPipe) { pointer in
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            pointer,
            socklen_t(MemoryLayout<Int32>.size)
        )
    }
    guard noSigPipeResult == 0 else {
        throw RemoteTunnelProbeError.setSocketOption(errno)
    }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) { pointer in
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            pointer,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }
    _ = withUnsafePointer(to: &timeout) { pointer in
        setsockopt(
            fileDescriptor,
            SOL_SOCKET,
            SO_SNDTIMEO,
            pointer,
            socklen_t(MemoryLayout<timeval>.size)
        )
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
        throw RemoteTunnelProbeError.pathTooLong
    }
    withUnsafeMutableBytes(of: &address.sun_path) { destination in
        destination.copyBytes(from: pathBytes)
    }

    let connectionResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(
                fileDescriptor,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            )
        }
    }
    guard connectionResult == 0 else { throw RemoteTunnelProbeError.connect(errno) }

    let request = Data(
        (#"{"id":"shepherd:tunnel-probe","method":"ping","params":{}}"# + "\n").utf8
    )
    try request.withUnsafeBytes { bytes in
        guard let baseAddress = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(
                fileDescriptor,
                baseAddress.advanced(by: offset),
                bytes.count - offset
            )
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RemoteTunnelProbeError.write(errno) }
            offset += count
        }
    }

    var response = Data()
    while response.firstIndex(of: 0x0A) == nil {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw RemoteTunnelProbeError.read(errno) }
        guard count > 0 else { throw RemoteTunnelProbeError.connectionClosed }
        response.append(contentsOf: buffer[..<count])
        guard response.count <= 65_536 else { throw RemoteTunnelProbeError.responseTooLarge }
    }

    guard let newline = response.firstIndex(of: 0x0A) else {
        throw RemoteTunnelProbeError.invalidResponse
    }
    let envelope = try JSONDecoder().decode(
        TunnelProbeResponse.self,
        from: response[..<newline]
    )
    guard envelope.error == nil, envelope.result != nil else {
        throw RemoteTunnelProbeError.invalidResponse
    }
}

// MARK: - Process abstraction

enum RemoteProcessExitReason: Equatable, Sendable {
    case exit
    case signal
}

struct RemoteProcessResult: Equatable, Sendable {
    let status: Int32
    let reason: RemoteProcessExitReason
    let standardOutput: Data
    let standardError: Data
}

protocol RemoteTunnelRunningProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func wait() async -> RemoteProcessResult
    func terminate()
}

protocol RemoteTunnelCommandRunning: Sendable {
    func run(
        _ command: RemoteProcessCommand,
        timeout: Duration
    ) async throws -> RemoteProcessResult

    func start(_ command: RemoteProcessCommand) throws -> any RemoteTunnelRunningProcess
}

enum RemoteTunnelCommandRunnerError: Error, Equatable {
    case timeout
}

/// Foundation.Process を直接起動し、shell 展開を挟まない command runner。
struct FoundationRemoteTunnelCommandRunner: RemoteTunnelCommandRunning {
    func run(
        _ command: RemoteProcessCommand,
        timeout: Duration
    ) async throws -> RemoteProcessResult {
        let child = try start(command)
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: CommandCompletion.self) { group in
                group.addTask {
                    .exited(await child.wait())
                }
                group.addTask {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                }

                guard let completion = try await group.next() else {
                    throw CancellationError()
                }
                switch completion {
                case .exited(let result):
                    group.cancelAll()
                    try Task.checkCancellation()
                    return result
                case .timedOut:
                    child.terminate()
                    group.cancelAll()
                    throw RemoteTunnelCommandRunnerError.timeout
                }
            }
        } onCancel: {
            child.terminate()
        }
    }

    func start(_ command: RemoteProcessCommand) throws -> any RemoteTunnelRunningProcess {
        try FoundationRemoteTunnelProcess(command: command)
    }

    private enum CommandCompletion: Sendable {
        case exited(RemoteProcessResult)
        case timedOut
    }
}

/// Pipe を読み続けて child の出力量と無関係に process を進めつつ、末尾 32 KiB だけを残す。
/// `Pipe` の親側 write handle は launch 直後に閉じ、child 終了時に reader が EOF へ到達する。
private final class BoundedPipeCapture: @unchecked Sendable {
    let pipe = Pipe()

    private let limit: Int
    private let lock = NSLock()
    private let completion = DispatchGroup()
    private var buffer = Data()

    init(limit: Int = 32 * 1024) {
        self.limit = limit
    }

    func startReading() {
        completion.enter()
        let handle = pipe.fileHandleForReading
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { completion.leave() }
            while true {
                do {
                    guard let data = try handle.read(upToCount: 4096), !data.isEmpty else { return }
                    append(data)
                } catch {
                    return
                }
            }
        }
    }

    func closeParentWriteHandle() {
        try? pipe.fileHandleForWriting.close()
    }

    func finish() -> Data {
        completion.wait()
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    private func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }

        if data.count >= limit {
            buffer = Data(data.suffix(limit))
            return
        }
        let overflow = buffer.count + data.count - limit
        if overflow > 0 {
            buffer.removeFirst(overflow)
        }
        buffer.append(data)
    }
}

/// Process の終了を複数 waiter へ 1 回だけ配る lock-backed latch。
private final class RemoteProcessResultLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var result: RemoteProcessResult?
    private var waiters: [CheckedContinuation<RemoteProcessResult, Never>] = []

    func wait() async -> RemoteProcessResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve(_ result: RemoteProcessResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()

        for waiter in waiters {
            waiter.resume(returning: result)
        }
    }
}

/// Process.terminationHandler を async wait へ橋渡しし、cancel 時は SIGTERM、1 秒後も
/// 同じ child が生きている場合だけ SIGKILL を送る。終了済み PID の再利用を誤 kill しないよう、
/// Process.isRunning と元の processIdentifier を両方検査する。
private final class FoundationRemoteTunnelProcess: RemoteTunnelRunningProcess, @unchecked Sendable {
    private let process = Process()
    private let outputCapture: BoundedPipeCapture?
    private let errorCapture = BoundedPipeCapture()
    private let resultLatch = RemoteProcessResultLatch()
    private let lock = NSLock()

    init(command: RemoteProcessCommand) throws {
        process.executableURL = URL(fileURLWithPath: command.executablePath)
        process.arguments = command.arguments
        let inputPipe: Pipe?
        if command.standardInput != nil {
            let pipe = Pipe()
            // remote command が stdin を読む前に終了しても、EPIPE を app 全体の
            // SIGPIPE にせず discovery process の失敗として扱う。
            _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
            inputPipe = pipe
            process.standardInput = pipe
        } else {
            inputPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        if command.capturesStandardOutput {
            let capture = BoundedPipeCapture()
            outputCapture = capture
            process.standardOutput = capture.pipe
        } else {
            outputCapture = nil
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = errorCapture.pipe

        var environment = ProcessInfo.processInfo.environment
        environment.merge(command.environmentOverrides) { _, override in override }
        process.environment = environment

        process.terminationHandler = { [weak self] process in
            self?.didTerminate(process)
        }

        outputCapture?.startReading()
        errorCapture.startReading()
        do {
            try process.run()
        } catch {
            try? inputPipe?.fileHandleForReading.close()
            try? inputPipe?.fileHandleForWriting.close()
            outputCapture?.closeParentWriteHandle()
            errorCapture.closeParentWriteHandle()
            throw error
        }
        if let input = command.standardInput, let inputPipe {
            // discovery script は pipe capacity を超えない固定サイズに限定し、
            // launch 後に親側の read end を閉じてから書き込む。write end の close が
            // remote `/bin/sh -s` へ EOF を渡す。
            try? inputPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.write(contentsOf: input)
            try? inputPipe.fileHandleForWriting.close()
        }
        outputCapture?.closeParentWriteHandle()
        errorCapture.closeParentWriteHandle()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process.isRunning
    }

    func wait() async -> RemoteProcessResult {
        await resultLatch.wait()
    }

    func terminate() {
        let processIdentifier: Int32?
        lock.lock()
        if process.isRunning {
            processIdentifier = process.processIdentifier
        } else {
            processIdentifier = nil
        }
        lock.unlock()

        guard let processIdentifier else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.forceTerminateIfStillRunning(processIdentifier: processIdentifier)
        }
    }

    private func forceTerminateIfStillRunning(processIdentifier: Int32) {
        lock.lock()
        let shouldKill = process.isRunning && process.processIdentifier == processIdentifier
        lock.unlock()
        if shouldKill {
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func didTerminate(_ process: Process) {
        let output = outputCapture?.finish() ?? Data()
        let error = errorCapture.finish()
        let reason: RemoteProcessExitReason = process.terminationReason == .exit ? .exit : .signal
        resultLatch.resolve(
            RemoteProcessResult(
                status: process.terminationStatus,
                reason: reason,
                standardOutput: output,
                standardError: error
            )
        )
        process.terminationHandler = nil
    }
}

// MARK: - Supervision loop

/// 実時間を短縮するテストが sleep と timeout を差し替えるための schedule。
struct RemoteTunnelSchedule: Sendable {
    var discoveryTimeout: Duration
    var readinessTimeout: Duration
    var readinessPollInterval: Duration
    var retryDelay: @Sendable (_ failedAttempt: Int) -> Duration
    var sleep: @Sendable (Duration) async throws -> Void

    static let live = RemoteTunnelSchedule(
        discoveryTimeout: .seconds(15),
        readinessTimeout: .seconds(15),
        readinessPollInterval: .milliseconds(100),
        retryDelay: { failedAttempt in
            let delays = [1, 2, 4, 8, 16, 30]
            return .seconds(delays[min(max(failedAttempt - 1, 0), delays.count - 1)])
        },
        sleep: { duration in
            try await Task.sleep(for: duration)
        }
    )
}

/// MainActor の manager を保持せずに、Shepherd 専用 SSH process を監督する Sendable value。
/// persistent cache は run 開始時に読み、discovery 成功時に保存する。ready 前の失敗だけ
/// entry を削除し、ready 後の回線切断、監視 OFF、app 終了では次回接続へ残す。
private struct RemoteTunnelEngine: Sendable {
    let configuration: RemoteSourceConfiguration
    let localSocketPath: String
    let commandRunner: any RemoteTunnelCommandRunning
    let probe: RemoteTunnelProbe
    let fileSystem: RemoteTunnelFileSystem
    let schedule: RemoteTunnelSchedule
    let remoteSocketPathCache: RemoteSocketPathCache

    func run(
        emit: @Sendable (RemoteTunnelState) async -> Void
    ) async {
        var attempt = 1
        var cachedRemoteSocketPath = remoteSocketPathCache.load(configuration)
        while !Task.isCancelled {
            await emit(.discovering(attempt: attempt))
            do {
                try await runAttempt(
                    attempt: attempt,
                    cachedRemoteSocketPath: &cachedRemoteSocketPath,
                    emit: emit
                )
                // `-N` の SSH process は停止または失敗まで戻らない。
                return
            } catch is CancellationError {
                break
            } catch let readyExit as ReadyTunnelExit {
                // 一度 ping まで成功した接続は過去の連続失敗を解消している。次回は 1 秒から
                // 再開し、長時間生きた tunnel の切断を以前の max backoff へ引きずらない。
                attempt = 1
                let delay = schedule.retryDelay(attempt)
                await emit(.retrying(failure: readyExit.failure, delay: delay))
                do {
                    try await schedule.sleep(delay)
                } catch {
                    break
                }
            } catch let failure as RemoteTunnelFailure {
                guard failure.isRetryable else {
                    await emit(.failed(failure: failure))
                    break
                }
                let delay = schedule.retryDelay(attempt)
                await emit(.retrying(failure: failure, delay: delay))
                do {
                    try await schedule.sleep(delay)
                } catch {
                    break
                }
                attempt += 1
            } catch {
                let failure = RemoteTunnelFailure(
                    phase: .discovery,
                    kind: .sshLaunch,
                    exitStatus: nil,
                    diagnostic: boundedDiagnostic(String(describing: error))
                )
                let delay = schedule.retryDelay(attempt)
                await emit(.retrying(failure: failure, delay: delay))
                do {
                    try await schedule.sleep(delay)
                } catch {
                    break
                }
                attempt += 1
            }
        }
        fileSystem.removeSocket(localSocketPath)
    }

    private func runAttempt(
        attempt: Int,
        cachedRemoteSocketPath: inout String?,
        emit: @Sendable (RemoteTunnelState) async -> Void
    ) async throws {
        let remoteSocketPath: String
        if let cachedRemoteSocketPath {
            remoteSocketPath = cachedRemoteSocketPath
        } else {
            remoteSocketPath = try await discoverRemoteSocket()
            cachedRemoteSocketPath = remoteSocketPath
            remoteSocketPathCache.store(remoteSocketPath, configuration)
        }

        var becameReady = false
        do {
            defer { fileSystem.removeSocket(localSocketPath) }
            try Task.checkCancellation()
            do {
                try fileSystem.prepareSocket(localSocketPath)
            } catch {
                throw RemoteTunnelFailure(
                    phase: .forwarding,
                    kind: .invalidRemoteSocket,
                    exitStatus: nil,
                    diagnostic: boundedDiagnostic(String(describing: error))
                )
            }

            let command: RemoteProcessCommand
            do {
                command = try SSHCommandBuilder.tunnel(
                    for: configuration,
                    localSocketPath: localSocketPath,
                    remoteSocketPath: remoteSocketPath
                )
            } catch let error as SSHCommandBuilderError {
                let kind: RemoteTunnelFailure.Kind
                switch error {
                case .invalidLocalSocketPath, .invalidRemoteSocketPath:
                    kind = .invalidRemoteSocket
                }
                throw RemoteTunnelFailure(
                    phase: .forwarding,
                    kind: kind,
                    exitStatus: nil,
                    diagnostic: boundedDiagnostic(String(describing: error))
                )
            }

            let child: any RemoteTunnelRunningProcess
            do {
                child = try commandRunner.start(command)
            } catch {
                throw RemoteTunnelFailure(
                    phase: .forwarding,
                    kind: .sshLaunch,
                    exitStatus: nil,
                    diagnostic: boundedDiagnostic(String(describing: error))
                )
            }

            await emit(.connecting(attempt: attempt))
            try await withTaskCancellationHandler {
                do {
                    try await waitUntilReady(child)
                    try Task.checkCancellation()
                    await emit(.ready(localSocketPath: localSocketPath))
                    becameReady = true

                    let result = await child.wait()
                    try Task.checkCancellation()
                    throw ReadyTunnelExit(
                        failure: processFailure(result, phase: .forwarding)
                    )
                } catch {
                    // cancellation は onCancel がすでに terminate している。ここで重ねると
                    // process 終了前の短い窓に同じ child へ複数の signal を送る。
                    if !Task.isCancelled, child.isRunning {
                        child.terminate()
                    }
                    _ = await child.wait()
                    throw error
                }
            } onCancel: {
                child.terminate()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if !becameReady {
                cachedRemoteSocketPath = nil
                remoteSocketPathCache.store(nil, configuration)
            }
            throw error
        }
    }

    private func discoverRemoteSocket() async throws -> String {
        let command: RemoteProcessCommand
        do {
            command = try SSHCommandBuilder.status(for: configuration)
        } catch {
            throw RemoteTunnelFailure(
                phase: .discovery,
                kind: .sshLaunch,
                exitStatus: nil,
                diagnostic: boundedDiagnostic(String(describing: error))
            )
        }

        let result: RemoteProcessResult
        do {
            result = try await commandRunner.run(command, timeout: schedule.discoveryTimeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch RemoteTunnelCommandRunnerError.timeout {
            throw RemoteTunnelFailure(
                phase: .discovery,
                kind: .timeout,
                exitStatus: nil,
                diagnostic: "herdr status server --json timed out"
            )
        } catch {
            throw RemoteTunnelFailure(
                phase: .discovery,
                kind: .sshLaunch,
                exitStatus: nil,
                diagnostic: boundedDiagnostic(String(describing: error))
            )
        }

        guard result.status == 0 else {
            throw processFailure(result, phase: .discovery)
        }

        let status: (running: Bool, socket: String?, session: String?)
        do {
            status = try RemoteHerdrStatusParser.parse(result.standardOutput)
        } catch {
            throw RemoteTunnelFailure(
                phase: .discovery,
                kind: .malformedStatus,
                exitStatus: result.status,
                diagnostic: diagnostic(from: result, fallback: String(describing: error))
            )
        }

        guard status.running, let socketPath = status.socket else {
            throw RemoteTunnelFailure(
                phase: .discovery,
                kind: .remoteHerdrStopped,
                exitStatus: result.status,
                diagnostic: "remote Herdr session is not running"
            )
        }

        // `--session default` は Herdr の既定 namespace を表し、status の session は null になる。
        if let requestedSession = configuration.normalizedSessionName,
           requestedSession != "default",
           status.session != requestedSession {
            throw RemoteTunnelFailure(
                phase: .discovery,
                kind: .malformedStatus,
                exitStatus: result.status,
                diagnostic: "remote Herdr returned a different session"
            )
        }

        do {
            _ = try SSHCommandBuilder.tunnel(
                for: configuration,
                localSocketPath: localSocketPath,
                remoteSocketPath: socketPath
            )
        } catch {
            throw RemoteTunnelFailure(
                phase: .discovery,
                kind: .invalidRemoteSocket,
                exitStatus: result.status,
                diagnostic: boundedDiagnostic(String(describing: error))
            )
        }
        return socketPath
    }

    private func waitUntilReady(
        _ child: any RemoteTunnelRunningProcess
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: schedule.readinessTimeout)
        var lastProbeError: String?

        while clock.now < deadline {
            try Task.checkCancellation()
            if !child.isRunning {
                let result = await child.wait()
                throw processFailure(result, phase: .forwarding)
            }

            if fileSystem.socketExists(localSocketPath) {
                do {
                    try await probe.ping(localSocketPath)
                    return
                } catch {
                    lastProbeError = boundedDiagnostic(String(describing: error))
                }
            }
            try await schedule.sleep(schedule.readinessPollInterval)
        }

        throw RemoteTunnelFailure(
            phase: .forwarding,
            kind: lastProbeError == nil ? .timeout : .forwardingRejected,
            exitStatus: nil,
            diagnostic: lastProbeError ?? "local SSH stream socket did not become ready"
        )
    }
}

/// ping 成功後に SSH process が終了したことを outer loop へ伝え、backoff を 1 回目へ戻す印。
private struct ReadyTunnelExit: Error {
    let failure: RemoteTunnelFailure
}

// MARK: - Failure diagnostics

private func processFailure(
    _ result: RemoteProcessResult,
    phase: RemoteTunnelFailure.Phase
) -> RemoteTunnelFailure {
    let message = diagnostic(from: result, fallback: "ssh exited without diagnostics")
    let lowercased = message.lowercased()
    let kind: RemoteTunnelFailure.Kind

    if result.status == 127 || lowercased.contains("herdr: command not found") {
        kind = .remoteHerdrMissing
    } else if lowercased.contains("host key verification failed")
        || lowercased.contains("remote host identification has changed") {
        kind = .hostKey
    } else if lowercased.contains("permission denied")
        || lowercased.contains("no more authentication methods") {
        kind = .authentication
    } else if lowercased.contains("could not resolve hostname")
        || lowercased.contains("connection refused")
        || lowercased.contains("connection timed out")
        || lowercased.contains("operation timed out")
        || lowercased.contains("network is unreachable")
        || lowercased.contains("no route to host") {
        kind = .unreachable
    } else if phase == .forwarding,
              lowercased.contains("administratively prohibited")
                || lowercased.contains("connect failed")
                || lowercased.contains("open failed") {
        kind = .forwardingRejected
    } else {
        kind = .unexpectedExit
    }

    return RemoteTunnelFailure(
        phase: phase,
        kind: kind,
        exitStatus: result.status,
        diagnostic: message
    )
}

private func diagnostic(
    from result: RemoteProcessResult,
    fallback: String
) -> String {
    if !result.standardError.isEmpty {
        let error = boundedDiagnostic(String(decoding: result.standardError, as: UTF8.self))
        if !error.isEmpty { return error }
    }
    if !result.standardOutput.isEmpty {
        let output = boundedDiagnostic(String(decoding: result.standardOutput, as: UTF8.self))
        if !output.isEmpty { return output }
    }
    return boundedDiagnostic(fallback)
}

/// SSH が返す ANSI escape や terminal 制御文字を UI/log へ渡さず、UTF-8 の末尾 4 KiB を残す。
private func boundedDiagnostic(_ value: String) -> String {
    var reversedTail: [Unicode.Scalar] = []
    var byteCount = 0
    for scalar in value.unicodeScalars.reversed() {
        let sanitized: Unicode.Scalar
        switch scalar.value {
        case 0x09, 0x0A, 0x0D:
            sanitized = scalar
        case 0x20...0x10FFFF where !CharacterSet.controlCharacters.contains(scalar):
            sanitized = scalar
        default:
            sanitized = Unicode.Scalar(0xFFFD)!
        }

        let scalarByteCount = String(sanitized).utf8.count
        guard byteCount + scalarByteCount <= 4096 else { break }
        reversedTail.append(sanitized)
        byteCount += scalarByteCount
    }

    let tail = String(String.UnicodeScalarView(reversedTail.reversed()))
    return tail.trimmingCharacters(in: .whitespacesAndNewlines)
}
