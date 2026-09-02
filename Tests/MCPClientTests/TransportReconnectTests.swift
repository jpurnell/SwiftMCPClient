import Foundation
import Testing
@testable import MCPClient

/// Connecting a transport that is already connected.
///
/// `AsyncHTTPClient` traps in `deinit` if a client was never shut down. Both transports created
/// a fresh client on every `connect()` and dropped the previous one on the floor, so a second
/// call killed the process — not with an error a caller could handle, with a `Fatal error`.
///
/// Nothing called `connect()` twice until `MCPConnectionFactory` did: it begins a session
/// optimistically, and falling back to the handshake era connects again. The defect was older
/// than the factory; the factory is only what reached it.
///
/// This is the same crash shape the package fixed in July on the handshake-rejection path. That
/// fix released the transport on one error path. This one stops the transport leaking a client
/// at all.
@Suite("Transport reconnection")
struct TransportReconnectTests {

    /// The Streamable HTTP transport survives being connected twice, and still works.
    @Test("Connecting twice does not leak a client", .timeLimit(.minutes(1)))
    func streamableConnectsTwice() async throws {
        let server = try await StubHTTPServer.start(replies: [.ok(#"{"jsonrpc":"2.0","id":1}"#)])
        let transport = StreamableHTTPTransport(url: try await server.url)

        do {
            try await transport.connect()
            // The second call is what used to orphan the first client.
            try await transport.connect()

            try await transport.send(Data(#"{"jsonrpc":"2.0","id":1}"#.utf8))
            let response = try await transport.receive()
            #expect(String(decoding: response, as: UTF8.self).contains(#""id":1"#),
                    "the transport stopped working after a second connect")

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// And the legacy transport, which had the same hole for the same reason.
    @Test("The SSE transport also survives a second connect", .timeLimit(.minutes(1)))
    func sseConnectsTwice() async throws {
        let server = try await SSEStubServer.start(replies: [.ok("{}")])
        let transport = HTTPSSETransport(url: try await server.url)

        do {
            try await transport.connect()
            try await transport.connect()

            try await transport.send(Data("{}".utf8))

            // Reached the server, so the surviving client is a working one rather than merely
            // an un-crashed one.
            #expect(await server.received.count == 1)

            try await transport.disconnect()
            await server.stop()
        } catch {
            try? await transport.disconnect()
            await server.stop()
            throw error
        }
    }

    /// Disconnecting twice is also a caller's prerogative, and must not fail either.
    @Test("Disconnecting twice is harmless", .timeLimit(.minutes(1)))
    func disconnectsTwice() async throws {
        let server = try await StubHTTPServer.start(replies: [.ok("{}")])
        let transport = StreamableHTTPTransport(url: try await server.url)

        try await transport.connect()
        try await transport.disconnect()
        try await transport.disconnect()

        // Genuinely disconnected, not merely un-crashed: a send now has no client to use.
        await #expect(throws: (any Error).self) {
            try await transport.send(Data("{}".utf8))
        }

        await server.stop()
    }
}
