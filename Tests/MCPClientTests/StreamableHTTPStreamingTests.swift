import Foundation
import Testing
import AsyncHTTPClient
@testable import MCPClient

/// A POST response consumed as it arrives, rather than after it ends.
///
/// The spec permits a server to hold a POST response open and emit SSE events as work
/// progresses. Collecting the whole body first turns every one of those into a report: progress
/// notifications arrive in a batch after the work finished, which is the one moment they are
/// worthless. It also fails any call slower than the request timeout or larger than the buffer
/// cap, both of which present to a user as "the server is broken".
///
/// The server here flushes one event and refuses to send the next until the client says, over a
/// separate request, that the first arrived — so what is asserted is an ordering the server
/// recorded, not an elapsed time.
@Suite("Streamable HTTP — streaming responses")
struct StreamableHTTPStreamingTests {

    /// The property that distinguishes streaming from collecting: a message is receivable
    /// while the response that carries it is still open.
    @Test("A message is delivered before the response ends", .timeLimit(.minutes(1)))
    func deliversBeforeResponseEnds() async throws {
        let server = try await FlushProbeServer.start(
            first: #"{"jsonrpc":"2.0","id":1,"result":{"step":"one"}}"#,
            second: #"{"jsonrpc":"2.0","id":2,"result":{"step":"two"}}"#)
        let transport = StreamableHTTPTransport(url: try await server.probeURL)
        try await transport.connect()

        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))

            // Arrives while the server is still holding the response open — the server will
            // not send the second event until told, and it is told below.
            let first = try await transport.receive()
            #expect(String(decoding: first, as: UTF8.self).contains("one"))

            try await tell(try await server.signalURL)
            let second = try await transport.receive()
            #expect(String(decoding: second, as: UTF8.self).contains("two"))

            let incremental = await server.signalPrecededSecondFlush
            #expect(incremental, """
                the first message was not delivered until the response closed — the body is \
                still being collected rather than streamed
                """)

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// Event ids on a POST stream are recorded, because resumption needs them: a transport
    /// that streams but discards the ids cannot send `Last-Event-ID` when the stream drops.
    @Test("Event ids on a response stream are recorded", .timeLimit(.minutes(1)))
    func recordsEventIDs() async throws {
        let server = try await FlushProbeServer.start(
            first: #"{"jsonrpc":"2.0","id":7,"result":{}}"#,
            second: #"{"jsonrpc":"2.0","id":8,"result":{}}"#,
            firstID: "evt-11")
        let transport = StreamableHTTPTransport(url: try await server.probeURL)
        try await transport.connect()

        do {
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":7}"#.utf8))
            _ = try await transport.receive()

            #expect(await transport.lastEventID(forRequest: "7") == "evt-11")

            try await tell(try await server.signalURL)
            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// A plain JSON response is unchanged. Most responses are one document with nothing to
    /// stream, and rerouting them through the streaming path would be machinery for nothing.
    @Test("A plain JSON response still arrives whole")
    func plainJSONUnchanged() async throws {
        let received = try await withStub(replies: [.ok(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)]) {
            transport, _ in
            try await transport.send(Data("{}".utf8))
            return try await transport.receive()
        }

        #expect(String(decoding: received, as: UTF8.self).contains(#""id":1"#))
    }

    /// Sends the signal that releases the held response.
    private func tell(_ url: URL) async throws {
        let client = HTTPClient(eventLoopGroupProvider: .singleton)
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        do {
            _ = try await client.execute(request, timeout: .seconds(5))
            try await client.shutdown()
        } catch {
            // `HTTPClient` traps in `deinit` if it is not shut down.
            try? await client.shutdown()
            throw error
        }
    }
}

/// Events that carry nothing.
///
/// A server may send an SSE event with an id and an empty `data:` line — a keep-alive, or a
/// priming event before the real one. The reference implementation does exactly that once a
/// 2025-11-25 session is negotiated.
///
/// An event carrying no data is not a message. Handing one to a JSON-RPC decoder produces a
/// failure that names the response as invalid, when in fact the server did nothing wrong and
/// the real response arrived immediately afterwards.
@Suite("Streamable HTTP — empty events")
struct StreamableHTTPEmptyEventTests {

    /// The message after the empty one is what a caller receives.
    @Test("An empty-data event is not delivered as a message", .timeLimit(.minutes(1)))
    func emptyEventIsNotAMessage() async throws {
        let received = try await withStub(
            replies: [.primedSSE(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)]
        ) { transport, _ in
            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
            return try await transport.receive()
        }

        #expect(String(decoding: received, as: UTF8.self).contains(#""id":1"#),
                "the priming event was delivered instead of the response")
    }
}
