// Socket-bound RPC access for coherent agent screen observations. This file
// owns no polling, cache, or extraction state: the monitor decides when to run
// agent.get -> agent.read -> agent.get and rejects an observation when the two
// AgentInfo values describe different states or occupants. Each live instance
// captures one explicit socket path so remote reads stay on their SSH-forwarded
// Herdr endpoint rather than falling through to the local default socket.

import Foundation

/// Pair of RPC operations used by the agent screen monitor. Tests can replace
/// either closure independently to gate each stage of the bracketing
/// transaction without opening a Unix socket.
struct AgentReadDataSource: Sendable {
    var get: @Sendable (_ target: String) async throws -> AgentGetResult
    var readVisible: @Sendable (_ target: String) async throws -> AgentReadResult

    /// Creates a data source pinned to `socketPath`.
    ///
    /// `readVisible` requests the terminal's current visible grid as plain text
    /// and asks Herdr to remove ANSI sequences. It intentionally omits `lines`;
    /// visible reads are bounded by the terminal viewport and Herdr's response
    /// limit.
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
