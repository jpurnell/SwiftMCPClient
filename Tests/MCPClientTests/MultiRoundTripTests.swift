import Foundation
import Testing
import MCP
@testable import MCPClient

/// Multi Round-Trip Requests: how a server asks the client for something.
///
/// Before 2026-07-28 a server sent its own JSON-RPC request — sampling, elicitation, roots —
/// over an open stream. The stateless revision removed that: a server returns an
/// `InputRequiredResult` naming what it needs, and **the client retries the original request**
/// with the answers attached. The retry *is* the continuation, which is what keeps the exchange
/// stateless.
///
/// Two things make or break it. The answers are keyed by the server's own identifiers — that
/// correspondence is the only thing tying an answer to its question. And `requestState` is
/// opaque and must come back unmodified; it is how the server avoids redoing work it has
/// already done.
@Suite("Multi round-trip requests")
struct MultiRoundTripTests {

    /// The whole exchange: asked, answered, finished.
    @Test("An input request is answered by retrying the original request", .timeLimit(.minutes(1)))
    func retriesWithAnswers() async throws {
        let transport = MRTRStubTransport()
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        let result = try await connection.callToolFulfillingInput(
            name: "ask", arguments: nil
        ) { requests in
            // One answer per question, under the server's own keys.
            requests.mapValues { _ in InputResponse.listRoots(ListRoots.Result(roots: [])) }
        }

        // The final result is content, not another question — which is what distinguishes a
        // completed exchange from one that merely stopped.
        #expect(MCPClientConnection.isInterim(result) == false)
        #expect(await transport.attempts == 2, "the request was not retried")
    }

    /// The retry carries the server's opaque state back untouched. Losing it makes the server
    /// start again, which is the cost this field exists to avoid.
    @Test("The retry echoes requestState unmodified", .timeLimit(.minutes(1)))
    func echoesRequestState() async throws {
        let transport = MRTRStubTransport(requestState: "server-side-token")
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        _ = try await connection.callToolFulfillingInput(name: "ask", arguments: nil) { requests in
            requests.mapValues { _ in InputResponse.listRoots(ListRoots.Result(roots: [])) }
        }

        #expect(await transport.lastRequestState == "server-side-token")
    }

    /// A client that cannot answer says so by answering nothing, and the exchange stops rather
    /// than retrying forever with the same gap.
    @Test("Answering nothing ends the exchange", .timeLimit(.minutes(1)))
    func unansweredEndsTheExchange() async throws {
        let transport = MRTRStubTransport()
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        await #expect(throws: (any Error).self) {
            _ = try await connection.callToolFulfillingInput(name: "ask", arguments: nil) { _ in
                [:]
            }
        }
        #expect(await transport.attempts == 1, "a request with no answers was retried anyway")
    }

    /// A bound, so a server that keeps asking cannot loop a client indefinitely.
    @Test("Rounds are bounded", .timeLimit(.minutes(1)))
    func roundsAreBounded() async throws {
        let transport = MRTRStubTransport(alwaysAsks: true)
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        await #expect(throws: (any Error).self) {
            _ = try await connection.callToolFulfillingInput(
                name: "ask", arguments: nil, maximumRounds: 3
            ) { requests in
                requests.mapValues { _ in InputResponse.listRoots(ListRoots.Result(roots: [])) }
            }
        }
        #expect(await transport.attempts == 3)
    }
}

/// Asks for input once — or forever — and then completes.
private actor MRTRStubTransport: MCPTransport {

    private let requestState: String?
    private let alwaysAsks: Bool
    private var pending: [Data] = []
    private(set) var attempts = 0
    private(set) var lastRequestState: String?

    init(requestState: String? = nil, alwaysAsks: Bool = false) {
        self.requestState = requestState
        self.alwaysAsks = alwaysAsks
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        attempts += 1

        let params = object["params"] as? [String: Any]
        lastRequestState = params?["requestState"] as? String

        let result: [String: Any]
        if alwaysAsks || attempts == 1 {
            var interim: [String: Any] = [
                "resultType": "input_required",
                "inputRequests": ["ask-1": ["method": "roots/list", "params": [String: Any]()]]
            ]
            if let requestState { interim["requestState"] = requestState }
            result = interim
        } else {
            result = ["resultType": "complete", "content": [Any]()]
        }
        pending.append(try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
    }

    func receive() async throws -> Data {
        for _ in 0..<200 {
            if !pending.isEmpty { return pending.removeFirst() }
            // silent: a cancelled sleep ends the wait, and the throw below reports it
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw MCPClient.MCPError.connectionFailed(reason: "nothing queued")
    }
}
