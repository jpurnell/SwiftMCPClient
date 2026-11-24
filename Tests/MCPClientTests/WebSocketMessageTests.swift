import Foundation
import Testing
import NIOWebSocket
@testable import MCPClient

/// What `WebSocketTransport` does with messages on a connection that works.
///
/// Every earlier WebSocket test ended at the upgrade. None got a message off a connected
/// socket, which is how a transport that crashed on every successful connection, and one
/// that refused any message over 16 KiB, went unnoticed.
@Suite("WebSocketTransport — messages (wire)")
struct WebSocketMessageTests {

    static let ping = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

    /// Connects, sends one message, and returns what `receive()` gave or threw.
    static func exchange(
        reply: WebSocketStubServer.Reply,
        limits: MCPResponseLimits = .standard
    ) async throws -> (received: Data?, error: (any Error)?, origin: String) {
        let server = try await WebSocketStubServer.start(reply: reply)
        let url = try await server.url()
        let transport = WebSocketTransport(url: url, limits: limits)
        var received: Data?
        var caught: (any Error)?
        do {
            try await transport.connect()
            try await transport.send(ping)
            received = try await transport.receive()
        } catch {
            caught = error
        }
        try? await transport.disconnect()
        await server.stop()
        return (received, caught, HTTPOrigin.description(of: url))
    }

    @Test("A message sent on a connected socket is received", .timeLimit(.minutes(1)))
    func roundTrip() async throws {
        let outcome = try await Self.exchange(reply: .single(bytes: 1_000))
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        #expect(outcome.received == Data(WebSocketStubServer.message(bytes: 1_000).utf8))
    }

    @Test("A message larger than one default frame arrives whole", .timeLimit(.minutes(1)))
    func largerThanDefaultFrame() async throws {
        // 16 KiB is WebSocketKit's default for one frame. A tool listing is routinely larger.
        let outcome = try await Self.exchange(reply: .single(bytes: 20_000))
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        #expect(outcome.received?.count == 20_000)
    }

    @Test("A message sent as fragments is joined", .timeLimit(.minutes(1)))
    func fragmentedMessage() async throws {
        let outcome = try await Self.exchange(reply: .fragmented(total: 200_000, fragment: 8_192))
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        #expect(outcome.received?.count == 200_000)
    }

    // MARK: - The limit

    static let small = MCPResponseLimits(maximumMessageBytes: 4_096)

    @Test("A message of exactly the limit is delivered", .timeLimit(.minutes(1)))
    func exactlyTheLimit() async throws {
        let outcome = try await Self.exchange(reply: .single(bytes: 4_096), limits: Self.small)
        #expect(outcome.error == nil, "\(String(describing: outcome.error))")
        #expect(outcome.received?.count == 4_096)
    }

    /// The reason a connection that was closed on a message past the limit gives.
    static func expectNamesTheLimit(_ error: (any Error)?, _ label: String) {
        guard case .connectionFailed(let reason) = error as? MCPError else {
            Issue.record("\(label): expected MCPError.connectionFailed, got \(String(describing: error))")
            return
        }
        #expect(reason.contains("4096-byte limit"), "\(label): \(reason)")
    }

    @Test("A single frame over the limit is not delivered, and the close names the limit",
          .timeLimit(.minutes(1)))
    func frameOverTheLimit() async throws {
        let outcome = try await Self.exchange(reply: .single(bytes: 5_000), limits: Self.small)
        #expect(outcome.received == nil)
        Self.expectNamesTheLimit(outcome.error, "frame")
    }

    @Test("Fragments that add up to more than the limit are refused, though each is small",
          .timeLimit(.minutes(1)))
    func fragmentsOverTheLimit() async throws {
        // Eight fragments of 1,000 bytes: none comes near a frame limit, together they pass it.
        let outcome = try await Self.exchange(
            reply: .fragmented(total: 8_000, fragment: 1_000), limits: Self.small)
        #expect(outcome.received == nil)
        Self.expectNamesTheLimit(outcome.error, "fragments")
    }

    @Test("A message of 20 MB sent in fragments is not buffered without bound", .timeLimit(.minutes(1)))
    func defaultLimitStopsAFlood() async throws {
        // The default is 10 MiB; this is twice that.
        let outcome = try await Self.exchange(reply: .fragmented(total: 20_000_000, fragment: 8_192))
        #expect(outcome.received == nil, "a message over the default limit was delivered whole")
        guard case .connectionFailed(let reason) = outcome.error as? MCPError else {
            Issue.record("expected MCPError.connectionFailed, got \(String(describing: outcome.error))")
            return
        }
        #expect(reason.contains("\(MCPResponseLimits.defaultMaximumBytes)-byte limit"), "\(reason)")
    }

    @Test("A close says what is known, and no more", arguments: [
        (nil as WebSocketErrorCode?, true), (.unexpectedServerError, true),
        (.normalClosure, false), (.goingAway, false), (.messageTooLarge, false),
    ])
    func closeReasons(_ code: WebSocketErrorCode?, _ namesTheLimit: Bool) {
        let reason = WebSocketTransport.reason(forClosing: code, limit: 4_096)
        #expect(reason.contains("4096-byte limit") == namesTheLimit, "\(String(describing: code)): \(reason)")
    }
}
