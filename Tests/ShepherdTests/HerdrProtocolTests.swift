// Pins Shepherd's protocol boundary to the subset of Herdr JSON it consumes.
// Protocol 17 adds agent lifecycle fields while preserving the snapshot,
// workspace, and pane fields below; unknown fields remain outside Shepherd's
// model instead of being copied into display state.

import Darwin
import Foundation
import XCTest
@testable import Shepherd

final class HerdrProtocolTests: XCTestCase {
    func testDecodesProtocol17SessionSnapshotSubset() throws {
        let json = Data(
            #"""
            {
              "type": "session_snapshot",
              "snapshot": {
                "version": "0.7.5",
                "protocol": 17,
                "focused_workspace_id": "w1",
                "focused_tab_id": "w1:t1",
                "focused_pane_id": "w1:p1",
                "workspaces": [
                  {
                    "workspace_id": "w1",
                    "label": "Shepherd",
                    "number": 1,
                    "focused": true,
                    "pane_count": 1,
                    "tab_count": 1,
                    "active_tab_id": "w1:t1",
                    "agent_status": "blocked"
                  }
                ],
                "tabs": [],
                "panes": [],
                "layouts": [],
                "agents": [
                  {
                    "agent": "codex",
                    "agent_status": "blocked",
                    "pane_id": "w1:p1",
                    "workspace_id": "w1",
                    "tab_id": "w1:t1",
                    "terminal_id": "terminal-1",
                    "focused": true,
                    "revision": 7,
                    "terminal_title_stripped": "Implement protocol 17",
                    "launch_pending": false,
                    "interactive_ready": true,
                    "state_change_seq": 42
                  }
                ]
              }
            }
            """#.utf8
        )

        let result = try makeDecoder().decode(SessionSnapshotResult.self, from: json)

        XCTAssertEqual(Herdr.supportedProtocol, 17)
        XCTAssertEqual(result.snapshot.protocolVersion, Herdr.supportedProtocol)
        XCTAssertEqual(result.snapshot.workspaces.first?.workspaceId, "w1")
        XCTAssertEqual(result.snapshot.agents.first?.paneId, "w1:p1")
        XCTAssertEqual(result.snapshot.agents.first?.terminalId, "terminal-1")
        XCTAssertEqual(result.snapshot.agents.first?.revision, 7)
        XCTAssertEqual(result.snapshot.agents.first?.agentStatus, .blocked)
    }

    func testDecodesProtocol17AgentInfoWithNativeSessionIdentity() throws {
        let json = Data(
            #"""
            {
              "type": "agent_info",
              "agent": {
                "agent": "codex",
                "agent_status": "working",
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "terminal_id": "terminal-1",
                "revision": 17,
                "state_change_seq": 9,
                "agent_session": {
                  "source": "herdr:codex",
                  "agent": "codex",
                  "kind": "id",
                  "value": "session-abc"
                },
                "unknown_protocol_field": true
              }
            }
            """#.utf8
        )

        let result = try makeDecoder().decode(AgentGetResult.self, from: json)

        XCTAssertEqual(result.agent.agent, "codex")
        XCTAssertEqual(result.agent.agentStatus, .working)
        XCTAssertEqual(result.agent.paneId, "w1:p1")
        XCTAssertEqual(result.agent.workspaceId, "w1")
        XCTAssertEqual(result.agent.tabId, "w1:t1")
        XCTAssertEqual(result.agent.terminalId, "terminal-1")
        XCTAssertEqual(result.agent.revision, 17)
        XCTAssertEqual(result.agent.stateChangeSeq, 9)
        XCTAssertEqual(
            result.agent.agentSession,
            HerdrAgentSession(
                source: "herdr:codex",
                agent: "codex",
                kind: .id,
                value: "session-abc"
            )
        )
    }

    func testAgentInfoDefaultsMissingStateChangeSequenceToZero() throws {
        let json = Data(
            #"""
            {
              "type": "agent_info",
              "agent": {
                "agent": null,
                "agent_status": "idle",
                "pane_id": "w2:p3",
                "workspace_id": "w2",
                "tab_id": "w2:t2",
                "terminal_id": "terminal-2",
                "revision": 22
              }
            }
            """#.utf8
        )

        let result = try makeDecoder().decode(AgentGetResult.self, from: json)

        XCTAssertNil(result.agent.agent)
        XCTAssertEqual(result.agent.stateChangeSeq, 0)
        XCTAssertNil(result.agent.agentSession)
    }

    func testDecodesProtocol17PaneReadResult() throws {
        let json = Data(
            #"""
            {
              "type": "pane_read",
              "read": {
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "source": "visible",
                "format": "text",
                "text": "Implementing the preview\n",
                "revision": 9007199254740993,
                "truncated": false
              }
            }
            """#.utf8
        )

        let result = try makeDecoder().decode(AgentReadResult.self, from: json)

        XCTAssertEqual(result.read.paneId, "w1:p1")
        XCTAssertEqual(result.read.workspaceId, "w1")
        XCTAssertEqual(result.read.tabId, "w1:t1")
        XCTAssertEqual(result.read.source, .visible)
        XCTAssertEqual(result.read.format, .text)
        XCTAssertEqual(result.read.text, "Implementing the preview\n")
        XCTAssertEqual(result.read.revision, 9_007_199_254_740_993)
        XCTAssertFalse(result.read.truncated)
    }

    func testLiveAgentReadDataSourcePinsSocketAndSendsExactRequestOptions() async throws {
        let server = try TestAgentReadRPCServer(
            resultBodies: [
                agentInfoResult(status: "working", revision: 30, stateChangeSequence: 4),
                [
                    "type": "pane_read",
                    "read": [
                        "pane_id": "w1:p1",
                        "workspace_id": "w1",
                        "tab_id": "w1:t1",
                        "source": "visible",
                        "format": "text",
                        "text": "Reading the current screen",
                        "revision": 31,
                        "truncated": false,
                    ],
                ],
                agentInfoResult(status: "idle", revision: 31, stateChangeSequence: 5),
            ]
        )
        async let receivedRequests = server.serveAll()
        let dataSource = AgentReadDataSource.live(socketPath: server.socketPath)

        let before = try await dataSource.get("w1:p1")
        let read = try await dataSource.readVisible("w1:p1")
        let after = try await dataSource.get("w1:p1")
        let requests = try await receivedRequests

        XCTAssertEqual(before.agent.agentStatus, .working)
        XCTAssertEqual(read.read.text, "Reading the current screen")
        XCTAssertEqual(after.agent.agentStatus, .idle)

        XCTAssertEqual(requests.count, 3)
        assertGetRequest(requests[0], target: "w1:p1")
        let readObject = try requestObject(requests[1])
        let readParameters = try XCTUnwrap(readObject["params"] as? [String: Any])
        XCTAssertEqual(readObject["method"] as? String, "agent.read")
        XCTAssertEqual(
            Set(readParameters.keys),
            Set(["target", "source", "format", "strip_ansi"])
        )
        XCTAssertEqual(readParameters["target"] as? String, "w1:p1")
        XCTAssertEqual(readParameters["source"] as? String, "visible")
        XCTAssertEqual(readParameters["format"] as? String, "text")
        XCTAssertEqual(readParameters["strip_ansi"] as? Bool, true)
        assertGetRequest(requests[2], target: "w1:p1")
    }

    private func assertGetRequest(
        _ data: Data,
        target: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        do {
            let object = try requestObject(data)
            let parameters = try XCTUnwrap(
                object["params"] as? [String: Any],
                file: file,
                line: line
            )
            XCTAssertEqual(object["method"] as? String, "agent.get", file: file, line: line)
            XCTAssertEqual(Set(parameters.keys), Set(["target"]), file: file, line: line)
            XCTAssertEqual(parameters["target"] as? String, target, file: file, line: line)
        } catch {
            XCTFail("Could not decode agent.get request: \(error)", file: file, line: line)
        }
    }

    private func requestObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func agentInfoResult(
        status: String,
        revision: UInt64,
        stateChangeSequence: UInt64
    ) -> [String: Any] {
        [
            "type": "agent_info",
            "agent": [
                "agent": "codex",
                "agent_status": status,
                "pane_id": "w1:p1",
                "workspace_id": "w1",
                "tab_id": "w1:t1",
                "terminal_id": "terminal-1",
                "revision": revision,
                "state_change_seq": stateChangeSequence,
            ],
        ]
    }
}

private enum AgentReadProtocolTestError: Error {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case accept(Int32)
    case read(Int32)
    case connectionClosed
    case requestTooLarge
    case write(Int32)
}

/// Scripted Unix socket server that records each one-shot Herdr RPC request.
private final class TestAgentReadRPCServer: @unchecked Sendable {
    let socketPath: String

    private let serverFileDescriptor: Int32
    private let responses: [Data]

    init(resultBodies: [[String: Any]]) throws {
        responses = try resultBodies.enumerated().map { index, result in
            var response = try JSONSerialization.data(
                withJSONObject: [
                    "id": "test-agent-read-\(index)",
                    "result": result,
                ]
            )
            response.append(0x0A)
            return response
        }

        socketPath = "/tmp/shepherd-agent-read-\(UUID().uuidString.prefix(12)).sock"
        _ = unlink(socketPath)

        let fileDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fileDescriptor >= 0 else {
            throw AgentReadProtocolTestError.socket(errno)
        }
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
            throw AgentReadProtocolTestError.bind(errno)
        }
        guard Darwin.listen(fileDescriptor, 1) == 0 else {
            Darwin.close(fileDescriptor)
            _ = unlink(socketPath)
            throw AgentReadProtocolTestError.listen(errno)
        }
    }

    deinit {
        Darwin.close(serverFileDescriptor)
        _ = unlink(socketPath)
    }

    func serveAll() async throws -> [Data] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    continuation.resume(returning: try serveAllSync())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func serveAllSync() throws -> [Data] {
        var requests: [Data] = []
        for response in responses {
            let client = Darwin.accept(serverFileDescriptor, nil, nil)
            guard client >= 0 else {
                throw AgentReadProtocolTestError.accept(errno)
            }
            defer { Darwin.close(client) }

            requests.append(try readRequest(from: client))
            try write(response, to: client)
        }
        return requests
    }

    private func readRequest(from client: Int32) throws -> Data {
        var request = Data()
        while request.firstIndex(of: 0x0A) == nil {
            var byte: UInt8 = 0
            let count = Darwin.read(client, &byte, 1)
            guard count >= 0 else {
                throw AgentReadProtocolTestError.read(errno)
            }
            guard count > 0 else {
                throw AgentReadProtocolTestError.connectionClosed
            }
            request.append(byte)
            guard request.count <= 4096 else {
                throw AgentReadProtocolTestError.requestTooLarge
            }
        }

        let newline = request.firstIndex(of: 0x0A)!
        return Data(request[..<newline])
    }

    private func write(_ response: Data, to client: Int32) throws {
        try response.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    client,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                guard count > 0 else {
                    throw AgentReadProtocolTestError.write(errno)
                }
                offset += count
            }
        }
    }
}
