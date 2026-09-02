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

/// Picking a dropped stream back up where it stopped.
///
/// The session records event ids and its unit tests prove it builds the right header. That
/// proves nothing about whether the transport *sends* it — which is the same gap that left
/// `updateAuthorization(_:)` correct and uncalled for months. This asserts it on the wire.
@Suite("Streamable HTTP — resumption")
struct StreamableHTTPResumptionTests {

    /// A stream that delivered an event and then ended is reopened, and the reopen says where
    /// to continue from. Without the header the server replays from the beginning or not at
    /// all, and either way the messages between the drop and the reconnect are lost.
    @Test("A reconnect carries the last event id", .timeLimit(.minutes(1)))
    func reconnectCarriesLastEventID() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok("{}")],
            serverStream: .serving([#"{"jsonrpc":"2.0","method":"tick"}"#], firstID: "evt-1"))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        do {
            await transport.didNegotiate(protocolVersion: "2025-06-18")

            // Two deliveries means the stream ended and was reopened at least once.
            _ = try await transport.receive()
            _ = try await transport.receive()

            let opens = await server.serverStreamOpens
            #expect(opens.count >= 2, "the stream was not reopened after it ended")
            #expect(opens.first?.lastEventID == nil,
                    "the first open asked to resume a stream that had never run")
            #expect(opens.dropFirst().first?.lastEventID == "evt-1",
                    "the reconnect did not say where to continue from")

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// Disconnecting stops the stream rather than leaving it reconnecting against a server
    /// nobody is talking to any more.
    @Test("Disconnecting stops the reconnect loop", .timeLimit(.minutes(1)))
    func disconnectStopsReconnecting() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok("{}")],
            serverStream: .serving([#"{"jsonrpc":"2.0","method":"tick"}"#]))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        await transport.didNegotiate(protocolVersion: "2025-06-18")
        _ = try await transport.receive()
        try await transport.disconnect()

        let afterDisconnect = await server.serverStreamOpens.count
        // Long enough that a live reconnect loop would have opened several more.
        try await Task.sleep(for: .milliseconds(200))

        #expect(await server.serverStreamOpens.count == afterDisconnect,
                "the stream kept reconnecting after disconnect")

        await server.stop()
    }
}

/// Recovering a response stream the server cut off.
///
/// 2025-11-25 (SEP-1699) settles how: **resumption is always via `GET`, regardless of which
/// stream dropped.** A broken response stream is not re-issued as a new POST — that would run
/// the work twice — it is picked back up with a `GET` carrying the last event id seen on it.
///
/// This package recorded those event ids from the day the streaming path landed and never used
/// them. A dropped response stream simply lost its response, and the caller saw a request that
/// never answered.
@Suite("Streamable HTTP — response stream resumption")
struct StreamableHTTPResponseResumptionTests {

    /// The recovery, end to end: the response stream dies after one event, and the rest arrives
    /// over a `GET` that says where to continue from.
    @Test("A dropped response stream is resumed with a GET", .timeLimit(.minutes(1)))
    func droppedResponseStreamResumes() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.droppedAfter(#"{"jsonrpc":"2.0","method":"notifications/progress"}"#,
                                    id: "evt-4")],
            serverStream: .serving([#"{"jsonrpc":"2.0","id":1,"result":{}}"#]))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))

            // What arrived before the drop.
            let progress = try await transport.receive()
            #expect(String(decoding: progress, as: UTF8.self).contains("progress"))

            // Waited for at the *server*, not by awaiting `receive()`. `receive()` parks on a
            // continuation that is not cancellation-aware, so an unimplemented resume would
            // hang the whole suite rather than fail this test — which is exactly what it did
            // the first time this was written.
            let resumed = await waitForServerStreamOpen(on: server)
            let resume = try #require(resumed, "no GET was opened; the dropped stream was not resumed")
            #expect(resume.lastEventID == "evt-4",
                    "the resume did not say where the dropped stream stopped")

            // Only now is it safe to wait for the rest of the response.
            let result = try await transport.receive()
            #expect(String(decoding: result, as: UTF8.self).contains(#""id":1"#))

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// A stream that ends *cleanly* is a finished stream, not a dropped one. Resuming it would
    /// ask the server to replay a response it has already delivered in full.
    @Test("A response stream that ends cleanly is not resumed", .timeLimit(.minutes(1)))
    func cleanEndIsNotResumed() async throws {
        let server = try await StubHTTPServer.start(
            replies: [.ok(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)],
            serverStream: .serving(["{}"]))
        let transport = StreamableHTTPTransport(url: try await server.url)
        try await transport.connect()

        try await transport.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
        _ = try await transport.receive()

        #expect(await server.serverStreamOpens.isEmpty,
                "a completed response was resumed as though it had been cut off")

        try await transport.disconnect()
        await server.stop()
    }
}

// MARK: - Bounded waiting

/// Waits, briefly and with a bound, for the client to open a server stream.
///
/// Polls the server rather than awaiting the transport. Anything that awaits `receive()` for a
/// message that may never arrive cannot be timed out — the continuation it parks on does not
/// observe cancellation — so a missing feature presents as a hung suite instead of a failed
/// test.
private func waitForServerStreamOpen(
    on server: StubHTTPServer,
    attempts: Int = 40
) async -> StubHTTPServer.Received? {
    for _ in 0..<attempts {
        if let first = await server.serverStreamOpens.first { return first }
        // silent: a cancelled sleep just ends the wait early, and the caller handles nil
        try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
}
