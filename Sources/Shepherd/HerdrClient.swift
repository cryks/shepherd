// One-shot RPC layer over the herdr server's Unix socket. The wire format is
// newline-delimited JSON: one response line is read per request line, and the
// connection is closed after each RPC. socketPath accepts both the local
// herdr's default socket and the per-endpoint socket that SSH forwards from the
// remote socket. This layer does synchronous I/O on a background queue and
// exposes an async API upward. read/write are capped at 10 seconds and a
// response line at 4 MiB; it holds no UI state or poll cadence.

import Foundation

enum HerdrClientError: Error {
    case socketFailed(Int32)
    case connectFailed(Int32)
    case pathTooLong
    case connectionClosed
    case writeFailed(Int32)
    case readFailed(Int32)
    case responseTooLarge(Int)
    case emptyResult
}

enum Herdr {
    /// Endpoint of the local default session. Remote sessions do not override
    /// this path; RemoteTunnelManager passes a per-source temporary socket to
    /// Store.live.
    static var defaultSocketPath: String {
        return NSHomeDirectory() + "/.config/herdr/herdr.sock"
    }

    /// The socket API version this app is written against. When
    /// session.snapshot's protocol differs from this, upper layers show the
    /// gray icon.
    static let supportedProtocol = 17

    /// One-shot RPC. Opens a connection per call, receives one response line,
    /// then closes. Throws RPCError when the server returns an error line.
    static func request<R: Codable>(
        _ method: String,
        params: [String: Any] = [:],
        socketPath: String = defaultSocketPath,
        as type: R.Type
    ) async throws -> R {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(
                        returning: try requestSync(
                            method,
                            params: params,
                            socketPath: socketPath
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func requestSync<R: Codable>(
        _ method: String,
        params: [String: Any],
        socketPath: String
    ) throws -> R {
        let fd = try connectSocket(path: socketPath, ioTimeout: 10)
        defer { close(fd) }

        let envelope: [String: Any] = [
            "id": "shepherd:\(method)",
            "method": method,
            "params": params,
        ]
        var data = try JSONSerialization.data(withJSONObject: envelope)
        data.append(0x0A)
        try writeAll(fd, data)

        guard let line = try LineReader(fd: fd, maximumLineBytes: 4 * 1024 * 1024).readLine() else {
            throw HerdrClientError.connectionClosed
        }
        let response = try makeDecoder().decode(RPCResponse<R>.self, from: line)
        if let error = response.error { throw error }
        guard let result = response.result else { throw HerdrClientError.emptyResult }
        return result
    }
}

func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}

// MARK: - POSIX socket helpers

private func connectSocket(path: String, ioTimeout: TimeInterval) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HerdrClientError.socketFailed(errno) }

    // Even if a remote tunnel teardown races with an RPC write, don't let
    // SIGPIPE kill the whole app; surface it as writeFailed and return to the
    // per-endpoint reconnect path.
    var noSigPipe: Int32 = 1
    guard setsockopt(
        fd,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSigPipe,
        socklen_t(MemoryLayout<Int32>.size)
    ) == 0 else {
        let err = errno
        close(fd)
        throw HerdrClientError.socketFailed(err)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    // sun_path is fixed at 104 bytes. Paths under the home directory fit, but
    // anything longer fails explicitly.
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
        close(fd)
        throw HerdrClientError.pathTooLong
    }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        dst.copyBytes(from: bytes)
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let err = errno
        close(fd)
        throw HerdrClientError.connectFailed(err)
    }

    var timeout = timeval(
        tv_sec: Int(ioTimeout),
        tv_usec: Int32((ioTimeout - floor(ioTimeout)) * 1_000_000)
    )
    let size = socklen_t(MemoryLayout<timeval>.size)
    guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, size) == 0,
          setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, size) == 0 else {
        let err = errno
        close(fd)
        throw HerdrClientError.connectFailed(err)
    }
    return fd
}

private func writeAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        var offset = 0
        while offset < raw.count {
            let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
            guard n > 0 else { throw HerdrClientError.writeFailed(errno) }
            offset += n
        }
    }
}

/// Reader that yields newline-delimited lines from an fd. Assumes blocking reads.
private final class LineReader {
    private let fd: Int32
    private let maximumLineBytes: Int
    private var buffer = Data()

    init(fd: Int32, maximumLineBytes: Int) {
        self.fd = fd
        self.maximumLineBytes = maximumLineBytes
    }

    /// Returns the next line (LF excluded). nil when the server has closed the connection.
    func readLine() throws -> Data? {
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<index])
                buffer = Data(buffer[buffer.index(after: index)...])
                return line
            }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return nil }
            guard n > 0 else { throw HerdrClientError.readFailed(errno) }
            buffer.append(contentsOf: chunk[0..<n])
            guard buffer.count <= maximumLineBytes else {
                throw HerdrClientError.responseTooLarge(maximumLineBytes)
            }
        }
    }
}
