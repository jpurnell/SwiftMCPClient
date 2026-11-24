import Foundation
import Testing
@testable import MCPClient

/// A transport that takes every message and never produces one — and, like the real ones,
/// does not notice that the task waiting on it was cancelled. Disconnecting it is what ends
/// a wait.
actor SilentTransport: MCPTransport {
    private var waiting: [CheckedContinuation<Data, any Error>] = []
    private var answers: [Data]
    private(set) var disconnects = 0

    /// - Parameter answers: Messages to hand out first, in order, before going silent.
    init(answering answers: [String] = []) {
        self.answers = answers.map { Data($0.utf8) }
    }

    func connect() async throws {}

    func disconnect() async throws {
        disconnects += 1
        for continuation in waiting {
            continuation.resume(throwing: MCPError.connectionFailed(reason: "Disconnected"))
        }
        waiting.removeAll()
    }

    func send(_ data: Data) async throws {}

    func receive() async throws -> Data {
        if !answers.isEmpty { return answers.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }
}

/// How long a request waits for its answer.
///
/// `MCPClientConnection` has a `requestTimeout`, and applied it to every request but the
/// first. `initialize` reads its answer straight from the transport — the dispatcher is not
/// running yet — and that read had no limit: a server that accepted the handshake and said
/// nothing left `initialize` waiting for ever.
@Suite("Requests have a deadline")
struct RequestDeadlineTests {

    static let initialized = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"stub","version":"1"}}}"#

    @Test("initialize fails with timeout when the server never answers", .timeLimit(.minutes(1)))
    func initializeTimesOut() async throws {
        let transport = SilentTransport()
        let connection = MCPClientConnection(transport: transport, requestTimeout: .milliseconds(200))
        await #expect(throws: MCPError.timeout) {
            _ = try await connection.initialize(clientName: "test", clientVersion: "1")
        }
        // The handshake failed, so the transport is released — which is also what ends the
        // read that was abandoned.
        #expect(await transport.disconnects == 1)
    }

    @Test("initialize over a real stream fails with timeout when the server accepts and stays silent",
          .timeLimit(.minutes(1)))
    func initializeTimesOutOnTheWire() async throws {
        // The stream opens and names its endpoint; the POST is accepted; nothing follows.
        let server = try await FaultStubServer.start(.byMethod(
            get: ResponseLimitWireTests.legacyStream,
            other: "HTTP/1.1 202 Accepted\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"))
        let transport = HTTPSSETransport(
            url: try await server.url(path: "/sse"), connectionTimeout: 5, maxReconnectAttempts: 0)
        let connection = MCPClientConnection(transport: transport, requestTimeout: .milliseconds(300))
        await #expect(throws: MCPError.timeout) {
            _ = try await connection.initialize(clientName: "test", clientVersion: "1")
        }
        await server.stop()
    }

    @Test("A later request fails with timeout when its answer never comes", .timeLimit(.minutes(1)))
    func laterRequestTimesOut() async throws {
        let transport = SilentTransport(answering: [Self.initialized])
        let connection = MCPClientConnection(transport: transport, requestTimeout: .milliseconds(200))
        _ = try await connection.initialize(clientName: "test", clientVersion: "1")
        await #expect(throws: MCPError.timeout) {
            _ = try await connection.ping()
        }
        try await connection.disconnect()
    }

    @Test("An answer that arrives in time is returned", .timeLimit(.minutes(1)))
    func answeredInTime() async throws {
        let transport = SilentTransport(answering: [Self.initialized])
        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(30))
        let result = try await connection.initialize(clientName: "test", clientVersion: "1")
        #expect(result.protocolVersion == "2024-11-05")
        try await connection.disconnect()
    }
}

/// `HTTPSSETransport.connect()` waits for the server's `endpoint` event, and its
/// `connectionTimeout` is documented as the limit on that wait. It bounded the response
/// head only: a server that opened the stream and never named an endpoint held `connect()`
/// for ever.
@Suite("Legacy HTTP+SSE — connect() has a deadline")
struct LegacyConnectDeadlineTests {

    @Test("A stream that opens and never names an endpoint fails connect() at the deadline",
          .timeLimit(.minutes(1)))
    func endpointNeverArrives() async throws {
        // A head, a comment line to show the stream is alive, and then nothing.
        let server = try await FaultStubServer.start(.byMethod(
            get: "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n: waiting\n\n", other: ""))
        let transport = HTTPSSETransport(
            url: try await server.url(path: "/sse", query: "key=fixture-key-do-not-log"),
            connectionTimeout: 1.5, maxReconnectAttempts: 0)
        var caught: (any Error)?
        do {
            try await transport.connect()
        } catch {
            caught = error
        }
        guard case .connectionFailed(let reason) = caught as? MCPError else {
            Issue.record("expected MCPError.connectionFailed, got \(String(describing: caught))")
            return
        }
        #expect(reason.hasPrefix("Could not reach http://127.0.0.1:\(try await server.port): "), "\(reason)")
        #expect(reason.contains("endpoint event"), "\(reason)")
        #expect(!reason.contains("fixture-key-do-not-log") && !reason.contains("/sse"), "\(reason)")
        try await transport.disconnect()
        await server.stop()
    }
}
