import Darwin
import Foundation

// MARK: - Public boundary used by EndpointMonitor

// stop() publishes .stopped at once, but reaping the SSH process runs in the
// background, so an immediate start() resumes only after the previous task ends.
@MainActor
protocol RemoteTunnelManaging: AnyObject {
    var configuration: RemoteSourceConfiguration { get }
    var localSocketPath: String { get }
    var state: RemoteTunnelState { get }
    var onStateChange: ((RemoteTunnelState) -> Void)? { get set }

    func start()
    func stop()
}

// .ready needs a ping answered through the local listener, not just the listener
// itself. Protocol support is judged upstream, not here.
enum RemoteTunnelState: Equatable, Sendable {
    case stopped
    case discovering(attempt: Int)
    case connecting(attempt: Int)
    case ready(localSocketPath: String)
    case retrying(failure: RemoteTunnelFailure, delay: Duration)
    case failed(failure: RemoteTunnelFailure)
}

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

    // Everything but a bad socket path can recover on its own once the network,
    // the auth agent, or the remote Herdr changes.
    var isRetryable: Bool {
        kind != .invalidRemoteSocket
    }
}

struct RemoteSocketPathCache: Sendable {
    let load: @Sendable (RemoteSourceConfiguration) -> String?
    let store: @Sendable (String?, RemoteSourceConfiguration) -> Void

    static let live = userDefaults(.standard)

    static let disabled = RemoteSocketPathCache(
        load: { _ in nil },
        store: { _, _ in }
    )

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

    // A cached path from a different destination would forward to the wrong host,
    // so the entry is dropped unless the alias and session still match.
    func matches(_ configuration: RemoteSourceConfiguration) -> Bool {
        sshAlias == configuration.sshAlias
            && sessionName == configuration.normalizedSessionName
    }
}

private final class UserDefaultsRemoteSocketPathStorage: @unchecked Sendable {
    private let defaults: UserDefaults
    // All sources share one key, so read-modify-write must be serialized or a
    // concurrent store drops another source's entry.
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

    // Test seam. The caller owns the directory holding localSocketPath, so
    // runtimeDirectoryPath stays nil and deinit never removes it.
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

// OpenSSH joins the remote command back into one string and hands it to the
// destination's login shell, so the argv here keeps exactly one dynamic remote
// token: the session name already validated against Herdr's ASCII grammar.
enum SSHCommandBuilder {
    private static let executablePath = "/usr/bin/ssh"

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

    // A GUI app can answer no prompt, and multiplexing or backgrounding would
    // outlive the process Shepherd supervises. Connection details such as
    // ProxyJump and IdentityFile still come from the user's OpenSSH config.
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

    // `-n` and StdinNull=yes are left out: the resolver script arrives on SSH stdin.
    private static let discoveryOptions = ["-T"] + connectionPolicyOptions

    // ClearAllForwardings=no keeps the command-line `-L` alive against a config
    // that clears forwardings. The unlink only ever hits a stale socket in the
    // app-owned directory, and the bind mask keeps the listener owner-only.
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

