import Foundation
import Testing
import Logging
import NIOCore
@testable import MCPClient

/// An error that describes itself the way a networking library's does: with the URL it was
/// reaching, whole.
struct LeakyError: LocalizedError {
    static let marker = "fixture-token-do-not-log"
    var errorDescription: String? {
        "GET https://mcp.example.test/mcp/key?token=\(LeakyError.marker) failed"
    }
}

/// A transport whose `receive()` fails with an error of its own.
actor FailingReceiveTransport: MCPTransport {
    private(set) var sent: [Data] = []
    func connect() async throws {}
    func disconnect() async throws {}
    func send(_ data: Data) async throws { sent.append(data) }
    func receive() async throws -> Data { throw LeakyError() }
}

/// What is said — in a log and to a caller — when reading from a transport fails.
///
/// A connection failure was already described by ``TransportFailure``: its kind, in this
/// package's words, and never the library's own description. A failure while *reading* was
/// not. The dispatcher and the event stream logged `error.localizedDescription`, and the
/// dispatcher handed the raw error to every request that was waiting.
@Suite("A failed read is described by its kind")
struct ReceiveFailureTests {

    @Test("The dispatcher logs the kind of a receive failure, not its description", .timeLimit(.minutes(1)))
    func dispatcherLogsKind() async throws {
        let recorder = LogRecorder()
        let dispatcher = MCPMessageDispatcher(transport: FailingReceiveTransport(), logger: recorder.logger())
        await dispatcher.start()
        // Returns once the read loop has failed, whichever of the two got there first.
        await #expect(throws: (any Error).self) { try await dispatcher.waitForResponse(id: 1) }

        let lines = recorder.messages(at: .warning)
        #expect(lines.count == 1)
        #expect(lines.allSatisfy { !$0.contains(LeakyError.marker) && !$0.contains("mcp.example.test") },
                "the library's own description was logged: \(lines)")
        #expect(lines.first?.contains("LeakyError") == true, "the kind was not named: \(lines)")
        await dispatcher.stop()
    }

    @Test("A request waiting on a failed read is failed with MCPError, not the library's error",
          .timeLimit(.minutes(1)))
    func dispatcherWrapsError() async throws {
        let dispatcher = MCPMessageDispatcher(
            transport: FailingReceiveTransport(), logger: LogRecorder().logger())
        await dispatcher.start()
        var caught: (any Error)?
        do {
            _ = try await dispatcher.waitForResponse(id: 1)
        } catch {
            caught = error
        }
        guard case .connectionFailed(let reason) = caught as? MCPError else {
            Issue.record("expected MCPError.connectionFailed, got \(String(describing: caught))")
            return
        }
        #expect(!reason.contains(LeakyError.marker))
        #expect(reason.contains("LeakyError"))
        // And the same for a request that arrives after the failure.
        await #expect(throws: MCPError.connectionFailed(reason: reason)) {
            try await dispatcher.waitForResponse(id: 2)
        }
        await dispatcher.stop()
    }

    @Test("An MCPError from the transport reaches the caller as it was thrown", .timeLimit(.minutes(1)))
    func ownErrorsPassThrough() async throws {
        #expect(TransportFailure.receiveFailure(MCPError.transportClosed) == .transportClosed)
        #expect(TransportFailure.receiveFailure(MCPError.connectionFailed(reason: "SSE stream terminated"))
                == .connectionFailed(reason: "SSE stream terminated"))
    }

    @Test("initialize, read directly, reports a failed read as MCPError", .timeLimit(.minutes(1)))
    func directReadWrapsError() async throws {
        let connection = MCPClientConnection(transport: FailingReceiveTransport())
        var caught: (any Error)?
        do {
            _ = try await connection.initialize(clientName: "test", clientVersion: "1")
        } catch {
            caught = error
        }
        guard case .connectionFailed(let reason) = caught as? MCPError else {
            Issue.record("expected MCPError.connectionFailed, got \(String(describing: caught))")
            return
        }
        #expect(!reason.contains(LeakyError.marker))
    }

    @Test("The event stream logs the kind of a body failure, not its description", .timeLimit(.minutes(1)))
    func eventStreamLogsKind() async throws {
        let recorder = LogRecorder()
        let (bytes, continuation) = AsyncThrowingStream<ByteBuffer, any Error>.makeStream()
        continuation.yield(ByteBuffer(string: "data: one\n\n"))
        continuation.finish(throwing: LeakyError())

        var events: [SSEEvent] = []
        var caught: (any Error)?
        do {
            for try await event in SSEEventStream.events(from: bytes, logger: recorder.logger()) {
                events.append(event)
            }
        } catch {
            caught = error
        }
        #expect(events.map(\.data) == ["one"])
        #expect(caught is LeakyError)

        let lines = recorder.messages(at: .warning)
        #expect(lines.count == 1)
        #expect(lines.allSatisfy { !$0.contains(LeakyError.marker) && !$0.contains("mcp.example.test") },
                "the library's own description was logged: \(lines)")
        #expect(lines.first?.contains("LeakyError") == true, "the kind was not named: \(lines)")
    }
}
