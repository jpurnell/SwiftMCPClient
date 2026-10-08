import Foundation
import Testing
import NIOCore
import NIOHTTP1
@testable import MCPClient

/// What a transport says when the network fails underneath it.
///
/// Until now it said whatever the networking library said: `connectionFailed` carried
/// `error.localizedDescription`. Each failure below was provoked and that text recorded
/// (macOS, AsyncHTTPClient on Network.framework and on NIO, WebSocketKit on NIO):
///
/// | Failure | `localizedDescription` | `String(describing:)` |
/// |---|---|---|
/// | connection refused | `…(AsyncHTTPClient.HTTPClient.NWPOSIXError error 1.)` | `POSIXErrorCode(rawValue: 61): Connection refused` |
/// | name not found | `…(Network.NWError error -65554 - NoSuchRecord)` | `-65554: NoSuchRecord` |
/// | connect timeout | `…(AsyncHTTPClient.HTTPClientError error 1.)` | `HTTPClientError.connectTimeout` |
/// | no answer by the deadline | `…(AsyncHTTPClient.HTTPClientError error 1.)` | `HTTPClientError.deadlineExceeded` |
/// | peer hangs up | `…(AsyncHTTPClient.HTTPClientError error 1.)` | `HTTPClientError.remoteConnectionClosed` |
/// | answer is not HTTP | `…(NIOHTTP1.HTTPParserError error 19.)` | `invalid constant string` |
/// | TLS to a plaintext port | `…(…NWTLSError error 1.)` / `…(NIOSSL.NIOSSLError error 0.)` | `-9836: bad protocol version` / `handshakeFailed(…sslError([… at /…/CNIOBoringSSL/ssl/tls_record.cc:125]))` |
/// | untrusted certificate | the same two | `-9808: bad certificate format` / `handshakeFailed(…CERTIFICATE_VERIFY_FAILED at /…/handshake.cc:288…)` |
/// | WebSocket refused | `…(NIOPosix.NIOConnectionError error 1.)` | `Connection errors: SingleConnectionFailure(target: [IPv4]127.0.0.1/127.0.0.1:1, …)` |
/// | WebSocket name not found | the same | `DNS error: … for host no-such-host.invalid, port 80` |
///
/// None of them carried the request's path, query, a header or any of the response. What the
/// transport passed on was the first column, which carries nothing at all: three different
/// failures read `HTTPClientError error 1`. And nothing made the second column's contents a
/// property of this library rather than of its dependencies' current wording — one of them
/// already prints a path from the machine the library was built on.
///
/// So the text is now composed here, from the error's type and case and the configured
/// origin, and these tests hold it to that: each failure is provoked against a URL whose
/// path, query and header are recognisable, and every rendering of the error is searched.
@Suite("Error text — a network failure is described by kind and origin")
struct TransportFailureTests {

    /// One way for the network to fail, and the words the transport should use for it.
    enum Failure: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case refused, silent, hangsUp, notHTTP, tlsToPlaintext, untrustedCertificate

        var testDescription: String { rawValue }

