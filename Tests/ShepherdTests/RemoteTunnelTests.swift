// Verifies RemoteTunnelManager's state transitions and process ownership without launching SSH or a real Herdr.
// The status response, long-lived child, socket path cache, socket file, ping, and sleep are each controlled
// individually, covering cache reuse across restarts, discarding before ready, retention after ready, and
// terminate on stop.

import Darwin
import Foundation
import XCTest
@testable import Shepherd

final class RemoteTunnelTests: XCTestCase {
    func testLiveProbeSendsLineDelimitedPingAndAcceptsProtocolMismatch() async throws {
        let server = try TestHerdrPingServer()
        async let receivedRequest = server.serveOnePing()

        try await RemoteTunnelProbe.live.ping(server.socketPath)
        let request = try await receivedRequest
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request) as? [String: Any]
        )

        XCTAssertEqual(object["method"] as? String, "ping")
        XCTAssertEqual(object["id"] as? String, "shepherd:tunnel-probe")
    }

    @MainActor
    func testProductionInitializerCreatesPrivateShortSocketPath() throws {
        let manager = try RemoteTunnelManager(configuration: makeConfiguration())
        defer { manager.stop() }

        let directory = (manager.localSocketPath as NSString).deletingLastPathComponent
        let attributes = try FileManager.default.attributesOfItem(atPath: directory)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue

        XCTAssertEqual(permissions, Int(S_IRWXU))
        XCTAssertTrue(manager.localSocketPath.hasSuffix("/herdr.sock"))
        XCTAssertLessThan(
            manager.localSocketPath.utf8.count,
            MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.localSocketPath))
    }

    @MainActor
    func testDoesNotBecomeReadyUntilForwardedPingSucceeds() async throws {
        let child = TestRunningProcess()
        let runner = ScriptedCommandRunner(
            discoveryResults: [statusResult(prefix: "remote shell banner\n")],
            tunnelProcesses: [child]
        )
        let files = TestTunnelFileSystem()
        let probeGate = ProbeGate()
        let manager = try makeManager(
            runner: runner,
            childProbe: RemoteTunnelProbe { _ in
                await probeGate.wait()
            },
            files: files
        )
        defer { manager.stop() }

        var states: [RemoteTunnelState] = []
        manager.onStateChange = { states.append($0) }
        manager.start()

        let becameConnecting = await waitUntil { manager.state.isConnecting }
        XCTAssertTrue(becameConnecting)
        XCTAssertFalse(states.contains(where: \.isReady))

        await probeGate.open()
        let becameReady = await waitUntil { manager.state.isReady }
        XCTAssertTrue(becameReady)
        XCTAssertEqual(runner.discoveryCommandCount, 1)
        XCTAssertEqual(runner.tunnelCommandCount, 1)

        manager.stop()
        let terminated = await waitUntil { child.terminateCallCount == 1 }
        XCTAssertTrue(terminated)
    }

    @MainActor
    func testUserDefaultsCacheSurvivesRecreationAndRejectsEditedDestination() {
        let suiteName = "io.github.cryks.shepherd.socket-cache-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let configuration = makeConfiguration()

        RemoteSocketPathCache.userDefaults(defaults).store(
            "/home/me/.config/herdr/herdr.sock",
            configuration
        )
        let recreatedCache = RemoteSocketPathCache.userDefaults(defaults)

        XCTAssertEqual(
            recreatedCache.load(configuration),
            "/home/me/.config/herdr/herdr.sock"
        )
        var editedAlias = configuration
        editedAlias.sshAlias = "another-workbox"
        XCTAssertNil(recreatedCache.load(editedAlias))
        var editedSession = configuration
        editedSession.sessionName = "agents"
        XCTAssertNil(recreatedCache.load(editedSession))
    }

    @MainActor
    func testReadyTunnelExitReusesCachedSocketAndReconnectsFromFirstBackoff() async throws {
        let firstChild = TestRunningProcess()
        let secondChild = TestRunningProcess()
        let runner = ScriptedCommandRunner(
            discoveryResults: [statusResult()],
            tunnelProcesses: [firstChild, secondChild]
        )
        let files = TestTunnelFileSystem()
        let manager = try makeManager(
            runner: runner,
            childProbe: RemoteTunnelProbe { _ in },
            files: files
        )
        defer { manager.stop() }

        var states: [RemoteTunnelState] = []
        manager.onStateChange = { states.append($0) }
        manager.start()
        let firstConnectionBecameReady = await waitUntil { manager.state.isReady }
        XCTAssertTrue(firstConnectionBecameReady)

        firstChild.exit(
            RemoteProcessResult(
                status: 255,
                reason: .exit,
                standardOutput: Data(),
                standardError: Data("Connection reset by peer\n".utf8)
            )
        )

        let reconnected = await waitUntil {
            runner.discoveryCommandCount == 1
                && runner.tunnelCommandCount == 2
                && manager.state.isReady
        }
        XCTAssertTrue(reconnected)
        let retryDelays = states.compactMap { state -> Duration? in
            guard case .retrying(_, let delay) = state else { return nil }
            return delay
        }
        XCTAssertEqual(retryDelays.first, .milliseconds(1))
        XCTAssertEqual(
            states.filter { state in
                guard case .discovering(attempt: 1) = state else { return false }
                return true
            }.count,
            2
        )
    }

    @MainActor
    func testFailureBeforeReadyClearsCacheAndRediscoversSocket() async throws {
        let failedChild = TestRunningProcess()
        failedChild.exit(
            RemoteProcessResult(
                status: 255,
                reason: .exit,
                standardOutput: Data(),
                standardError: Data("open failed: connect failed\n".utf8)
            )
        )
        let readyChild = TestRunningProcess()
        let cache = TestRemoteSocketPathCache()
        let runner = ScriptedCommandRunner(
            discoveryResults: [
                statusResult(socketPath: "/run/herdr/old.sock"),
                statusResult(socketPath: "/run/herdr/new.sock"),
            ],
            tunnelProcesses: [failedChild, readyChild]
        )
        let files = TestTunnelFileSystem()
        let manager = try makeManager(
            runner: runner,
            childProbe: RemoteTunnelProbe { _ in },
            files: files,
            remoteSocketPathCache: cache.dependency
        )
        defer { manager.stop() }

        manager.start()
        let rediscovered = await waitUntil {
            runner.discoveryCommandCount == 2
                && runner.tunnelCommandCount == 2
                && manager.state.isReady
        }

        XCTAssertTrue(rediscovered)
        XCTAssertEqual(cache.value, "/run/herdr/new.sock")
    }

    @MainActor
    func testRecreatedManagerUsesCacheWithoutDiscovery() async throws {
        let cache = TestRemoteSocketPathCache()
        let firstChild = TestRunningProcess()
        let firstRunner = ScriptedCommandRunner(
            discoveryResults: [statusResult()],
            tunnelProcesses: [firstChild]
        )
        let firstFiles = TestTunnelFileSystem()
        let firstManager = try makeManager(
            runner: firstRunner,
            childProbe: RemoteTunnelProbe { _ in },
            files: firstFiles,
            remoteSocketPathCache: cache.dependency
        )

        firstManager.start()
        let firstBecameReady = await waitUntil { firstManager.state.isReady }
        XCTAssertTrue(firstBecameReady)
        firstManager.stop()
        let firstWasTerminated = await waitUntil { firstChild.terminateCallCount == 1 }
        XCTAssertTrue(firstWasTerminated)

        let secondChild = TestRunningProcess()
        let secondRunner = ScriptedCommandRunner(
            discoveryResults: [],
            tunnelProcesses: [secondChild]
        )
        let secondFiles = TestTunnelFileSystem()
        let secondManager = try makeManager(
            runner: secondRunner,
            childProbe: RemoteTunnelProbe { _ in },
            files: secondFiles,
            remoteSocketPathCache: cache.dependency
        )
        defer { secondManager.stop() }

        secondManager.start()
        let secondBecameReady = await waitUntil { secondManager.state.isReady }
        XCTAssertTrue(secondBecameReady)
        XCTAssertEqual(firstRunner.discoveryCommandCount, 1)
        XCTAssertEqual(secondRunner.discoveryCommandCount, 0)
        XCTAssertEqual(secondRunner.tunnelCommandCount, 1)
    }

    @MainActor
    func testStopBeforeReadyPreservesCacheForNextOnCycle() async throws {
        let cache = TestRemoteSocketPathCache()
        let child = TestRunningProcess()
        let runner = ScriptedCommandRunner(
            discoveryResults: [statusResult()],
            tunnelProcesses: [child]
        )
        let files = TestTunnelFileSystem()
        let manager = try makeManager(
            runner: runner,
            childProbe: RemoteTunnelProbe { _ in
                try await Task.sleep(for: .seconds(60))
            },
            files: files,
            remoteSocketPathCache: cache.dependency
        )

        manager.start()
        let becameConnecting = await waitUntil { manager.state.isConnecting }
        XCTAssertTrue(becameConnecting)
        manager.stop()
        let childWasTerminated = await waitUntil { child.terminateCallCount == 1 }

        XCTAssertTrue(childWasTerminated)
        XCTAssertEqual(cache.value, "/home/me/.config/herdr/herdr.sock")
    }

    @MainActor
    func testAuthenticationFailurePublishesBoundedDiagnosticAndWaitsForRetry() async throws {
        let sshDiagnostic = String(repeating: "\u{001B}", count: 5_000)
            + "Permission denied (publickey).\n"
        let result = RemoteProcessResult(
            status: 255,
            reason: .exit,
            standardOutput: Data(),
            standardError: Data(sshDiagnostic.utf8)
        )
        let runner = ScriptedCommandRunner(discoveryResults: [result], tunnelProcesses: [])
        let files = TestTunnelFileSystem()
        let manager = try makeManager(
            runner: runner,
            childProbe: RemoteTunnelProbe { _ in },
            files: files,
            retrySleep: { _ in
                try await Task.sleep(for: .seconds(60))
            }
        )
        defer { manager.stop() }

        manager.start()
        let beganRetryWait = await waitUntil { manager.state.isRetrying }
        XCTAssertTrue(beganRetryWait)

        guard case .retrying(let failure, let delay) = manager.state else {
            return XCTFail("認証失敗が retrying state へ公開されなかった")
        }
        XCTAssertEqual(failure.phase, .discovery)
        XCTAssertEqual(failure.kind, .authentication)
        XCTAssertEqual(failure.exitStatus, 255)
        XCTAssertTrue(failure.diagnostic.hasSuffix("Permission denied (publickey)."))
        XCTAssertLessThanOrEqual(failure.diagnostic.utf8.count, 4096)
        XCTAssertFalse(failure.diagnostic.contains("\u{001B}"))
        XCTAssertEqual(delay, .milliseconds(1))
        XCTAssertEqual(runner.discoveryCommandCount, 1)
    }

    @MainActor
    func testInvalidRemoteSocketStopsWithoutRetryingOrStartingTunnel() async throws {
        let runner = ScriptedCommandRunner(
            discoveryResults: [statusResult(socketPath: "/home/me/config:copy/herdr.sock")],
            tunnelProcesses: []
        )
        let files = TestTunnelFileSystem()
        let manager = try makeManager(
            runner: runner,
            childProbe: RemoteTunnelProbe { _ in },
            files: files
        )
        defer { manager.stop() }

        manager.start()
        let becameFailed = await waitUntil { manager.state.isFailed }
        XCTAssertTrue(becameFailed)

        guard case .failed(let failure) = manager.state else {
            return XCTFail("不正 remote socket が failed state へ公開されなかった")
        }
        XCTAssertEqual(failure.kind, .invalidRemoteSocket)
        XCTAssertEqual(runner.discoveryCommandCount, 1)
        XCTAssertEqual(runner.tunnelCommandCount, 0)

        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(runner.discoveryCommandCount, 1)
    }

    @MainActor
    func testStopCancelsInFlightDiscovery() async throws {
        let runner = CancellableDiscoveryRunner()
        let files = TestTunnelFileSystem()
        let manager = try makeManager(
            runner: runner,
            childProbe: RemoteTunnelProbe { _ in },
            files: files
        )

        manager.start()
        let discoveryStarted = await waitUntil { runner.runCallCount == 1 }
        XCTAssertTrue(discoveryStarted)
        manager.stop()

        let discoveryWasCancelled = await waitUntil { runner.wasCancelled }
        XCTAssertTrue(discoveryWasCancelled)
        XCTAssertEqual(manager.state, .stopped)
    }

    @MainActor
    private func makeManager(
        runner: any RemoteTunnelCommandRunning,
        childProbe: RemoteTunnelProbe,
        files: TestTunnelFileSystem,
        remoteSocketPathCache: RemoteSocketPathCache = .disabled,
        retrySleep: @escaping @Sendable (Duration) async throws -> Void = { _ in
            try await Task.sleep(for: .milliseconds(1))
        }
    ) throws -> RemoteTunnelManager {
        try RemoteTunnelManager(
            configuration: makeConfiguration(),
            localSocketPath: "/tmp/shepherd-tests/private/herdr.sock",
            commandRunner: runner,
            probe: childProbe,
            fileSystem: files.dependency,
            schedule: RemoteTunnelSchedule(
                discoveryTimeout: .seconds(1),
                readinessTimeout: .seconds(1),
                readinessPollInterval: .milliseconds(1),
                retryDelay: { _ in .milliseconds(1) },
                sleep: retrySleep
            ),
            remoteSocketPathCache: remoteSocketPathCache
        )
    }

    private func makeConfiguration() -> RemoteSourceConfiguration {
        RemoteSourceConfiguration(
            id: .remote(uuid: UUID(uuidString: "0bf8e281-1055-4d9f-acf8-f629c8421cf8")!),
            label: "Work",
            sshAlias: "workbox"
        )
    }

    private func statusResult(
        prefix: String = "",
        socketPath: String = "/home/me/.config/herdr/herdr.sock"
    ) -> RemoteProcessResult {
        let json = #"{"status":"running","running":true,"socket":"\#(socketPath)","session":null}"#
        return RemoteProcessResult(
            status: 0,
            reason: .exit,
            standardOutput: Data("\(prefix)\(json)\n".utf8),
            standardError: Data()
        )
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }
}

