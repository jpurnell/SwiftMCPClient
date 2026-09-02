import Foundation
import Testing
import MCP
@testable import MCPClient

/// Mirroring annotated tool parameters into headers, and refusing tools that annotate badly.
///
/// A server **MAY** mark tool parameters with `x-mcp-header`, and a conforming client **MUST**
/// mirror those values into `Mcp-Param-{Name}` headers so intermediaries can route on them.
/// The client **MUST** also reject a tool whose annotations break the rules — excluding it from
/// `tools/list` rather than refusing the whole listing, so one malformed definition does not
/// cost a server every other tool it offers.
@Suite("x-mcp-header")
struct XMCPHeaderTests {

    /// A well-annotated tool survives listing, and its annotation is understood.
    @Test("A valid annotation is kept")
    func validAnnotationKept() async throws {
        let transport = ToolListingTransport(tools: [
            toolJSON(name: "execute_sql", annotated: ["region": "Region"])
        ])
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        let tools = try await connection.listTools()

        #expect(tools.map(\.name) == ["execute_sql"])
    }

    /// A tool whose annotation is not a valid header name is excluded — and only that tool.
    /// Failing the listing would let one bad definition deny a client every tool on the server.
    @Test("An invalid annotation costs only its own tool")
    func invalidAnnotationExcludesOnlyThatTool() async throws {
        let transport = ToolListingTransport(tools: [
            toolJSON(name: "good", annotated: ["region": "Region"]),
            toolJSON(name: "bad", annotated: ["region": "Not A Header"])
        ])
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        let tools = try await connection.listTools()

        #expect(tools.map(\.name) == ["good"], "a malformed annotation cost the whole listing")
    }

    /// The values reach the wire, under the header the annotation named.
    @Test("An annotated argument is mirrored into a header", .timeLimit(.minutes(1)))
    func mirrorsAnnotatedArgument() async throws {
        let seen = try await withStub(replies: [.ok("{}")]) { transport, server in
            await transport.didNegotiate(protocolVersion: "2026-07-28")
            await transport.useParameterHeaders(["execute_sql": ["region": "Region"]])
            try await transport.send(Data("""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execute_sql",\
            "arguments":{"region":"us-west1","query":"SELECT 1"}}}
            """.utf8))
            _ = try await transport.receive()
            return await server.received.last?.parameterHeaders
        }

        #expect(seen?["Mcp-Param-Region"] == "us-west1")
        #expect(seen?["Mcp-Param-Query"] == nil, "an unannotated argument was mirrored")
    }

    /// An argument the call omits sends no header. An empty one is a value, and the server
    /// compares headers against the body.
    @Test("An absent argument sends no header", .timeLimit(.minutes(1)))
    func absentArgumentSendsNoHeader() async throws {
        let seen = try await withStub(replies: [.ok("{}")]) { transport, server in
            await transport.didNegotiate(protocolVersion: "2026-07-28")
            await transport.useParameterHeaders(["execute_sql": ["region": "Region"]])
            try await transport.send(Data(
                #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"execute_sql","arguments":{}}}"#.utf8))
            _ = try await transport.receive()
            return await server.received.last?.parameterHeaders
        }

        #expect(seen?.isEmpty == true)
    }

    /// A value that cannot travel as plain ASCII goes in the sentinel, exactly as `Mcp-Name`
    /// does — the server decodes before comparing.
    @Test("An awkward value is encoded", .timeLimit(.minutes(1)))
    func awkwardValueIsEncoded() async throws {
        let seen = try await withStub(replies: [.ok("{}")]) { transport, server in
            await transport.didNegotiate(protocolVersion: "2026-07-28")
            await transport.useParameterHeaders(["greet": ["greeting": "Greeting"]])
            try await transport.send(Data("""
            {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"greet",\
            "arguments":{"greeting":"Hello, 世界"}}}
            """.utf8))
            _ = try await transport.receive()
            return await server.received.last?.parameterHeaders
        }

        let header = try #require(seen?["Mcp-Param-Greeting"])
        #expect(MCPHeaderValue.decode(header) == "Hello, 世界")
    }
}

// MARK: - Helpers

/// A tool definition with the given parameters annotated for header mirroring.
private func toolJSON(name: String, annotated: [String: String]) -> [String: Any] {
    var properties: [String: Any] = ["query": ["type": "string"]]
    for (parameter, header) in annotated {
        properties[parameter] = ["type": "string", "x-mcp-header": header]
    }
    return [
        "name": name,
        "description": "a tool",
        "inputSchema": ["type": "object", "properties": properties]
    ]
}

/// Answers `tools/list` with the given definitions.
private actor ToolListingTransport: MCPTransport {

    private let tools: [[String: Any]]
    private var pending: [Data] = []

    init(tools: [[String: Any]]) {
        self.tools = tools
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        let result: [String: Any] = ["tools": tools, "resultType": "complete"]
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
