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
    static var defaultSocketPath: String {
        return NSHomeDirectory() + "/.config/herdr/herdr.sock"
    }

    // The socket API version this app was written against. Upper layers compare
    // it with session.snapshot's protocol and warn on a difference.
    static let supportedProtocol = 20

    static func request<R: Codable>(
        _ method: String,
        params: [String: Any] = [:],
        socketPath: String = defaultSocketPath,
        as type: R.Type
    ) async throws -> R {
        try await request(method, params: params, socketPath: socketPath, as: type) { result, _ in
            result
        }
    }

    // transform also receives the raw response line so a caller that needs the
    // bytes makeDecoder() dropped or renamed can decode it again instead of
    // issuing a second RPC. It runs on the background queue that did the I/O.
    static func request<R: Codable, T>(
        _ method: String,
        params: [String: Any] = [:],
        socketPath: String = defaultSocketPath,
        as type: R.Type,
        transform: @escaping (_ result: R, _ responseLine: Data) throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let line = try requestSync(
                        method,
                        params: params,
                        socketPath: socketPath
                    )
                    let response = try makeDecoder().decode(RPCResponse<R>.self, from: line)
                    if let error = response.error { throw error }
                    guard let result = response.result else {
                        throw HerdrClientError.emptyResult
                    }
                    continuation.resume(returning: try transform(result, line))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func requestSync(
        _ method: String,
        params: [String: Any],
        socketPath: String
    ) throws -> Data {
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
        return line
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

    // A tunnel teardown that races with an RPC write must not kill the app with
    // SIGPIPE; report it as writeFailed and let the endpoint reconnect.
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
    // sun_path is a fixed 104 bytes. Paths under the home directory fit; a
    // longer one has to fail here rather than be silently truncated.
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

// Blocking reads only; connectSocket's SO_RCVTIMEO is what bounds them.
private final class LineReader {
    private let fd: Int32
    private let maximumLineBytes: Int
    private var buffer = Data()

    init(fd: Int32, maximumLineBytes: Int) {
        self.fd = fd
        self.maximumLineBytes = maximumLineBytes
    }

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
