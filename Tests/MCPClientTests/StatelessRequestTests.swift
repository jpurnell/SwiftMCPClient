import Foundation
import Testing
import MCP
@testable import MCPClient

/// Talking to a server that has no handshake.
///
/// MCP 2026-07-28 made the protocol stateless: `initialize` and `notifications/initialized` are
/// gone, and every request carries its own protocol version, client identity and capabilities.
/// A client does not *negotiate* a version so much as declare one and find out.
@Suite("Stateless requests")
struct StatelessRequestTests {

    /// No handshake is sent. That is the whole point of the revision, and a client that sent
    /// one anyway would be asking a stateless server for a method it removed.
    @Test("Beginning statelessly sends no initialize")
    func noHandshake() async throws {
        let transport = StatelessStubTransport()
        let connection = MCPClientConnection(transport: transport)

        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")
        _ = try? await connection.listTools()

        #expect(await transport.methodsSent.contains("initialize") == false)
        #expect(await transport.methodsSent.contains("tools/list"))
    }

    /// The declared version reaches the wire the same way a negotiated one does — in `_meta`,
    /// and therefore in the header the transport mirrors from it.
    @Test("The declared version travels on every request")
    func declaredVersionTravels() async throws {
        let transport = StatelessStubTransport()
        let connection = MCPClientConnection(transport: transport)

        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")
        _ = try? await connection.listTools()

        let meta = try #require(statelessMeta(of: await transport.lastRequest))
        #expect(meta["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28")
        #expect((meta["io.modelcontextprotocol/clientInfo"] as? [String: Any])?["name"] as? String == "probe")
    }
}

/// Reading a result the way 2026-07-28 requires.
@Suite("Result types")
struct ResultTypeTests {

    /// A result tagged `complete` is the ordinary case and comes back as content.
    @Test("A complete result is returned")
    func completeResult() async throws {
        let transport = StatelessStubTransport(resultType: "complete")
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        let tools = try await connection.listTools()

        #expect(tools.isEmpty)
    }

    /// **The compatibility rule.** A server on an earlier revision omits the field entirely, and
    /// a client **MUST** read that as `complete`. Reading an absent tag as "unknown" would break
    /// every 2025-era server the moment this client started looking for it.
    @Test("An absent result type means complete")
    func absentResultTypeIsComplete() async throws {
        let transport = StatelessStubTransport(resultType: nil)
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        let tools = try await connection.listTools()

        #expect(tools.isEmpty)
    }

    /// An interim result is not content. A server saying "I need something from you first" that
    /// a client hands back as an answer is the failure this tag exists to prevent — the caller
    /// would act on an empty result as though the work were done.
    @Test("An input-required result is not returned as content")
    func inputRequiredIsNotContent() async throws {
        let transport = StatelessStubTransport(resultType: "input_required")
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        await #expect(throws: (any Error).self) {
            _ = try await connection.listTools()
        }
    }
}

/// What a server says when it cannot speak the version it was offered.
@Suite("Unsupported protocol version")
struct UnsupportedVersionTests {

    /// The error a stateless client must be able to read, because without a handshake it is the
    /// only way to learn what a server *does* speak. The supported list travels in the error's
    /// `data`, and a client that cannot reach it has no way to pick a version and retry.
    @Test("The server's supported versions are readable from the error")
    func supportedVersionsAreReadable() async throws {
        let transport = UnsupportedVersionTransport(supported: ["2025-11-25", "2026-07-28"])
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2030-01-01", clientName: "probe", clientVersion: "1.0")

        do {
            _ = try await connection.listTools()
            Issue.record("a version the server rejected was treated as usable")
        } catch let error as MCPClient.MCPError {
            let versions = MCPClientConnection.supportedVersions(from: error)
            #expect(versions == ["2025-11-25", "2026-07-28"])
        }
    }

    /// A refusal that names no versions is still a refusal. Returning an empty list rather than
    /// nothing keeps a caller from mistaking "the server did not say" for "the server supports
    /// none", which are different problems.
    @Test("A refusal with no list yields no versions rather than a failure")
    func refusalWithoutAList() async throws {
        let transport = UnsupportedVersionTransport(supported: nil)
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2030-01-01", clientName: "probe", clientVersion: "1.0")

        do {
            _ = try await connection.listTools()
            Issue.record("a version the server rejected was treated as usable")
        } catch let error as MCPClient.MCPError {
            #expect(MCPClientConnection.supportedVersions(from: error).isEmpty)
        }
    }
}

// MARK: - Helpers

/// A transport that answers any request with an empty tool list, tagged as asked.
private actor StatelessStubTransport: MCPTransport {

    private let resultType: String?
    private var pending: [Data] = []
    private(set) var methodsSent: [String] = []
    private(set) var lastRequest: Data?

    init(resultType: String? = "complete") {
        self.resultType = resultType
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        if let method = object["method"] as? String { methodsSent.append(method) }
        lastRequest = data

        guard let id = object["id"] else { return }
        var result: [String: Any] = ["tools": [Any]()]
        if let resultType { result["resultType"] = resultType }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        pending.append(try JSONSerialization.data(withJSONObject: response))
    }

    func receive() async throws -> Data {
        try await waitForMessage()
    }

    /// Suspends until something is queued, as a real transport does.
    ///
    /// Throwing on an empty queue would end the message dispatcher the moment it starts — it
    /// loops on `receive()` — and every later response would go undelivered, which presents as
    /// a request that hangs rather than a transport that failed.
    private func waitForMessage() async throws -> Data {
        for _ in 0..<200 {
            if !pending.isEmpty { return pending.removeFirst() }
            // silent: a cancelled sleep ends the wait, and the throw below reports it
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw MCPClient.MCPError.connectionFailed(reason: "nothing queued")
    }
}

/// A transport that refuses every request with `-32022`.
private actor UnsupportedVersionTransport: MCPTransport {

    private let supported: [String]?
    private var pending: [Data] = []

    init(supported: [String]?) {
        self.supported = supported
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        var error: [String: Any] = [
            "code": -32022,
            "message": "Unsupported protocol version"
        ]
        if let supported { error["data"] = ["supported": supported] }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "error": error]
        pending.append(try JSONSerialization.data(withJSONObject: response))
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

/// The `_meta` of a recorded request, parsed outside the actor that captured it.
private func statelessMeta(of data: Data?) -> [String: Any]? {
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let params = object["params"] as? [String: Any] else {
        return nil
    }
    return params["_meta"] as? [String: Any]
}
