// herdr サーバの Unix socket との一発 RPC 通信層。ワイヤは改行区切り JSON。
// リクエスト 1 行につきレスポンス 1 行を読み、RPC ごとに接続を閉じる。socketPath は
// ローカル herdr の既定 socket と、SSH が remote socket を転送した endpoint 固有 socket の
// どちらも受け付ける。この層はバックグラウンドキューで同期 I/O を行い、上位へ async API
// として返す。read/write は 10 秒、応答行は 4 MiB を上限とし、UI 状態やpoll周期は持たない。

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
    /// ローカル default session の接続先。remote session はこの path を上書きせず、
    /// RemoteTunnelManager が source ごとの一時 socket を Store.live へ渡す。
    static var defaultSocketPath: String {
        return NSHomeDirectory() + "/.config/herdr/herdr.sock"
    }

    /// このアプリが実装対象にしているソケット API のバージョン。
    /// session.snapshot の protocol がこれと異なる場合、上位はグレーアイコンにする。
    static let supportedProtocol = 16

    /// 一発 RPC。呼び出しごとに接続を張り、レスポンス 1 行を受けて閉じる。
    /// サーバがエラー行を返した場合は RPCError を投げる。
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

// MARK: - POSIX ソケットヘルパ

private func connectSocket(path: String, ioTimeout: TimeInterval) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw HerdrClientError.socketFailed(errno) }

    // remote tunnel の終了と RPC write が競合しても SIGPIPE でアプリ全体を終了させず、
    // writeFailed として endpoint 単位の再接続へ戻す。
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
    // sun_path は 104 バイト固定。ホームディレクトリ配下のパスなら収まるが、超えたら明示的に落とす。
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

/// fd から改行区切りで 1 行ずつ読むリーダ。ブロッキング read 前提。
private final class LineReader {
    private let fd: Int32
    private let maximumLineBytes: Int
    private var buffer = Data()

    init(fd: Int32, maximumLineBytes: Int) {
        self.fd = fd
        self.maximumLineBytes = maximumLineBytes
    }

    /// 次の 1 行 (LF を除く) を返す。サーバが接続を閉じたら nil。
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
