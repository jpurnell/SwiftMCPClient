import Foundation
import Testing
import Logging
import NIOCore
@testable import MCPClient

/// How much of a response a transport reads, and what it says when reading one fails.
///
/// Two things were wrong with `response.body.collect`. A body that failed part-way — the
/// server hung up before sending what `Content-Length` promised — threw the networking
/// library's own error straight to the caller, where a connection failure had long been
/// described in this package's words. And a body past the fixed 10 MB ceiling threw
/// `NIOTooManyBytesError`, which says nothing about what was too large or how to allow it.
/// An event stream had no ceiling at all: an event whose blank line never came was
/// accumulated until memory ran out.
///
/// The stub writes bytes exactly as given, because the responses in question are the ones a
/// well-formed server cannot produce.
@Suite("Response bodies and events — failures and limits (wire)")
struct ResponseLimitWireTests {

    static let message = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)

    /// A legacy stream's opening: the head, and the `endpoint` event `connect()` waits for.
    static let legacyStream = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        + "event: endpoint\ndata: /messages\n\n"

    static func json(declaring length: Int?, sending count: Int) -> String {
        let declared = length.map { "Content-Length: \($0)\r\n" } ?? ""
        return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\(declared)Connection: close\r\n\r\n"
            + #"{"jsonrpc":"2.0","id":1,"result":{"pad":""#
            + String(repeating: "a", count: max(0, count - 44)) + #""}}"#
    }

    enum Kind: String, CaseIterable, Sendable { case streamable, legacy }

    /// Sends one message through a transport of `kind` to a stub answering its `POST` with
    /// `reply`, and returns what `send(_:)` threw and what `receive()` then had.
    static func send(
        _ kind: Kind, answeredWith reply: String, limits: MCPResponseLimits = .standard
    ) async throws -> (error: (any Error)?, received: Data?, origin: String) {
        let server = try await FaultStubServer.start(.byMethod(get: legacyStream, other: reply))
        let transport: any MCPTransport
        switch kind {
        case .streamable:
            transport = StreamableHTTPTransport(
                url: try await server.url(path: "/mcp"), openServerStream: false,
                connectionTimeout: 5, limits: limits)
        case .legacy:
            transport = HTTPSSETransport(
                url: try await server.url(path: "/sse"), connectionTimeout: 5,
                maxReconnectAttempts: 0, limits: limits)
        }
        try await transport.connect()
        var caught: (any Error)?
        var received: Data?
        do {
            try await transport.send(message)
            received = try await transport.receive()
        } catch {
            caught = error
        }
        try await transport.disconnect()
        let origin = "http://127.0.0.1:\(try await server.port)"
        await server.stop()
        return (caught, received, origin)
    }

    // MARK: - A body that fails part-way

    @Test("A body cut short is connectionFailed, naming the kind and the origin",
          .timeLimit(.minutes(1)), arguments: Kind.allCases)
    func truncatedBody(_ kind: Kind) async throws {
        let outcome = try await Self.send(kind, answeredWith: Self.json(declaring: 5000, sending: 100))
        guard case .connectionFailed(let reason) = outcome.error as? MCPError else {
            Issue.record("\(kind): expected MCPError.connectionFailed, got \(String(describing: outcome.error))")
            return
        }
        #expect(reason.hasPrefix("Could not reach \(outcome.origin): "), "\(kind): \(reason)")
        #expect(!reason.contains("HTTPClientError") || !reason.contains("error "), "\(kind): \(reason)")
    }

    // MARK: - A body past the limit

    @Test("A body declared larger than the limit is responseTooLarge",
          .timeLimit(.minutes(1)), arguments: Kind.allCases)
    func declaredTooLarge(_ kind: Kind) async throws {
        let outcome = try await Self.send(
            kind, answeredWith: Self.json(declaring: 5000, sending: 5000),
            limits: MCPResponseLimits(maximumResponseBytes: 1024))
        guard case .responseTooLarge(let limit, let reason) = outcome.error as? MCPError else {
            Issue.record("\(kind): expected MCPError.responseTooLarge, got \(String(describing: outcome.error))")
            return
        }
        #expect(limit == 1024)
        #expect(reason.contains(outcome.origin) && reason.contains("1024"), "\(kind): \(reason)")
    }

    @Test("A body with no declared length is cut off at the limit",
          .timeLimit(.minutes(1)), arguments: Kind.allCases)
    func undeclaredTooLarge(_ kind: Kind) async throws {
        let outcome = try await Self.send(
            kind, answeredWith: Self.json(declaring: nil, sending: 5000),
            limits: MCPResponseLimits(maximumResponseBytes: 1024))
        guard case .responseTooLarge(let limit, _) = outcome.error as? MCPError else {
            Issue.record("\(kind): expected MCPError.responseTooLarge, got \(String(describing: outcome.error))")
            return
        }
        #expect(limit == 1024)
    }

    @Test("A body within the limit is delivered whole",
          .timeLimit(.minutes(1)), arguments: Kind.allCases)
    func withinLimit(_ kind: Kind) async throws {
        let outcome = try await Self.send(
            kind, answeredWith: Self.json(declaring: 900, sending: 900),
            limits: MCPResponseLimits(maximumResponseBytes: 1024))
        #expect(outcome.error == nil, "\(kind): \(String(describing: outcome.error))")
        #expect(outcome.received?.count == 900)
    }

    @Test("The limits default to 10 MiB each, and a limit below one byte is one byte")
    func defaults() {
        #expect(MCPResponseLimits.standard.maximumResponseBytes == 10 * 1024 * 1024)
        #expect(MCPResponseLimits.standard.maximumEventBytes == 10 * 1024 * 1024)
        #expect(MCPResponseLimits(maximumResponseBytes: 0, maximumEventBytes: -5)
                == MCPResponseLimits(maximumResponseBytes: 1, maximumEventBytes: 1))
    }

    // MARK: - An event past the limit

    /// A source of chunks that counts how many were taken from it.
    struct CountedChunks: AsyncSequence, Sendable {
        typealias Element = ByteBuffer
        let texts: [String]
        let taken: ByteCount

        struct AsyncIterator: AsyncIteratorProtocol {
            var index = 0
            let texts: [String]
            let taken: ByteCount

            mutating func next() async -> ByteBuffer? {
                guard index < texts.count else { return nil }
                defer { index += 1 }
                taken.add(1)
                return ByteBuffer(string: texts[index])
            }
        }

        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(texts: texts, taken: taken)
        }
    }

    static func chunks(_ texts: [String], taken: ByteCount) -> CountedChunks {
        CountedChunks(texts: texts, taken: taken)
    }

    @Test("An event that never ends is cut off at the limit, not accumulated", .timeLimit(.minutes(1)))
    func eventStreamCutOff() async throws {
        let taken = ByteCount()
        // One complete event, then a `data:` line that goes on for 200 KiB without ending.
        let source = Self.chunks(
            ["data: one\n\n", "data: "] + Array(repeating: String(repeating: "a", count: 1024), count: 200),
            taken: taken)

        var events: [String] = []
        var caught: (any Error)?
        do {
            for try await event in SSEEventStream.events(
                from: source, logger: LogRecorder().logger(), maximumEventBytes: 4096) {
                events.append(event.data)
            }
        } catch {
            caught = error
        }
        #expect(events == ["one"])
        guard case .responseTooLarge(let limit, _) = caught as? MCPError else {
            Issue.record("expected MCPError.responseTooLarge, got \(String(describing: caught))")
            return
        }
        #expect(limit == 4096)
        // Two chunks to begin with, four more to reach 4096 bytes of pending event, one to
        // pass it, and whatever the stream had buffered ahead: nowhere near 202.
        #expect(taken.value < 20, "\(taken.value) chunks were read before stopping")
    }

    @Test("Many events, each within the limit, are all delivered", .timeLimit(.minutes(1)))
    func manySmallEvents() async throws {
        let line = "data: " + String(repeating: "b", count: 1000) + "\n\n"
        let source = Self.chunks(Array(repeating: line, count: 50), taken: ByteCount())
        var count = 0
        for try await _ in SSEEventStream.events(
            from: source, logger: LogRecorder().logger(), maximumEventBytes: 4096) {
            count += 1
        }
        #expect(count == 50)
    }

    static let endlessEvent = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
        + "data: " + String(repeating: "a", count: 8000)

    @Test("Legacy HTTP+SSE: an oversized first event fails connect() and is not retried",
          .timeLimit(.minutes(1)))
    func legacyConnectTooLarge() async throws {
        let server = try await FaultStubServer.start(.byMethod(get: Self.endlessEvent, other: ""))
        let transport = HTTPSSETransport(
            url: try await server.url(path: "/sse"), connectionTimeout: 5,
            maxReconnectAttempts: 3, reconnectBaseDelay: 0.01,
            limits: MCPResponseLimits(maximumEventBytes: 1024))
        var caught: (any Error)?
        do {
            try await transport.connect()
        } catch {
            caught = error
        }
        guard case .responseTooLarge(let limit, _) = caught as? MCPError else {
            Issue.record("expected MCPError.responseTooLarge, got \(String(describing: caught))")
            return
        }
        #expect(limit == 1024)
        #expect(server.connectionsAccepted == 1, "the stream was opened \(server.connectionsAccepted) times")
        try await transport.disconnect()
        await server.stop()
    }

    @Test("Streamable HTTP: an oversized event ends the server stream for good, and says so",
          .timeLimit(.minutes(1)))
    func serverStreamTooLarge() async throws {
        let server = try await FaultStubServer.start(.byMethod(get: Self.endlessEvent, other: ""))
        let recorder = LogRecorder()
        let transport = StreamableHTTPTransport(
            url: try await server.url(path: "/mcp"), connectionTimeout: 5,
            limits: MCPResponseLimits(maximumEventBytes: 1024))
        await transport.useDiagnostics(recorder.logger())
        try await transport.connect()
        await transport.didNegotiate(protocolVersion: "2025-06-18")

        let ended = try await RedirectRun.wait(atMost: .seconds(10)) {
            await transport.serverStreamEnding != nil
        }
        #expect(ended, "the server stream's loop is still running")
        #expect(await transport.serverStreamEnding == .eventTooLarge)
        #expect(server.connectionsAccepted == 1, "the stream was opened \(server.connectionsAccepted) times")
        #expect(recorder.messages(at: .error).contains { $0.contains("1024") })
        try await transport.disconnect()
        await server.stop()
    }

    @Test("Streamable HTTP: an oversized event in a POST's stream is abandoned, not resumed",
          .timeLimit(.minutes(1)))
    func responseStreamTooLarge() async throws {
        let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
            + "id: 1\ndata: \n\n" + "data: " + String(repeating: "a", count: 8000)
        let server = try await FaultStubServer.start(.byMethod(get: Self.endlessEvent, other: reply))
        let recorder = LogRecorder()
        let transport = StreamableHTTPTransport(
            url: try await server.url(path: "/mcp"), openServerStream: false, connectionTimeout: 5,
            limits: MCPResponseLimits(maximumEventBytes: 1024))
        await transport.useDiagnostics(recorder.logger())
        try await transport.connect()
        try await transport.send(Self.message)

        let idle = try await RedirectRun.wait(atMost: .seconds(10)) {
            await transport.responseStreamsAreIdle
        }
        #expect(idle, "the response stream is still being read")
        // One connection: the POST. A resumption would have been a second, a GET.
        #expect(server.connectionsAccepted == 1, "\(server.connectionsAccepted) connections were made")
        #expect(recorder.messages(at: .error).contains { $0.contains("1024") })
        try await transport.disconnect()
        await server.stop()
    }
}
