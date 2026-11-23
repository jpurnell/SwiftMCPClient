import Foundation
import NIOHTTP1
import Testing
@testable import MCPClient

/// A refusal that arrives as a real non-2xx HTTP response, with the JSON-RPC error in its body.
///
/// SwiftMCPServer refuses an unsupported protocol revision with `400` and a JSON-RPC error body
/// naming `-32022` and the revisions it does speak. The transport used to throw on the status
/// and never read the body, so the code the era decision turns on arrived as `400` and the
/// list of versions never arrived at all. The stub transports in the other suites deliver
/// `-32022` as a JSON-RPC *message*, which is a different path and never exercised this one.
@Suite("HTTP error bodies", .serialized)
struct HTTPErrorBodyTests {

    static let serverVersions = ["2026-07-28", "2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    /// The body SwiftMCPServer sends (MCPWire.swift) for an unsupported revision.
    static func refusalBody(id: Int = 1, requested: String = "2099-01-01") -> String {
        let supported = serverVersions.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32022,"message":"Unsupported protocol version '\#(requested)'","data":{"requested":"\#(requested)","supported":[\#(supported)]}}}"#
    }

    private static let request = Data(#"{"jsonrpc":"2.0","id":1,"method":"server/discover"}"#.utf8)

    // MARK: - The transport

    @Test("A 400 carrying -32022 surfaces the JSON-RPC code, message and data", .timeLimit(.minutes(1)))
    func refusalSurfacesJSONRPCError() async throws {
        let reply = StubHTTPServer.Reply(status: .badRequest, body: Self.refusalBody())
        try await withStub(replies: [reply]) { transport, _ in
            do {
                try await transport.send(Self.request)
                Issue.record("a 400 was not thrown")
            } catch MCPError.requestFailed(let code, let message, let data) {
                #expect(code == -32022)
                #expect(message == "Unsupported protocol version '2099-01-01'")
                #expect(MCPClientConnection.supportedVersions(
                    from: .requestFailed(code: code, message: message, data: data)) == Self.serverVersions)
            }
        }
    }

    @Test("A 404 carrying -32601 surfaces -32601, still an old-server signal", .timeLimit(.minutes(1)))
    func methodNotFoundSurfaces() async throws {
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"Method not found"}}"#
        try await withStub(replies: [.init(status: .notFound, body: body)]) { transport, _ in
            do {
                try await transport.send(Self.request)
                Issue.record("a 404 was not thrown")
            } catch MCPError.requestFailed(let code, _, _) {
                #expect(code == -32601)
                #expect(MCPClientConnection.era(forRefusalCode: code) == .handshake)
            }
        }
    }

    @Test("A non-2xx body that is not a JSON-RPC error keeps the HTTP status", .timeLimit(.minutes(1)))
    func nonJSONRPCBodyKeepsStatus() async throws {
        let bodies = [
            "<html>Bad Gateway</html>",
            #"{"error":"invalid_token"}"#,
            #"{"jsonrpc":"1.0","id":1,"error":{"code":-32022,"message":"x"}}"#,
            #"{"jsonrpc":"2.0","id":1,"error":{"code":"-32022","message":"x"}}"#,
            #"{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":7}}"#
        ]
        for body in bodies {
            try await withStub(replies: [.init(status: .badRequest, body: body)]) { transport, _ in
                do {
                    try await transport.send(Self.request)
                    Issue.record("a 400 was not thrown")
                } catch MCPError.requestFailed(let code, let message, let data) {
                    #expect(code == 400, "body \(body)")
                    #expect(message.hasPrefix("HTTP 400 from POST"))
                    #expect(data == nil)
                }
            }
        }
    }

    @Test("A 401 with a non-JSON-RPC body is unchanged", .timeLimit(.minutes(1)))
    func unauthorizedWithPlainBodyUnchanged() async throws {
        try await withStub(replies: [.unauthorized()]) { transport, server in
            do {
                try await transport.send(Self.request)
                Issue.record("a 401 was not thrown")
            } catch MCPError.requestFailed(let code, let message, let data) {
                #expect(code == 401)
                #expect(message.hasPrefix("HTTP 401 from POST"))
                #expect(data == nil)
            }
            #expect(await server.received.count == 1)
        }
    }

