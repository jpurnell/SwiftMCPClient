import Foundation
import Testing
@testable import MCPClient

#if os(macOS) || os(Linux)

/// How much one line from a subprocess may hold.
///
/// A message is a line, and a line ends when the child writes a newline. A child that never
/// does — by fault or by intent — was buffered until the process ran out of memory.
@Suite("StdioTransport — message limit")
struct StdioLimitTests {

    static let small = MCPResponseLimits(maximumMessageBytes: 1_000)

    /// A JSON-RPC-shaped line of exactly `bytes` bytes, without its newline.
    static func line(bytes: Int) -> Data {
        let prefix = #"{"jsonrpc":"2.0","id":1,"result":{"pad":""#
        let suffix = #""}}"#
        let padding = max(0, bytes - prefix.utf8.count - suffix.utf8.count)
        return Data((prefix + String(repeating: "a", count: padding) + suffix).utf8)
    }

    @Test("A line of exactly the limit is delivered", .timeLimit(.minutes(1)))
    func exactlyTheLimit() async throws {
        let transport = StdioTransport(command: "/bin/cat", limits: Self.small)
        try await transport.connect()
        let message = Self.line(bytes: 1_000)
        try await transport.send(message)
        #expect(try await transport.receive() == message)
        try await transport.disconnect()
    }

    @Test("A line over the limit is refused as too large", .timeLimit(.minutes(1)))
    func lineOverTheLimit() async throws {
        let transport = StdioTransport(command: "/bin/cat", limits: Self.small)
        try await transport.connect()
        try await transport.send(Self.line(bytes: 1_001))
        do {
            _ = try await transport.receive()
            Issue.record("a line over the limit was delivered")
        } catch let MCPError.responseTooLarge(limit, reason) {
            #expect(limit == 1_000)
            #expect(!reason.contains("/bin/cat"), "\(reason)")
        } catch {
            Issue.record("expected MCPError.responseTooLarge, got \(error)")
        }
        try await transport.disconnect()
    }

    @Test("A child that never writes a newline is cut off, not buffered for ever",
          .timeLimit(.minutes(1)))
    func noNewline() async throws {
        // 100 KB of "a", no newline, and then the child stays alive: only the limit ends this.
        let transport = StdioTransport(
            command: "/bin/sh",
            arguments: ["-c", "head -c 100000 /dev/zero | tr '\\0' a; sleep 30"],
            limits: Self.small)
        try await transport.connect()
        do {
            _ = try await transport.receive()
            Issue.record("a line with no end was delivered")
        } catch let MCPError.responseTooLarge(limit, _) {
            #expect(limit == 1_000)
        } catch {
            Issue.record("expected MCPError.responseTooLarge, got \(error)")
        }
        try await transport.disconnect()
    }

    @Test("After a message is refused the child is stopped and the transport is closed",
          .timeLimit(.minutes(1)))
    func closedAfterRefusal() async throws {
        let transport = StdioTransport(command: "/bin/cat", limits: Self.small)
        try await transport.connect()
        try await transport.send(Self.line(bytes: 1_001))
        _ = try? await transport.receive()
        // Framing is lost mid-line; nothing further can be read from this stream.
        await #expect(throws: MCPError.self) { _ = try await transport.receive() }
        await #expect(throws: MCPError.self) { try await transport.send(Self.line(bytes: 10)) }
        try await transport.disconnect()
    }

    @Test("The default limit is the standard one", .timeLimit(.minutes(1)))
    func defaultLimit() async throws {
        #expect(MCPResponseLimits.standard.maximumMessageBytes == MCPResponseLimits.defaultMaximumBytes)
    }
}

#endif