private extension RemoteTunnelState {
    var isConnecting: Bool {
        guard case .connecting = self else { return false }
        return true
    }

    var isReady: Bool {
        guard case .ready = self else { return false }
        return true
    }

    var isRetrying: Bool {
        guard case .retrying = self else { return false }
        return true
    }

    var isFailed: Bool {
        guard case .failed = self else { return false }
        return true
    }
}

private enum TunnelTestError: Error {
    case scriptExhausted
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case accept(Int32)
    case read(Int32)
    case connectionClosed
    case requestTooLarge
    case write(Int32)
}

/// One-shot server that receives the live probe's wire contract on a temporary Unix socket outside the repository.
private final class TestHerdrPingServer: @unchecked Sendable {
    let socketPath: String
    private let serverFileDescriptor: Int32

    init() throws {
        socketPath = "/tmp/shepherd-probe-\(UUID().uuidString.prefix(12)).sock"
        _ = unlink(socketPath)

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else { throw TunnelTestError.socket(errno) }
        serverFileDescriptor = fileDescriptor

        var noSigPipe: Int32 = 1
        _ = withUnsafePointer(to: &noSigPipe) { pointer in
            setsockopt(
                fileDescriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: socketPath.utf8)
        }
        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(
                    fileDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fileDescriptor)
            throw TunnelTestError.bind(errno)
        }
        guard Darwin.listen(fileDescriptor, 1) == 0 else {
            Darwin.close(fileDescriptor)
            _ = unlink(socketPath)
            throw TunnelTestError.listen(errno)
        }
    }

    deinit {
        Darwin.close(serverFileDescriptor)
        _ = unlink(socketPath)
    }

    func serveOnePing() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    continuation.resume(returning: try serveOnePingSync())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func serveOnePingSync() throws -> Data {
        let client = Darwin.accept(serverFileDescriptor, nil, nil)
        guard client >= 0 else { throw TunnelTestError.accept(errno) }
        defer { Darwin.close(client) }

        var request = Data()
        while request.firstIndex(of: 0x0A) == nil {
            var byte: UInt8 = 0
            let count = Darwin.read(client, &byte, 1)
            guard count >= 0 else { throw TunnelTestError.read(errno) }
            guard count > 0 else { throw TunnelTestError.connectionClosed }
            request.append(byte)
            guard request.count <= 4096 else { throw TunnelTestError.requestTooLarge }
        }

        let responseObject: [String: Any] = [
            "id": "shepherd:tunnel-probe",
            "result": [
                "version": "test",
                "protocol": Herdr.supportedProtocol - 1,
            ],
        ]
        var response = try JSONSerialization.data(withJSONObject: responseObject)
        response.append(0x0A)
        try response.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    client,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else { throw TunnelTestError.write(errno) }
                offset += count
            }
        }

        let newline = request.firstIndex(of: 0x0A)!
        return Data(request[..<newline])
    }
}