    @Test("A 5xx with a JSON-RPC body surfaces it; one without keeps the status", .timeLimit(.minutes(1)))
    func serverErrorBodies() async throws {
        let rpc = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"Internal error"}}"#
        try await withStub(replies: [.init(status: .internalServerError, body: rpc)]) { transport, _ in
            await #expect(throws: MCPError.self) { try await transport.send(Self.request) }
            do { try await transport.send(Self.request) } catch MCPError.requestFailed(let code, let message, _) {
                #expect(code == -32603)
                #expect(message == "Internal error")
            }
        }
        try await withStub(replies: [.init(status: .internalServerError, body: "oops")]) { transport, _ in
            do { try await transport.send(Self.request) } catch MCPError.requestFailed(let code, _, _) {
                #expect(code == 500)
            }
        }
    }

    @Test("An oversized error body is not read without bound; the HTTP status is kept", .timeLimit(.minutes(1)))
    func oversizedBodyKeepsStatus() async throws {
        // Valid JSON-RPC error, padded past the bound: reading it all would be the unbounded read.
        let padding = String(repeating: "a", count: 200_000)
        let body = #"{"jsonrpc":"2.0","id":1,"error":{"code":-32022,"message":"\#(padding)"}}"#
        try await withStub(replies: [.init(status: .badRequest, body: body)]) { transport, _ in
            do {
                try await transport.send(Self.request)
                Issue.record("a 400 was not thrown")
            } catch MCPError.requestFailed(let code, _, _) {
                #expect(code == 400)
            }
        }
    }

    // MARK: - The connection and the factory

    @Test("supportedVersions(from:) reads the versions from a real HTTP 400", .timeLimit(.minutes(1)))
    func connectionReadsVersionsFromRealRefusal() async throws {
        let server = try await StubHTTPServer.start(replies: [], responder: Self.serverResponder)
        let transport = StreamableHTTPTransport(url: try await server.url)
        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(10))
        try await connection.beginStateless(
            protocolVersion: "2099-01-01", clientName: "probe", clientVersion: "1.0")
        do {
            _ = try await connection.discoverServer()
            Issue.record("the refusal was not thrown")
        } catch let error as MCPError {
            #expect(MCPClientConnection.supportedVersions(from: error) == Self.serverVersions)
        }
        try await connection.disconnect()
        await server.stop()
    }

    @Test("The factory connects at the newest mutual revision after a real 400 refusal",
          .timeLimit(.minutes(1)))
    func factoryCorrectsFromRealRefusal() async throws {
        let server = try await StubHTTPServer.start(replies: [], responder: Self.serverResponder)
        let transport = StreamableHTTPTransport(url: try await server.url)
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0",
            requestTimeout: .seconds(10), preferred: "2099-01-01")

        #expect(connected.era == .stateless)
        #expect(connected.protocolVersion == "2026-07-28")

        _ = try await connected.connection.listTools()
        let received = await server.received
        #expect(received.first?.method == "server/discover")
        #expect(received.contains { $0.method == "initialize" } == false,
                "initialize was sent to a server that had answered the refusal")
        let later = received.dropFirst()
        #expect(later.isEmpty == false)
        #expect(later.allSatisfy { $0.protocolVersion == "2026-07-28" },
                "later requests did not carry the mutual revision: \(later.map { $0.protocolVersion ?? "nil" })")

        try await connected.connection.disconnect()
        await server.stop()
    }

    @Test("A 404 with -32601 for server/discover still falls back to the handshake",
          .timeLimit(.minutes(1)))
    func oldServerStillFallsBack() async throws {
        let server = try await StubHTTPServer.start(replies: [], responder: { request in
            let id = Self.requestID(request.body)
            switch Self.methodName(request.body) {
            case "initialize":
                return .ok(#"{"jsonrpc":"2.0","id":\#(id),"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"old","version":"1"}}}"#)
            case "server/discover":
                return .init(status: .notFound,
                             body: #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"Method not found"}}"#)
            default:
                return .ok(#"{"jsonrpc":"2.0","id":\#(id),"result":{}}"#)
            }
        })
        let transport = StreamableHTTPTransport(url: try await server.url)
        let connected = try await MCPConnectionFactory.connect(
            transport: transport, clientName: "probe", clientVersion: "1.0",
            requestTimeout: .seconds(10))

        #expect(connected.era == .handshake)
        #expect(connected.protocolVersion == "2025-06-18")
        let methods = await server.received.map { $0.method ?? Self.methodName($0.body) }
        #expect(methods.prefix(2) == ["server/discover", "initialize"])

        try await connected.connection.disconnect()
        await server.stop()
    }

    // MARK: - A server that behaves like SwiftMCPServer

    /// Refuses any declared revision it does not speak with a real `400`; answers the rest.
    /// `initialize` is answered `404` because a 2026-07-28 server removed it.
    static let serverResponder: @Sendable (StubHTTPServer.Received) -> StubHTTPServer.Reply = { request in
        let id = requestID(request.body)
        let method = methodName(request.body)
        guard method != "initialize" else {
            return .init(status: .notFound,
                         body: #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32601,"message":"Method not found"}}"#)
        }
        if let declared = request.protocolVersion, !serverVersions.contains(declared) {
            return .init(status: .badRequest, body: refusalBody(id: id, requested: declared))
        }
        if let declared = declaredInBody(request.body), !serverVersions.contains(declared) {
            return .init(status: .badRequest, body: refusalBody(id: id, requested: declared))
        }
        return .ok(#"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[],"supportedVersions":["2026-07-28"],"capabilities":{},"resultType":"complete"}}"#)
    }

    static func requestID(_ body: String) -> Int {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        return object?["id"] as? Int ?? 0
    }

    static func methodName(_ body: String) -> String {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        return object?["method"] as? String ?? ""
    }

    static func declaredInBody(_ body: String) -> String? {
        let object = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let params = object?["params"] as? [String: Any]
        let meta = params?["_meta"] as? [String: Any]
        return meta?.compactMap { $0.key.hasSuffix("protocolVersion") ? $0.value as? String : nil }.first
    }
}
