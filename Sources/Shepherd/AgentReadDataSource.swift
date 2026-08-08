import Foundation

// Closures rather than a protocol so tests can gate each stage of the
// bracketing transaction separately without opening a Unix socket.
struct AgentReadDataSource: Sendable {
    var get: @Sendable (_ target: String) async throws -> AgentGetResult
    var readVisible: @Sendable (_ target: String) async throws -> AgentReadResult

    // The socket path is pinned per instance: a remote endpoint must be read
    // over its SSH-forwarded socket, not the local default one.
    static func live(socketPath: String) -> AgentReadDataSource {
        AgentReadDataSource(
            get: { [socketPath] target in
                try await Herdr.request(
                    "agent.get",
                    params: ["target": target],
                    socketPath: socketPath,
                    as: AgentGetResult.self
                )
            },
            // `lines` is omitted on purpose: a visible read is already bounded
            // by the terminal viewport and Herdr's response limit.
            readVisible: { [socketPath] target in
                try await Herdr.request(
                    "agent.read",
                    params: [
                        "target": target,
                        "source": "visible",
                        "format": "text",
                        "strip_ansi": true,
                    ],
                    socketPath: socketPath,
                    as: AgentReadResult.self
                )
            }
        )
    }
}