/// Runner that hands out discovery responses and tunnel children in FIFO order and records launch counts.
private final class ScriptedCommandRunner: RemoteTunnelCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var discoveryResults: [RemoteProcessResult]
    private var tunnelProcesses: [TestRunningProcess]
    private var discoveryCommands: [RemoteProcessCommand] = []
    private var tunnelCommands: [RemoteProcessCommand] = []

    init(
        discoveryResults: [RemoteProcessResult],
        tunnelProcesses: [TestRunningProcess]
    ) {
        self.discoveryResults = discoveryResults
        self.tunnelProcesses = tunnelProcesses
    }

    var discoveryCommandCount: Int {
        withLock { discoveryCommands.count }
    }

    var tunnelCommandCount: Int {
        withLock { tunnelCommands.count }
    }

    func run(
        _ command: RemoteProcessCommand,
        timeout _: Duration
    ) async throws -> RemoteProcessResult {
        try takeRunResult(recording: command)
    }

    private func takeRunResult(
        recording command: RemoteProcessCommand
    ) throws -> RemoteProcessResult {
        lock.lock()
        defer { lock.unlock() }

        discoveryCommands.append(command)
        guard !discoveryResults.isEmpty else { throw TunnelTestError.scriptExhausted }
        return discoveryResults.removeFirst()
    }

    func start(_ command: RemoteProcessCommand) throws -> any RemoteTunnelRunningProcess {
        try takeTunnelProcess(recording: command)
    }

    private func takeTunnelProcess(
        recording command: RemoteProcessCommand
    ) throws -> TestRunningProcess {
        lock.lock()
        defer { lock.unlock() }
        tunnelCommands.append(command)
        guard !tunnelProcesses.isEmpty else { throw TunnelTestError.scriptExhausted }
        return tunnelProcesses.removeFirst()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// In-memory cache that returns the same path across manager recreation and also observes clearing via store(nil).
private final class TestRemoteSocketPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String?

    var dependency: RemoteSocketPathCache {
        RemoteSocketPathCache(
            load: { [weak self] _ in self?.value },
            store: { [weak self] path, _ in self?.setValue(path) }
        )
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    private func setValue(_ value: String?) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }
}

