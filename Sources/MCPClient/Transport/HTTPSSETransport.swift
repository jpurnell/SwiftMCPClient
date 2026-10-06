import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import NIOSSL
import Logging

/// Connects to a remote MCP server via HTTP POST (requests) and Server-Sent Events (responses).
///
/// This is the primary transport for production use, connecting to a hosted MCP server
/// (e.g., a GeoSEO MCP server at `https://mcp.example.com`).
///
/// ## MCP SSE Protocol
///
/// 1. **Connect:** Opens a `GET` request to the SSE endpoint. The server sends an
///    `endpoint` event containing the URL for JSON-RPC POST requests.
/// 2. **Send:** POSTs JSON-RPC data to the endpoint URL.
/// 3. **Receive:** Yields JSON-RPC responses from SSE `message` events.
/// 4. **Disconnect:** Cancels the SSE stream.
///
/// ## The Endpoint Stays on the Stream's Origin
///
/// The `endpoint` event is the server telling the client where to send everything else —
/// including the `Authorization` header. It is usually a path, but it is resolved as a URL
/// reference, so it can name another host outright. This transport accepts it only if it
/// resolves to the **same origin** as the `url` it was created with: the same scheme, the
/// same host, and the same port (a port left out being the scheme's default). An endpoint
/// that carries userinfo (`user@host`) is refused as well, and a fragment is dropped.
///
/// Anything else fails ``connect()`` with ``MCPError/endpointRejected(endpoint:reason:)``.
/// Nothing is sent to the endpoint, and the connect is not retried. This matches the
/// TypeScript and Python reference clients; the 2024-11-05 specification itself says only
/// that the event contains "a URI". There is no setting that widens it.
///
/// ## Reconnection
///
/// If the SSE stream drops during ``connect()``, the transport automatically
/// retries up to `maxReconnectAttempts` times with exponential backoff
/// starting from `reconnectBaseDelay`.
///
/// ## Cross-Platform
///
/// Uses `AsyncHTTPClient` for HTTP on every platform. TLS is the platform's own
/// on Apple platforms and NIOSSL's on Linux, both verifying against the system
/// roots. A self-signed or privately issued server certificate is trusted by
/// supplying it — see ``ServerTrust`` — and a transport given one verifies with
/// NIOSSL everywhere, so that case behaves identically on macOS and Linux.
public actor HTTPSSETransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]

    /// Asked for a current `Authorization` header before each request.
    ///
    /// The stream is the limit here. A header cannot be changed on a request that is already
    /// open, so a token expiring mid-stream is recoverable only at the next reconnect — which
    /// is inherent to a long-lived GET, not something this could fix. What it does fix is every
    /// POST, and the token the stream carries when it is next opened.
    private let authorization: AuthorizationProvider?
    private let connectionTimeout: TimeAmount
    private let maxReconnectAttempts: Int
    private let reconnectBaseDelay: TimeInterval
    private let serverTrust: ServerTrust

    /// The endpoint URL extracted from the SSE `endpoint` event during connect.
    private var endpointURL: URL?

    /// The HTTP client used for all requests.
    private var httpClient: HTTPClient?

    /// Queue of received JSON-RPC messages from SSE `message` events.
    private var messageQueue: [Data] = []

    /// Continuation for waiting `receive()` calls when no messages are queued.
    private var messageContinuation: CheckedContinuation<Data, any Error>?

    /// The background task reading the SSE stream.
    private var streamTask: Task<Void, Never>?

    /// Whether the transport is currently connected.
    private var isConnected: Bool = false

    /// Creates a new HTTP/SSE transport.
    ///
    /// - Parameters:
    ///   - url: The SSE endpoint URL (e.g., `https://mcp.example.com/sse`).
    ///   - headers: Custom HTTP headers sent with all requests (e.g., authentication).
    ///   - authorization: Asked for a current `Authorization` header before each POST, again
    ///     after a `401`, and when the stream is opened. Supplying one is how a session that
    ///     refreshes reaches the wire; without it the header in `headers` is frozen for the
    ///     life of the transport.
    ///   - connectionTimeout: Maximum time to wait for the initial endpoint event. Default 30s.
    ///   - maxReconnectAttempts: Number of reconnection attempts on stream drop. Default 3.
    ///   - reconnectBaseDelay: Base delay for exponential backoff in seconds. Default 1.0.
    ///   - serverTrust: Which certificate roots an `https://` server may chain to. Defaults
    ///     to ``ServerTrust/system``. For a self-signed or privately issued certificate,
    ///     supply it with ``ServerTrust/onlyRoots(_:)`` or ``ServerTrust/additionalRoots(_:)``;
    ///     the chain and the hostname are verified either way.
    public init(
        url: URL,
        headers: [String: String] = [:],
        authorization: AuthorizationProvider? = nil,
        connectionTimeout: TimeInterval = 30.0,
        maxReconnectAttempts: Int = 3,
        reconnectBaseDelay: TimeInterval = 1.0,
        serverTrust: ServerTrust = .system
    ) {
        self.url = url
        self.headers = headers
        self.authorization = authorization
        self.connectionTimeout = .seconds(clamping: connectionTimeout)
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBaseDelay = reconnectBaseDelay
        self.serverTrust = serverTrust
    }

    /// Removed: this did not trust a self-signed certificate, it disabled verification.
    ///
    /// Passing `true` set NIOSSL's `certificateVerification` to `.none`, which accepts any
    /// certificate from anyone. Supply the certificate instead — see ``ServerTrust``.
    ///
    /// - Parameters:
    ///   - url: The SSE endpoint URL.
    ///   - headers: Custom HTTP headers sent with all requests.
    ///   - authorization: Asked for a current `Authorization` header.
    ///   - connectionTimeout: Maximum time to wait for the initial endpoint event.
    ///   - maxReconnectAttempts: Number of reconnection attempts on stream drop.
    ///   - reconnectBaseDelay: Base delay for exponential backoff in seconds.
    ///   - trustSelfSignedCertificates: Ignored. Verification is never disabled.
    @available(*, unavailable, message: "This disabled certificate verification entirely. Pass serverTrust: try .onlyRoots([.pemFile(path)]) (or .additionalRoots) with the server's certificate; omit the argument where it was false.")
    public init(
        url: URL,
        headers: [String: String] = [:],
        authorization: AuthorizationProvider? = nil,
        connectionTimeout: TimeInterval = 30.0,
        maxReconnectAttempts: Int = 3,
        reconnectBaseDelay: TimeInterval = 1.0,
        trustSelfSignedCertificates: Bool
    ) {
        self.url = url
        self.headers = headers
        self.authorization = authorization
        self.connectionTimeout = .seconds(clamping: connectionTimeout)
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBaseDelay = reconnectBaseDelay
        self.serverTrust = .system
    }

    /// The TLS configuration every request is made with.
    nonisolated var tlsConfiguration: TLSConfiguration {
        serverTrust.makeTLSConfiguration()
    }

    /// Open the SSE connection to the MCP server, retrying with exponential backoff on failure.
    ///
    /// - Throws: ``MCPError/endpointRejected(endpoint:reason:)``, without retrying, if the
    ///   server's `endpoint` event names a URL off the origin of the configured stream;
    ///   otherwise the last attempt's error once the retries are spent.
    public func connect() async throws {
        let logger = Logger(label: "MCPClient.HTTPSSETransport")
        var lastError: (any Error)?

        // The same policy the Streamable HTTP server stream uses, rather than a second copy
        // of the arithmetic. Inline, it could only be checked by sleeping, and it grew without
        // bound — a caller raising `maxReconnectAttempts` was quietly buying delays measured
        // in hours.
        let backoff = StreamBackoff(base: .seconds(reconnectBaseDelay), ceiling: .seconds(30))

        for attempt in 0...maxReconnectAttempts {
            let delay = backoff.delay(forAttempt: attempt)
            if delay > .zero {
                try await Task.sleep(for: delay)
            }

            do {
                try await performConnect()
                return
            } catch let MCPError.endpointRejected(endpoint, reason) {
                // Not retried. This is a decision about the server, not a failure of the
                // network: another attempt re-opens the stream, credentials attached, to be
                // told the same thing.
                // logging: swift-log has no privacy annotations; an origin only — no path, query, userinfo or header
                logger.error("Refused the server's message endpoint on \(endpoint): \(reason)")
                if let client = httpClient {
                    httpClient = nil
                    // silent: best-effort cleanup; the refusal is the error that matters
                    try? await client.shutdown()
                }
                throw MCPError.endpointRejected(endpoint: endpoint, reason: reason)
            } catch {
                lastError = error
                // logging: swift-log Logger does not support privacy annotations
                logger.warning("SSE connect attempt \(attempt) failed: \(error.localizedDescription)")
                // Clean up the HTTP client on failure so it doesn't leak
                if let client = httpClient {
                    httpClient = nil
                    // silent: best-effort cleanup during retry loop
                    try? await client.shutdown()
                }
            }
        }

        throw lastError ?? MCPError.connectionFailed(
            reason: "Failed to connect after \(maxReconnectAttempts) retries"
        )
    }

    /// Cancel the SSE stream and shut down the HTTP client.
    public func disconnect() async throws {
        streamTask?.cancel()
        streamTask = nil
        endpointURL = nil
        isConnected = false
        messageQueue.removeAll()

        // Fail any waiting receive() call
        messageContinuation?.resume(throwing: MCPError.connectionFailed(reason: "Disconnected"))
        messageContinuation = nil

        // Shut down the HTTP client
        if let client = httpClient {
            httpClient = nil
            // silent: best-effort shutdown during disconnect
            try? await client.shutdown()
        }
    }

    /// Post a JSON-RPC message to the server's endpoint URL.
    public func send(_ data: Data) async throws {
        guard let endpointURL = endpointURL, let client = httpClient else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        var response = try await post(data, to: endpointURL, on: client, forcingRefresh: false)

        // One retry, and only for a refusal — the same recovery the Streamable HTTP transport
        // has, for the same reason: a revoked grant or an expired registration is invisible to
        // a clock, and arrives only as a 401. Once, not in a loop: a server refusing a
        // just-refreshed token is refusing the grant.
        if response.status.code == 401, authorization != nil {
            response = try await post(data, to: endpointURL, on: client, forcingRefresh: true)
        }

        guard (200...299).contains(response.status.code) else {
            throw MCPError.requestFailed(
                code: Int(response.status.code),
                message: "HTTP \(response.status.code) from POST to \(endpointURL.absoluteString)",
                data: nil
            )
        }

        // Some MCP servers return the JSON-RPC response directly in the POST
        // response body rather than via the SSE stream.
        let body = try await response.body.collect(upTo: 10 * 1024 * 1024) // 10MB limit
        let responseData = Data(buffer: body)
        if !responseData.isEmpty {
            enqueueMessage(responseData)
        }
    }

    /// Makes one POST, with a freshly resolved `Authorization` header.
    ///
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the request could not be made, or
    ///   whatever the provider threw. A provider that fails **fails the send**: continuing
    ///   unauthenticated reaches the server as a `401`, which reads as a credential problem at
    ///   the far end rather than a local one.
    private func post(
        _ data: Data,
        to endpointURL: URL,
        on client: HTTPClient,
        forcingRefresh: Bool
    ) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: endpointURL.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }
        try await applyAuthorization(to: &request, forcingRefresh: forcingRefresh)
        request.body = .bytes(data)

        do {
            return try await client.execute(request, timeout: connectionTimeout)
        } catch {
            throw MCPError.connectionFailed(reason: error.localizedDescription)
        }
    }

    /// Puts a current token on a request, if this transport was given a way to get one.
    ///
    /// Applied after the static headers, so a live session wins over a token pasted into
    /// configuration — both present means the pasted one is the leftover.
    private func applyAuthorization(
        to request: inout HTTPClientRequest,
        forcingRefresh: Bool
    ) async throws {
        guard let authorization else { return }
        if let header = try await authorization(forcingRefresh) {
            request.headers.replaceOrAdd(name: "Authorization", value: header)
        } else {
            // `nil` means not signed in, which is a request with no header — not one carrying
            // `Bearer` and nothing after it.
            request.headers.remove(name: "Authorization")
        }
    }

    /// Return the next queued SSE message, or suspend until one arrives.
    public func receive() async throws -> Data {
        guard isConnected else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        // If we already have a queued message, return it immediately
        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }

        // Wait for the next message from the SSE stream
        return try await withCheckedThrowingContinuation { continuation in
            self.messageContinuation = continuation
        }
    }

    // MARK: - Connection

    private func performConnect() async throws {
        // A client already here is one this transport is responsible for. Replacing it without
        // shutting it down orphans it, and `AsyncHTTPClient` traps in `deinit` rather than
        // leaking quietly — so the cost of forgetting is the process, not memory.
        if let existing = httpClient {
            httpClient = nil
            // A shutdown that fails still leaves nothing referencing the client, and the
            // connection being established is what the caller is actually waiting on.
            // silent: a failed shutdown still leaves the client unreferenced
            try? await existing.shutdown()
        }

        let client = makeHTTPClient()
        self.httpClient = client

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "Accept", value: "text/event-stream")
        request.headers.add(name: "Cache-Control", value: "no-cache")
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }
        // Resolved each time the stream is opened, so a reconnect after a token expired does
        // not present the token that had already stopped working.
        try await applyAuthorization(to: &request, forcingRefresh: false)

        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, timeout: connectionTimeout)
        } catch {
            throw MCPError.connectionFailed(reason: error.localizedDescription)
        }

        guard (200...299).contains(response.status.code) else {
            throw MCPError.connectionFailed(
                reason: "SSE endpoint returned HTTP \(response.status.code)"
            )
        }

        // Create a single iterator — NIO async sequences only allow one.
        // We read until we find the endpoint event, then hand the iterator
        // off to a background task for ongoing SSE messages.
        var iterator = response.body.makeAsyncIterator()
        var parser = SSEParser()

        while let buffer = try await iterator.next() {
            guard let text = String(buffer: buffer, encoding: .utf8) else { continue }
            let events = parser.append(text)

            for event in events {
                if event.event == "endpoint" {
                    // Held to the origin of `url` — see `resolveEndpoint`. A refusal throws
                    // from here, before the endpoint is stored and so before anything can be
                    // sent to it.
                    let resolvedEndpoint = try Self.resolveEndpoint(event.data, against: url)

                    self.endpointURL = resolvedEndpoint
                    self.isConnected = true

                    // Queue any messages that arrived in the same chunk
                    for laterEvent in events where laterEvent.event == "message" || laterEvent.event == nil {
                        if laterEvent.data != event.data,
                           let data = laterEvent.data.data(using: .utf8) {
                            messageQueue.append(data)
                        }
                    }

                    // Hand off the iterator to a background task
                    startBackgroundStream(iterator: iterator, parser: parser)
                    return

                } else if event.event == "message" || event.event == nil {
                    // Messages before endpoint — queue them
                    if let data = event.data.data(using: .utf8) {
                        messageQueue.append(data)
                    }
                }
            }
        }

        // If we get here, the stream ended without an endpoint event
        throw MCPError.connectionFailed(reason: "No endpoint event received from SSE stream")
    }

    // MARK: - Endpoint Origin

    /// Turns the server's `endpoint` event into the URL messages are POSTed to, or refuses it.
    ///
    /// The value is the server's to choose and is resolved as an RFC 3986 reference, so it is
    /// not necessarily a path: an absolute URL replaces the whole origin, and so does
    /// `//host/path`. Whatever it resolves to is where the caller's credentials go, which is
    /// why the result is held to the origin of the stream the caller configured:
    ///
    /// - **Same scheme, host and effective port.** Compared as parsed components, never as
    ///   string prefixes; scheme and host case-insensitively; a port left out is the scheme's
    ///   default. `http` for an `https` stream is a different origin, and refused.
    /// - **No userinfo.** `user@host` is refused even on the right host. Nothing needs it, and
    ///   `good.example@evil.test` is how a URL is made to read as one host and reach another.
    /// - **No fragment.** Dropped, not refused: it is never sent in a request.
    ///
    /// A relative reference cannot fail any of these — `..` stops at the root of the origin —
    /// so a server that sends a path, as almost all do, sees no difference.
    ///
    /// - Parameters:
    ///   - raw: The `data` of the `endpoint` event.
    ///   - streamURL: The SSE URL the transport was configured with.
    /// - Returns: The URL to POST to, on `streamURL`'s origin and with no fragment.
    /// - Throws: ``MCPError/endpointRejected(endpoint:reason:)`` if the endpoint is on another
    ///   origin or carries userinfo; ``MCPError/connectionFailed(reason:)`` if it is not a URL.
    static func resolveEndpoint(_ raw: String, against streamURL: URL) throws -> URL {
        guard let resolved = URL(string: raw, relativeTo: streamURL)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            throw MCPError.connectionFailed(reason: "Invalid endpoint URL: \(raw)")
        }
        components.fragment = nil

        // Re-read from the string, because the string is what the HTTP client is handed. A
        // check made on one parse and a request made from another is the gap this closes.
        guard let text = components.string, let endpoint = URL(string: text) else {
            throw MCPError.connectionFailed(reason: "Invalid endpoint URL: \(raw)")
        }

        let expected = originDescription(of: streamURL)
        let named = originDescription(of: endpoint)

        guard endpoint.user == nil, endpoint.password == nil else {
            throw MCPError.endpointRejected(
                endpoint: named,
                reason: "The server's endpoint event carries credentials in its URL; "
                    + "expected a plain endpoint on \(expected)")
        }

        // The origin, component by component. Each side is parsed; nothing here is a prefix
        // or a substring test, so `good.example.evil.test` is simply a different host.
        guard let expectedScheme = streamURL.scheme?.lowercased(),
              let expectedHost = streamURL.host?.lowercased(), !expectedHost.isEmpty,
              let expectedPort = effectivePort(of: streamURL),
              endpoint.scheme?.lowercased() == expectedScheme,
              endpoint.host?.lowercased() == expectedHost,
              effectivePort(of: endpoint) == expectedPort else {
            throw MCPError.endpointRejected(
                endpoint: named,
                reason: "Endpoint origin does not match connection origin \(expected); "
                    + "nothing was sent to it")
        }
        return endpoint
    }

    /// The port a URL's requests go to: the one it names, else its scheme's default.
    ///
    /// - Parameter url: An absolute URL.
    /// - Returns: `nil` unless the scheme is `http` or `https` — nothing else is a place this
    ///   transport can POST to, so nothing else has a port worth comparing.
    private static func effectivePort(of url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return url.port ?? 443
        case "http": return url.port ?? 80
        default: return nil
        }
    }

    /// `scheme://host[:port]` — what an error or a log line may say about a URL.
    ///
    /// Userinfo, path and query are left out on purpose: the first is a credential, and a
    /// legacy endpoint's query is usually the session id.
    private static func originDescription(of url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return "(no origin)"
        }
        let authority = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port else { return "\(scheme)://\(authority)" }
        return "\(scheme)://\(authority):\(port)"
    }

    /// Continue reading SSE messages in the background using the same iterator.
    private func startBackgroundStream(
        iterator: sending HTTPClientResponse.Body.AsyncIterator,
        parser: sending SSEParser
    ) {
        // Justification: iterator and parser are transferred via `sending` and used only inside this Task
        nonisolated(unsafe) var iterator = iterator
        // Justification: parser is transferred via `sending` and used only inside this Task
        nonisolated(unsafe) var parser = parser
        streamTask = Task { [weak self] in
            do {
                while let buffer = try await iterator.next() {
                    guard let self = self else { return }
                    guard let text = String(buffer: buffer, encoding: .utf8) else { continue }
                    let events = parser.append(text)

                    for event in events {
                        guard event.event == "message" || event.event == nil else { continue }
                        // An event carrying no data is a keep-alive, not a message. Handing an
                        // empty payload to a JSON-RPC decoder reports the response as invalid
                        // when the server did nothing wrong.
                        guard !event.data.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let data = event.data.data(using: .utf8) else { continue }
                        await self.enqueueMessage(data)
                    }
                }
            } catch is CancellationError {
                // A disconnect cancels this task, and a cancelled stream is not a failed one.
                // Logged at debug because "SSE stream ended with error" on every clean
                // shutdown trains an operator to ignore the line that matters.
                let logger = Logger(label: "MCPClient.HTTPSSETransport")
                // logging: an expected end, kept below warning so a real failure stands out
                logger.debug("SSE stream cancelled by disconnect")
            } catch {
                let logger = Logger(label: "MCPClient.HTTPSSETransport")
                // logging: swift-log Logger does not support privacy annotations
                logger.warning("SSE stream ended with error: \(error.localizedDescription)")
            }

            // Stream has ended
            guard let self = self else { return }
            await self.handleStreamEnd()
        }
    }

    // MARK: - HTTP Client Factory

    private func makeHTTPClient() -> HTTPClient {
        serverTrust.makeHTTPClient(connectTimeout: connectionTimeout)
    }

    // MARK: - Message Handling

    /// Enqueue a received message, or deliver it directly to a waiting continuation.
    private func enqueueMessage(_ data: Data) {
        if let continuation = messageContinuation {
            messageContinuation = nil
            continuation.resume(returning: data)
        } else {
            messageQueue.append(data)
        }
    }

    /// Handle the SSE stream ending unexpectedly.
    private func handleStreamEnd() {
        isConnected = false
        if let continuation = messageContinuation {
            messageContinuation = nil
            continuation.resume(throwing: MCPError.connectionFailed(reason: "SSE stream terminated"))
        }
    }
}

// MARK: - NIO ByteBuffer String Extension

private extension String {
    init?(buffer: NIOCore.ByteBuffer, encoding: String.Encoding = .utf8) {
        var buf = buffer
        guard let string = buf.readString(length: buf.readableBytes) else { return nil }
        self = string
    }
}
