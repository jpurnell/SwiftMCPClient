import Foundation
import Testing
import AsyncHTTPClient
@testable import MCPClient

/// The client against an independent implementation of the same specification.
///
/// Every other test in this suite checks our client against our own idea of what a server
/// does — a stub written from the same reading of the same document, by the same author, on
/// the same day. That catches mistakes in the code and not in the reading.
///
/// This one runs against `@modelcontextprotocol/server-everything`, the reference server
/// published by the specification's authors. It is the only thing here that can disagree with
/// us about what the specification means.
///
/// It matters most for the server-initiated `GET` channel. Apollo answers that with `405`, so
/// the largest piece of Streamable HTTP Phase 2 had never run against anything but a stub.
///
/// **Opt in explicitly**, after starting the server:
///
/// ```
/// npx -y @modelcontextprotocol/server-everything streamableHttp
/// MCP_CONFORMANCE_SERVER=http://127.0.0.1:3001/mcp swift test --filter ConformanceServerTests
/// ```
///
/// Skipped otherwise. It needs a process this suite does not start, so it cannot run
/// unattended — but it costs nothing and needs no account.
@Suite("Conformance — reference server", .serialized, .enabled(if: ConformanceServer.isEnabled))
struct ConformanceServerTests {

    /// The handshake, against a server that frames its answers as SSE with event ids — which
    /// is what the reference implementation does, and what our own stub only asserts we
    /// believe.
    @Test("Initialization and tools/list succeed", .timeLimit(.minutes(1)))
    func handshakeAndTools() async throws {
        let transport = StreamableHTTPTransport(url: try ConformanceServer.url())
        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(30))

        do {
            let info = try await connection.initialize(
                clientName: "SwiftMCPClient conformance", clientVersion: "1.0.0")
            ConformanceServer.report("server: \(info.serverInfo.name) \(info.serverInfo.version)")
            ConformanceServer.report("negotiated: \(info.protocolVersion)")

            let tools = try await connection.listTools()
            ConformanceServer.report("tools: \(tools.count)")
            #expect(!tools.isEmpty)

            // The session the server assigned, carried by our transport rather than assumed.
            //
            // Checked for shape, not merely for presence. The reference server issues UUIDs,
            // and "not nil" would accept a truncated id or a neighbouring header's value —
            // which is not hypothetical: probing this server by hand, a careless header match
            // produced exactly that, and every later request failed in a way that looked like
            // the server's fault.
            let session = try #require(await transport.sessionId,
                                       "the reference server assigns one; we did not keep it")
            ConformanceServer.report("session id: \(session)")
            _ = try #require(UUID(uuidString: session),
                             "kept something that is not the id the server issued: \(session)")

            try await connection.disconnect()
        } catch {
            try? await connection.disconnect()
            throw error
        }
    }

    /// The one that could not be checked before. Apollo refuses the `GET` channel, so until
    /// now the only thing that had ever accepted one was a stub written from the same reading
    /// of the specification as the code it was testing.
    @Test("The server-initiated stream is accepted", .timeLimit(.minutes(1)))
    func serverStreamIsAccepted() async throws {
        let transport = StreamableHTTPTransport(url: try ConformanceServer.url())
        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(30))

        do {
            _ = try await connection.initialize(
                clientName: "SwiftMCPClient conformance", clientVersion: "1.0.0")

            // Proved by asking for a *second* stream. The reference server allows one per
            // session and answers `409 Conflict` for another, so a conflict is the server
            // stating that our stream is open — which nothing observable from inside the
            // client could establish, since a refused GET and an accepted quiet one look
            // identical from here.
            let status = try await ConformanceServer.serverStreamStatus(
                url: try ConformanceServer.url(),
                sessionID: await transport.sessionId)
            ConformanceServer.report("second GET answered \(status) (409 = ours is open)")

            #expect(status == 409,
                    "the server reported no stream already open, so the transport opened none — got \(status)")

            try await connection.disconnect()
        } catch {
            try? await connection.disconnect()
            throw error
        }
    }

    /// The control for the test above, and the assertion that `openServerStream: false` is a
    /// real retreat rather than a flag that changes nothing.
    ///
    /// With no stream of ours open, the same request the server answered `409` is answered
    /// `200` — it hands the stream to the first asker. One test cannot show that; the pair can.
    @Test("With the stream disabled, the server offers it to someone else", .timeLimit(.minutes(1)))
    func disabledLeavesTheStreamFree() async throws {
        let transport = StreamableHTTPTransport(
            url: try ConformanceServer.url(), openServerStream: false)
        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(30))

        do {
            _ = try await connection.initialize(
                clientName: "SwiftMCPClient conformance", clientVersion: "1.0.0")

            let status = try await ConformanceServer.serverStreamStatus(
                url: try ConformanceServer.url(),
                sessionID: await transport.sessionId)
            ConformanceServer.report("with openServerStream false, GET answered \(status)")

            #expect((200...299).contains(status),
                    "the stream was not free, so one was opened despite the flag — got \(status)")

            try await connection.disconnect()
        } catch {
            try? await connection.disconnect()
            throw error
        }
    }
}

/// Support for the conformance run.
enum ConformanceServer {

    /// Whether the reference server has been pointed at.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SERVER"] != nil
    }

    /// Where it is.
    static func url() throws -> URL {
        let string = ProcessInfo.processInfo.environment["MCP_CONFORMANCE_SERVER"]
            ?? "http://127.0.0.1:3001/mcp"
        // SECURITY: a loopback address supplied by whoever opted into this run.
        return try #require(URL(string: string), "MCP_CONFORMANCE_SERVER is not a URL")
    }

    /// Prints a finding.
    static func report(_ message: String) {
        FileHandle.standardError.write(Data("    conformance: \(message)\n".utf8))
    }

    /// Opens the server stream directly and reports the status, without interpretation.
    ///
    /// Uses `AsyncHTTPClient` rather than `URLSession`, because an accepted stream is *held
    /// open with nothing to say* — and `URLSession.bytes` waits for a first byte that may
    /// never come, turning the successful case into a timeout. Here the response head is the
    /// answer, and it arrives immediately either way.
    static func serverStreamStatus(url: URL, sessionID: String?) async throws -> Int {
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        do {
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = .GET
            request.headers.add(name: "Accept", value: "text/event-stream")
            if let sessionID {
                request.headers.add(name: "Mcp-Session-Id", value: sessionID)
            }
            let response = try await client.execute(request, timeout: .seconds(10))
            let status = Int(response.status.code)
            // The body is deliberately abandoned: an accepted stream never ends, and only its
            // status was wanted.
            try await client.shutdown()
            return status
        } catch {
            // `HTTPClient` traps in `deinit` if it is not shut down.
            try? await client.shutdown()
            throw error
        }
    }
}
