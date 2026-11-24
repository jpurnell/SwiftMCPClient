import Foundation
import Testing
import Logging
@testable import MCPClient

/// The warning a transport writes when a credential is about to cross a network in the clear.
///
/// It was tested as a predicate — `HTTPOrigin.isPlaintextToRemote` — which says when the
/// warning *should* be written and nothing about whether it is. These read what each
/// transport actually wrote, through the logger it writes to.
///
/// "Another machine" has to be reachable without a network for a test to connect to it, so
/// it is `0.0.0.0`: not `localhost`, not in `127.0.0.0/8`, not `::1` — so the predicate calls
/// it remote — and yet a connection to it never leaves this host. Port 1 refuses at once.
@Suite("Plaintext credentials — the warning each transport writes")
struct PlaintextWarningTests {

    static let credentials = ["X-API-Key": "fixture-key-do-not-log"]

    /// The plaintext warnings in what was recorded.
    static func warnings(in recorder: LogRecorder) -> [String] {
        recorder.messages(at: .warning).filter { $0.hasPrefix(HTTPOrigin.plaintextWarningPrefix) }
    }

    /// Connects and disconnects, ignoring a refused connection: the warning is written
    /// before anything is dialled, and is what is being counted.
    static func cycle(_ transport: any MCPTransport) async {
        // silent: nothing listens on port 1; the refusal is expected and is not what is under test
        try? await transport.connect()
        // silent: disconnecting a transport that never connected has nothing to report
        try? await transport.disconnect()
    }

    /// One transport of each kind on a URL, recording into `recorder`.
    static func transports(
        http: String, socket: String, headers: [String: String],
        authorization: AuthorizationProvider? = nil, recorder: LogRecorder
    ) async throws -> [(name: String, transport: any MCPTransport)] {
        let streamable = StreamableHTTPTransport(
            url: try requireURL(http), headers: headers, authorization: authorization,
            openServerStream: false, connectionTimeout: 0.5)
        await streamable.useDiagnostics(recorder.logger())
        let legacy = HTTPSSETransport(
            url: try requireURL(http), headers: headers, authorization: authorization,
            connectionTimeout: 0.5, maxReconnectAttempts: 0)
        await legacy.useDiagnostics(recorder.logger())
        let webSocket = WebSocketTransport(
            url: try requireURL(socket), headers: headers, authorization: authorization,
            connectionTimeout: 0.5)
        await webSocket.useDiagnostics(recorder.logger())
        return [("StreamableHTTP", streamable), ("HTTPSSE", legacy), ("WebSocket", webSocket)]
    }

    @Test("Written exactly once per transport, however many times it connects", .timeLimit(.minutes(1)))
    func oncePerInstance() async throws {
        for (name, transport) in try await Self.transports(
            http: "http://0.0.0.0:1/mcp", socket: "ws://0.0.0.0:1/ws",
            headers: Self.credentials, recorder: LogRecorder()) {
            let recorder = LogRecorder()
            switch transport {
            case let transport as StreamableHTTPTransport: await transport.useDiagnostics(recorder.logger())
            case let transport as HTTPSSETransport: await transport.useDiagnostics(recorder.logger())
            case let transport as WebSocketTransport: await transport.useDiagnostics(recorder.logger())
            default: Issue.record("an unexpected transport: \(name)")
            }
            await Self.cycle(transport)
            await Self.cycle(transport)
            await Self.cycle(transport)

            let written = Self.warnings(in: recorder)
            #expect(written.count == 1, "\(name) wrote the warning \(written.count) times in three connects")
            #expect(written.first?.contains("http://0.0.0.0:1") == true || written.first?.contains("ws://0.0.0.0:1") == true,
                    "\(name) did not name the origin: \(written)")
            #expect(written.allSatisfy { !$0.contains("fixture-key-do-not-log") && !$0.contains("/mcp") && !$0.contains("/ws") },
                    "\(name) wrote more than the origin: \(written)")
        }
    }

    @Test("Written for a provider alone, with no static header", .timeLimit(.minutes(1)))
    func providerCounts() async throws {
        let recorder = LogRecorder()
        for (_, transport) in try await Self.transports(
            http: "http://0.0.0.0:1/mcp", socket: "ws://0.0.0.0:1/ws",
            headers: [:], authorization: { _ in "Bearer fixture" }, recorder: recorder) {
            await Self.cycle(transport)
        }
        #expect(Self.warnings(in: recorder).count == 3)
    }

    /// A host, whether the URL is TLS, and whether credentials are configured.
    struct Quiet: Sendable, CustomTestStringConvertible {
        let host: String
        let secure: Bool
        let credentials: Bool
        var testDescription: String { "\(secure ? "TLS" : "plaintext") to \(host), credentials: \(credentials)" }
    }

    @Test("Never written for loopback, for TLS, or with nothing to protect", .timeLimit(.minutes(1)),
          arguments: [
            Quiet(host: "127.0.0.1", secure: false, credentials: true),
            Quiet(host: "localhost", secure: false, credentials: true),
            Quiet(host: "[::1]", secure: false, credentials: true),
            Quiet(host: "0.0.0.0", secure: true, credentials: true),
            Quiet(host: "0.0.0.0", secure: false, credentials: false),
          ])
    func neverWritten(_ row: Quiet) async throws {
        let recorder = LogRecorder()
        for (_, transport) in try await Self.transports(
            http: "\(row.secure ? "https" : "http")://\(row.host):1/mcp",
            socket: "\(row.secure ? "wss" : "ws")://\(row.host):1/ws",
            headers: row.credentials ? Self.credentials : [:], recorder: recorder) {
            await Self.cycle(transport)
            await Self.cycle(transport)
        }
        #expect(Self.warnings(in: recorder).isEmpty, "\(row): \(Self.warnings(in: recorder))")
    }
}