/// Long-lived child that keeps wait pending until terminate or a test-driven exit.
private final class TestRunningProcess: RemoteTunnelRunningProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var result: RemoteProcessResult?
    private var waiters: [CheckedContinuation<RemoteProcessResult, Never>] = []
    private var terminateCalls = 0

    var isRunning: Bool {
        withLock { result == nil }
    }

    var terminateCallCount: Int {
        withLock { terminateCalls }
    }

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

    func terminate() {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        terminateCalls += 1
        lock.unlock()
        exit(
            RemoteProcessResult(
                status: SIGTERM,
                reason: .signal,
                standardOutput: Data(),
                standardError: Data()
            )
        )
    }

    func exit(_ result: RemoteProcessResult) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()

        waiters.forEach { $0.resume(returning: result) }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Filesystem that reproduces the state where the SSH listener has appeared at prepare time.
private final class TestTunnelFileSystem: @unchecked Sendable {
    private let lock = NSLock()
    private var available = false

    var dependency: RemoteTunnelFileSystem {
        RemoteTunnelFileSystem(
            prepareSocket: { [weak self] _ in
                self?.setAvailable(true)
            },
            socketExists: { [weak self] _ in
                self?.isAvailable ?? false
            },
            removeSocket: { [weak self] _ in
                self?.setAvailable(false)
            }
        )
    }

    private var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return available
    }

    private func setAvailable(_ value: Bool) {
        lock.lock()
        available = value
        lock.unlock()
    }
}

/// Blocks the ping until the test opens the gate, creating the boundary where listener creation alone does not make the tunnel ready.
private actor ProbeGate {
    private var isOpen = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func open() {
        isOpen = true
        waiter?.resume()
        waiter = nil
    }
}

/// Records that Task cancellation during discovery propagates all the way to the command runner.
private final class CancellableDiscoveryRunner: RemoteTunnelCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var cancelled = false

    var runCallCount: Int {
        withLock { calls }
    }

    var wasCancelled: Bool {
        withLock { cancelled }
    }

    func run(
        _: RemoteProcessCommand,
        timeout _: Duration
    ) async throws -> RemoteProcessResult {
        setCallStarted()
        return try await withTaskCancellationHandler {
            try await Task.sleep(for: .seconds(60))
            throw TunnelTestError.scriptExhausted
        } onCancel: { [weak self] in
            self?.setCancelled()
        }
    }

    func start(_: RemoteProcessCommand) throws -> any RemoteTunnelRunningProcess {
        throw TunnelTestError.scriptExhausted
    }

    private func setCallStarted() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    private func setCancelled() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
