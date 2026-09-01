import Foundation
import Testing
import NIOHTTP1
@testable import MCPClient

/// The client-initiated `GET` that carries messages the server originates.
///
/// Without it a `MCPClientConnection`'s notification stream is permanently empty over this
/// transport, and a server that expects to drive sampling cannot. ADR-001 deferred it; ADR-002
/// is this.
///
/// The stream is opened after initialization, because that is when the session exists to open
/// it for — and `didNegotiate` is the only moment the transport learns initialization
/// happened.
@Suite("Streamable HTTP — server stream")
struct StreamableHTTPServerStreamTests {

    /// A message the client never asked for, arriving on the channel that exists to carry it.
    @Test("A server-originated message is delivered", .timeLimit(.minutes(1)))
    func deliversServerMessage() async throws {
        let notification = #"{"jsonrpc":"2.0","method":"notifications/message","params":{}}"#
        let server = try await StubHTTPServer.start(
            replies: [.ok("{}")],
            serverStream: .serving([notification]))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        do {
            await transport.didNegotiate(protocolVersion: "2025-06-18")
            let received = try await transport.receive()

            #expect(String(decoding: received, as: UTF8.self).contains("notifications/message"))
            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// The stream is not opened before initialization. Opening it earlier asks a server to
    /// start a session-scoped channel for a session that does not exist yet.
    @Test("No stream is opened before initialization", .timeLimit(.minutes(1)))
    func noStreamBeforeInitialization() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok("{}")],
            serverStream: .serving(["{}"]))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        try await transport.send(Data("{}".utf8))
        _ = try await transport.receive()

        #expect(await server.serverStreamOpens.isEmpty)

        try await transport.disconnect()
        await server.stop()
    }

    /// A `405` is the server saying it offers no such channel. That is not an error: request
    /// and response keep working, and a client that treated it as a failure would refuse to
    /// talk to a conformant server.
    @Test("A 405 leaves the transport working", .timeLimit(.minutes(1)))
    func refusedStreamIsNotAFailure() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok(#"{"jsonrpc":"2.0","id":1}"#)],
            serverStream: .unsupported)
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        do {
            await transport.didNegotiate(protocolVersion: "2025-06-18")

            // The POST path is unaffected by the server having refused the GET.
            try await transport.send(Data("{}".utf8))
            let response = try await transport.receive()
            #expect(String(decoding: response, as: UTF8.self).contains(#""id":1"#))

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// A caller who does not want the channel gets exactly the previous behaviour — the
    /// one-line retreat ADR-002 promises.
    @Test("openServerStream false opens nothing", .timeLimit(.minutes(1)))
    func disabledOpensNothing() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok("{}")],
            serverStream: .serving(["{}"]))
        let transport = StreamableHTTPTransport(
            url: try await server.url, openServerStream: false)
        try await transport.connect()

        await transport.didNegotiate(protocolVersion: "2025-06-18")
        try await transport.send(Data("{}".utf8))
        _ = try await transport.receive()

        #expect(await server.serverStreamOpens.isEmpty)

        try await transport.disconnect()
        await server.stop()
    }

    /// Exactly one stream at a time. The specification permits one, and a client that opens
    /// another on every prompt leaks them server-side.
    @Test("Negotiating twice does not open a second stream", .timeLimit(.minutes(1)))
    func onlyOneStream() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok("{}")],
            serverStream: .serving([#"{"jsonrpc":"2.0","method":"a"}"#]))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        do {
            await transport.didNegotiate(protocolVersion: "2025-06-18")
            _ = try await transport.receive()
            await transport.didNegotiate(protocolVersion: "2025-06-18")

            #expect(await server.serverStreamOpens.count == 1,
                    "a second stream was opened while one was already running")

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// The stream carries the session, like every other request — a server tracking the
    /// conversation by id cannot attach an anonymous stream to it.
    @Test("The stream carries the session headers", .timeLimit(.minutes(1)))
    func streamCarriesSessionHeaders() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok("{}")],
            serverStream: .serving([#"{"jsonrpc":"2.0","method":"a"}"#]))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        do {
            // A POST first, so the server has assigned a session id to carry.
            try await transport.send(Data("{}".utf8))
            _ = try await transport.receive()

            await transport.didNegotiate(protocolVersion: "2025-06-18")
            _ = try await transport.receive()

            let open = try #require(await server.serverStreamOpens.first)
            #expect(open.sessionId == "stub-session")
            #expect(open.protocolVersion == "2025-06-18")

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }
}