        /// What the reason is expected to say.
        var says: String {
            switch self {
            case .refused: return "connection refused"
            case .silent: return "no response before the deadline"
            case .hangsUp: return "the server closed the connection"
            case .notHTTP: return "the response was not valid HTTP"
            case .tlsToPlaintext, .untrustedCertificate: return "TLS"
            }
        }
    }

    /// A path segment and a query no error may repeat.
    static let pathKey = "k3y-9f8e7d6c5b4a39281706f5e4d3c2b1a0"
    static let query = "api_key=\(Watched.key)"

    /// Every way an error is turned into text.
    static func renderings(of error: any Error) -> [String] {
        [String(describing: error), String(reflecting: error), error.localizedDescription]
    }

    /// Stands up whatever provokes the failure and returns the URL to aim at, with a way to
    /// take it down again.
    static func target(
        for failure: Failure,
        scheme plain: String,
        secure: String
    ) async throws -> (url: URL, stop: @Sendable () async -> Void) {
        let path = "/mcp/\(pathKey)/x"
        switch failure {
        case .refused:
            // A listener that has been closed: the port was free a moment ago and nothing
            // has had time to take it.
            let gone = try await FaultStubServer.start(.silent)
            let url = try await gone.url(scheme: plain, path: path, query: query)
            try await gone.stopAndWait()
            return (url, {})
        case .silent:
            let server = try await FaultStubServer.start(.silent)
            return (try await server.url(scheme: plain, path: path, query: query), { await server.stop() })
        case .hangsUp:
            let server = try await FaultStubServer.start(.closesOnRequest)
            return (try await server.url(scheme: plain, path: path, query: query), { await server.stop() })
        case .notHTTP:
            let server = try await FaultStubServer.start(
                .garbage("NOT-HTTP \(Watched.bodyMarker)\r\nSet-Cookie: \(Watched.session)\r\n\r\n"))
            return (try await server.url(scheme: plain, path: path, query: query), { await server.stop() })
        case .tlsToPlaintext:
            let server = try await FaultStubServer.start(.garbage("HTTP/1.1 400 Bad Request\r\n\r\n"))
            return (try await server.url(scheme: secure, path: path, query: query), { await server.stop() })
        case .untrustedCertificate:
            let identity = try TestIdentity.selfSigned()
            let server = try await RedirectStubServer.start(kind: .streamable, tls: try identity.serverContext())
            var components = try #require(URLComponents(
                url: try await server.url(path: path, query: query), resolvingAgainstBaseURL: false))
            components.scheme = secure
            return (try #require(components.url), { await server.stop() })
        }
    }

    /// Checks one caught error against what it may and may not say.
    static func check(
        _ caught: (any Error)?,
        _ failure: Failure,
        origin: String,
        _ label: String,
        says expected: String? = nil
    ) throws {
        let says = expected ?? failure.says
        let error = try #require(caught, "\(label) \(failure): the request did not fail")
        for text in renderings(of: error) {
            #expect(!text.contains(pathKey), "\(label) \(failure): the error carries the path key: \(text)")
            #expect(!text.contains(Watched.key), "\(label) \(failure): the error carries the query: \(text)")
            #expect(!text.contains(Watched.bodyMarker), "\(label) \(failure): the error quotes the response: \(text)")
            #expect(!text.contains(Watched.session), "\(label) \(failure): the error quotes a response header: \(text)")
            #expect(!text.contains("/Users/") && !text.contains(".cc:"),
                    "\(label) \(failure): the error carries a build path: \(text)")
        }
        guard case .connectionFailed(let reason) = error as? MCPError else {
            Issue.record("\(label) \(failure): expected connectionFailed, got \(error)")
            return
        }
        // Host and port are origin-level, and are what says *which* server could not be reached.
        #expect(reason.contains(origin), "\(label) \(failure): the reason does not name \(origin): \(reason)")
        #expect(reason.contains(says), "\(label) \(failure): the reason does not say '\(says)': \(reason)")
        #expect(!reason.contains("The operation couldn’t be completed"),
                "\(label) \(failure): the reason is the library's placeholder: \(reason)")
    }

    @Test("Streamable HTTP: a failed POST names the kind of failure and the origin, and nothing else",
          .timeLimit(.minutes(2)),
          arguments: Failure.allCases, [false, true])
    func streamable(_ failure: Failure, _ pinned: Bool) async throws {
        // `pinned` runs the request on NIO's own stack instead of Network.framework: the two
        // report the same failure as different types.
        let trust: ServerTrust = pinned ? try .onlyRoots([.pem(try TestIdentity.selfSigned().pem)]) : .system
        let (url, stop) = try await Self.target(for: failure, scheme: "http", secure: "https")
        let transport = StreamableHTTPTransport(
            url: url, headers: [Watched.keyHeader: Watched.key],
            openServerStream: false, connectionTimeout: 1.5, serverTrust: trust)
        try await transport.connect()

        var caught: (any Error)?
        do {
            try await transport.send(Watched.body)
        } catch {
            caught = error
        }
        #expect(caught is MCPError, "the failure reached the caller as \(String(describing: caught))")
        try Self.check(caught, failure, origin: HTTPOrigin.description(of: url), "streamable/\(pinned ? "NIO" : "platform")")
        try await transport.disconnect()
        await stop()
    }

    @Test("HTTP+SSE: a failed connect names the kind of failure and the origin, and nothing else",
          .timeLimit(.minutes(2)),
          arguments: Failure.allCases)
    func legacy(_ failure: Failure) async throws {
        let (url, stop) = try await Self.target(for: failure, scheme: "http", secure: "https")
        let transport = HTTPSSETransport(
            url: url, headers: [Watched.keyHeader: Watched.key],
            connectionTimeout: 1.5, maxReconnectAttempts: 0)

        var caught: (any Error)?
        do {
            try await transport.connect()
        } catch {
            caught = error
        }
        #expect(caught is MCPError, "the failure reached the caller as \(String(describing: caught))")
        try Self.check(caught, failure, origin: HTTPOrigin.description(of: url), "sse")
        try await transport.disconnect()
        await stop()
    }

    /// A peer that takes the connection and then says nothing — or hangs up without
    /// answering the upgrade — left `connect()` waiting forever: `WebSocketKit`'s upgrade has
    /// no timeout of its own and reports neither. Both now end at the connection timeout,
    /// and both therefore read as the deadline: the hang-up is not something `WebSocketKit`
    /// passes on, so the transport cannot tell it from silence.
    @Test("WebSocket: a failed connect names the kind of failure and the origin, and returns",
          .timeLimit(.minutes(2)),
          arguments: Failure.allCases)
    func webSocket(_ failure: Failure) async throws {
        let (url, stop) = try await Self.target(for: failure, scheme: "ws", secure: "wss")
        let transport = WebSocketTransport(
            url: url, headers: [Watched.keyHeader: Watched.key],
            authorization: nil, connectionTimeout: 1.5)

        var caught: (any Error)?
        do {
            try await transport.connect()
        } catch {
            caught = error
        }
        try Self.check(
            caught, failure, origin: HTTPOrigin.description(of: url), "ws",
            says: failure == .hangsUp ? Failure.silent.says : failure.says)
        #expect(HTTPOrigin.description(of: url).hasPrefix(failure == .tlsToPlaintext || failure == .untrustedCertificate ? "wss://" : "ws://"))
        try await transport.disconnect()
        await stop()
    }

    /// The unit under all of the above: an error it has never heard of is named by its type,
    /// and never by its own description.
    @Test("An unrecognised error is named by its type, never by its description")
    func unrecognised() throws {
        struct Chatty: Error, CustomStringConvertible, LocalizedError {
            var description: String { "GET https://mcp.example/mcp?api_key=\(Watched.key) failed" }
            var errorDescription: String? { description }
        }
        let url = try requireURL("https://user:hunter2@mcp.example:8443/mcp/\(Self.pathKey)?api_key=\(Watched.key)")
        let reason = TransportFailure.reason(for: Chatty(), reaching: url)
        #expect(!reason.contains(Watched.key))
        #expect(!reason.contains("hunter2"))
        #expect(!reason.contains(Self.pathKey))
        #expect(reason.contains("https://mcp.example:8443"))
        #expect(reason.contains("Chatty"))
    }

    /// A transport's own error is already composed, and is not wrapped in a second one.
    @Test("An MCPError is passed through as it is")
    func ownErrorsPassThrough() throws {
        let url = try requireURL("https://mcp.example/mcp")
        #expect(TransportFailure.reason(for: MCPError.timeout, reaching: url)
                == "Could not reach https://mcp.example: the request timed out")
        #expect(TransportFailure.reason(for: CancellationError(), reaching: url)
                == "Could not reach https://mcp.example: the request was cancelled")
    }
}