    // Every candidate stays quoted as "$candidate" so a remote value is executed,
    // never reinterpreted as shell source. mise shims are skipped because a
    // non-interactive shell often cannot resolve the tool version; the install
    // directories are searched instead.
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
        if [ "$require_protocol" = 1 ]; then
            # A delimiter after the JSON number rejects longer versions that
            # share its prefix.
            case "$client_status" in
                *"$protocol_field,"*|*"$protocol_field}"*) ;;
                *) return 1 ;;
            esac
        fi

        # The default namespace is not a named session, so do not pass --session to Herdr.
        if [ "$session" = default ]; then
            "$candidate" status server --json
        else
            "$candidate" "--session=$session" status server --json
        fi
    }

    try_candidates() {
        path_candidate=$(command -v herdr 2>/dev/null || :)
        case "$path_candidate" in
            /*/mise/shims/herdr) ;;
            /*) run_status "$path_candidate" && return 0 ;;
        esac

        if [ -n "$home" ]; then
            run_status "$home/.local/bin/herdr" && return 0
        fi

        case "$(uname -s 2>/dev/null || :)" in
            Darwin)
                run_status /opt/homebrew/bin/herdr && return 0
                run_status /usr/local/bin/herdr && return 0
                ;;
            Linux)
                run_status /home/linuxbrew/.linuxbrew/bin/herdr && return 0
                ;;
        esac

        if [ -n "$home" ]; then
            for candidate in \\
                "$home"/.local/share/mise/installs/herdr/*/bin/herdr \\
                "$home"/.local/share/mise/installs/github-ogulcancelik-herdr/*/herdr
            do
                run_status "$candidate" && return 0
            done
            run_status "$home/.nix-profile/bin/herdr" && return 0
        fi

        if [ -n "$user" ]; then
            run_status "/etc/profiles/per-user/$user/bin/herdr" && return 0
        fi
        run_status /nix/var/nix/profiles/default/bin/herdr && return 0
        run_status /run/current-system/sw/bin/herdr && return 0
        return 1
    }

    # Prefer a CLI on Shepherd's protocol; retry accepting any herdr that
    # answers, so a protocol bump degrades to optimistic monitoring instead
    # of losing the endpoint.
    require_protocol=1
    try_candidates && exit 0
    require_protocol=0
    try_candidates && exit 0

    printf '%s\\n' 'no herdr executable found in known remote locations' >&2
    exit 127
    """

    // The colon separates the two sides of OpenSSH's stream-local `-L` argument,
    // so a path containing one would split into a different forwarding.
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

// The Herdr socket API grants full control of the remote server, so the local end
// is a Unix socket inside a mode 0700 mkdtemp directory: unreachable by other
// users whatever StreamLocalBindMask does, and free of collisions with a second
// Shepherd process.
private struct PrivateTunnelSocketWorkspace {
    let directoryPath: String
    let socketPath: String

    static func create() throws -> PrivateTunnelSocketWorkspace {
        let preferredBase = FileManager.default.temporaryDirectory.path
        if let workspace = try create(under: preferredBase, rejectLongPath: true) {
            return workspace
        }
        // sun_path is short enough that a long TMPDIR alone can overflow it.
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

// Unlinking is limited to sockets. Anything else at that path means the app-owned
// directory assumption is broken, and deleting a stranger's file is worse than
// refusing to launch.
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

// Discovery only has to locate the socket; Store compares the protocol later,
// through the forwarded socket.
private struct RemoteHerdrServerStatus: Decodable {
    let running: Bool
    let socket: String?
    let session: String?
}

enum RemoteHerdrStatusParserError: Error, Equatable {
    case noStatusJSON
}

enum RemoteHerdrStatusParser {
    // Some hosts leak a shell banner into stdout, so the status is the last
    // decodable line. The Herdr CLI always prints its JSON on one line.
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

// SSH creates the local listener before the remote end is proven usable, so
// readiness needs a real request through it.
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

private func pingHerdrSocket(path: String) throws {
    let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fileDescriptor >= 0 else { throw RemoteTunnelProbeError.socket(errno) }
    defer { Darwin.close(fileDescriptor) }

    // The probe can race tunnel shutdown; without this the write would raise a
    // process-wide SIGPIPE instead of an EPIPE this attempt can report.
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
    // The protocol number in the result is ignored: a mismatch still proves the
    // tunnel carries Herdr traffic, and Store decides what to do about it.
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

// The pipe must be drained continuously or a chatty child blocks forever on a
// full buffer, yet only the tail is worth keeping for diagnostics.
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

    // The reader only sees EOF once the parent drops its own write end.
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
            // The remote command may exit before it reads stdin; without this the
            // write below would raise an app-wide SIGPIPE instead of EPIPE.
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

        // ssh needs the inherited PATH and SSH_AUTH_SOCK, so the overrides are
        // merged over the parent environment rather than replacing it.
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
            // A blocking write is safe only because the script is a fixed literal
            // smaller than the pipe buffer. Closing the write end is what gives the
            // remote `/bin/sh -s` its EOF.
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

    // The PID may already belong to an unrelated process by now, so the identity
    // is confirmed against Process itself before the signal.
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
                // `ssh -N` returns only when it is stopped, and that path throws.
                return
            } catch is CancellationError {
                break
            } catch let readyExit as ReadyTunnelExit {
                // A successful ping proves the endpoint works, so a later line drop
                // must not inherit the backoff an old failure streak had reached.
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
                    // onCancel already signalled the child; signalling again before
                    // it exits would hit the same process twice.
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
            // A path that once reached ready is still good; only a failure before
            // ready suggests the cached path is stale.
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

        // Herdr reports its default namespace as a null session, so the literal
        // name "default" can never match the returned value.
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

// SSH stderr can carry ANSI escapes and terminal control characters that would
// act on whatever renders the message, so only the readable tail survives.
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
