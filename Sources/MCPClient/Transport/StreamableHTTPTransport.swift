import Foundation
import Logging
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import NIOSSL

/// Supplies a current `Authorization` header value, refreshing if it has to.
///
/// Consulted once per request, and once more with `forcingRefresh` set after the server
/// refuses one. The two are different questions: the ordinary call asks for a token that is
/// valid by the clock, and the forced call asks for one obtained *now*, because a grant the
/// provider has revoked still looks valid to every clock on this side.
///
/// Returning `nil` sends the request with no `Authorization` header at all.
public typealias AuthorizationProvider = @Sendable (_ forcingRefresh: Bool) async throws -> String?

/// Connects to a remote MCP server via Streamable HTTP (MCP spec 2025-03-26).
///
/// Requests go out as `POST /mcp`; the server answers either with one JSON document or with an
/// SSE stream it may hold open while it works. Alongside them runs a single client-initiated
/// `GET` to the same endpoint, carrying the messages the *server* originates — progress,
/// log messages, sampling requests, list-changed notifications. Both feed the same
/// ``receive()`` queue, which is what makes this a multiplexer rather than a request/response
/// client (ADR-002).
///
/// Session continuity is the `Mcp-Session-Id` header, and every request after initialization
/// also carries the negotiated `MCP-Protocol-Version`.
///
/// ## Protocol Flow
///
/// 1. **Connect:** Creates the HTTP client (no network call needed).
/// 2. **Send:** POSTs JSON-RPC to `/mcp`. A JSON response is queued whole; an SSE response is
///    consumed as it arrives, so ``send(_:)`` returns once the request is answered rather than
///    when the work finishes — a progress notification delivered after the response closes is
///    not a progress notification.
/// 3. **Server stream:** once initialization completes, a `GET` opens the server-initiated
///    channel. A `405` means the server originates nothing, which is not an error; a dropped
///    stream reconnects with `Last-Event-ID` and a deliberately gentle backoff, because
///    nothing is blocked on it.
/// 4. **Receive:** Returns the next queued message from either source, or suspends until one
///    arrives.
/// 5. **Disconnect:** Cancels the server stream and every in-flight response, sends
///    `DELETE /mcp` to terminate the session, then shuts down the HTTP client.
///
/// ## Compared with legacy HTTP+SSE
///
/// The difference is what a dead stream costs. Legacy HTTP+SSE dies with its stream, because
/// that is its only channel for responses. Here, request and response keep working when the
/// server stream is gone — only server-initiated messages stop. That is why the two transports
/// are separate types rather than one with a mode flag: the failure modes differ, and a flag
/// hides exactly the difference that matters.
///
/// A caller that wants the earlier POST-only behaviour passes `openServerStream: false`.
///
/// ## Cross-Platform
///
/// Uses `AsyncHTTPClient` (Swift NIO) for HTTP and TLS, providing identical
/// behavior on macOS and Linux.
public actor StreamableHTTPTransport: MCPTransport {
    private let url: URL
    /// Session identity, the negotiated version, and the last event seen on each stream.
    private let session = StreamableHTTPSession()

    /// Whether the server-initiated stream should be opened after initialization.
    private let opensServerStream: Bool

    /// The one server-initiated stream, while it is running.
    ///
    /// One at a time: the specification permits a single `GET` stream, and a client that opens
    /// another on every prompt leaks them server-side.
    private var serverStreamTask: Task<Void, Never>?

    /// Tasks draining SSE response bodies into the receive queue.
    ///
    /// One per in-flight streaming response. They outlive `send(_:)` deliberately — that is
    /// what lets a response be consumed while the server is still writing it.
    private var responsePumps: [Task<Void, Never>] = []

    private var headers: [String: String]

    /// Asked for a current `Authorization` header before each request.
    private let authorization: AuthorizationProvider?
    private let connectionTimeout: TimeInterval
    private let trustSelfSignedCertificates: Bool

    /// The HTTP client used for all requests.
    private var httpClient: HTTPClient?

    /// Session ID returned by the server on initialize.
    /// The session id the server assigned, if it assigned one.
    ///
    /// Derived rather than stored: the session state owns session identity, and a
    /// second copy here would be a second thing to keep in step. Reading it across the actor
    /// boundary was already `await`ed, so this is not a change a caller can see.
    public var sessionId: String? {
        get async { await session.sessionID }
    }

    /// Queue of received JSON-RPC messages from POST response bodies.
    private var messageQueue: [Data] = []

    /// Continuation for waiting `receive()` calls when no messages are queued.
    private var messageContinuation: CheckedContinuation<Data, any Error>?

    /// Whether the transport has been connected.
    private var isConnected: Bool = false

    /// Creates a new Streamable HTTP transport.
    ///
    /// - Parameters:
    ///   - url: The MCP endpoint URL (e.g., `https://mcp.example.com/mcp`).
    ///   - headers: Custom HTTP headers sent with all requests (e.g., authentication).
    ///   - authorization: Asked for a current `Authorization` header before every request,
    ///     and again after a `401`. Supplying one is how a session that refreshes reaches the
    ///     wire; without it the header in `headers` is sent unchanged for the life of the
    ///     transport, which outlives the token on any provider that expires them.
    ///   - openServerStream: Whether to open the specification's client-initiated `GET`
    ///     stream once initialization completes. Defaults to `true`. A server that offers no
    ///     such channel answers `405`, which is not an error — the client simply has no
    ///     server-initiated messages. Passing `false` restores the POST-only behaviour of
    ///     ADR-001 exactly.
    ///   - connectionTimeout: Maximum time to wait for each HTTP request. Default 30s.
    ///   - trustSelfSignedCertificates: Accept self-signed or invalid TLS certificates.
    ///     **Use only for development/testing** — this disables certificate validation.
    public init(
        url: URL,
        headers: [String: String] = [:],
        authorization: AuthorizationProvider? = nil,
        openServerStream: Bool = true,
        connectionTimeout: TimeInterval = 30.0,
        trustSelfSignedCertificates: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.authorization = authorization
        self.opensServerStream = openServerStream
        self.connectionTimeout = connectionTimeout
        self.trustSelfSignedCertificates = trustSelfSignedCertificates
    }

    /// Replaces the `Authorization` header used by subsequent requests.
    ///
    /// An OAuth access token outlives neither a long survey of a server's tools nor, on some
    /// providers, a lunch break. Rebuilding the transport to carry a refreshed token would
    /// discard the session the server is tracking by `Mcp-Session-Id`; replacing the header
    /// in place keeps it.
    ///
    /// - Parameter header: A complete header value, such as `"Bearer eyJ…"`. Passing `nil`
    ///   removes the header, which is how a sign-out is expressed.
    public func updateAuthorization(_ header: String?) {
        if let header {
            headers["Authorization"] = header
        } else {
            headers.removeValue(forKey: "Authorization")
        }
    }

    /// Adopts the protocol version the server accepted, for every later request to echo.
    ///
    /// - Parameter protocolVersion: The version from the initialization result.
    public func didNegotiate(protocolVersion: String) async {
        await session.adopt(protocolVersion: protocolVersion)
        // Opened here rather than in `connect()`, because this is the moment the transport
        // learns initialization happened. Opening it earlier asks a server to start a
        // session-scoped channel for a session that does not exist yet.
        startServerStream()
    }

    /// Opens the server-initiated stream, if it is wanted and not already running.
    private func startServerStream() {
        guard opensServerStream, serverStreamTask == nil, isConnected else { return }
        // lifecycle: cancelled in `disconnect()`.
        serverStreamTask = Task { await self.runServerStream() }
    }

    /// Keeps the server-initiated stream open, reconnecting when it drops.
    ///
    /// Losing this stream is not fatal — request and response keep working without it — so it
    /// backs off gently rather than hammering a server to restore a channel nothing is
    /// blocked on. A `405` ends the loop for good: the server has said it has no such channel,
    /// and asking again on a schedule would be asking the same question forever.
    private func runServerStream() async {
        var attempt = 0
        // Tracked apart from `attempt`, because they answer different questions. The attempt
        // count decides how long to wait and resets whenever a stream delivered something; a
        // reconnect is a reconnect regardless. Deriving one from the other drops
        // `Last-Event-ID` from exactly the reconnect that most needs it — the one following a
        // healthy stream that ended.
        var isReconnect = false

        while !Task.isCancelled {
            let delay = StreamBackoff.serverStream.delay(forAttempt: attempt)
            if delay > .zero {
                // silent: a cancelled sleep is the disconnect path, checked on the next line
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }

            do {
                guard let body = try await openServerStream(resuming: isReconnect ? .get : nil) else {
                    return
                }
                isReconnect = true
                var delivered = false
                for try await event in SSEEventStream.events(from: body) {
                    guard !Task.isCancelled else { return }
                    if let id = event.id {
                        await session.record(eventID: id, for: .get)
                    }
                    enqueueMessage(Data(event.data.utf8))
                    delivered = true
                }

                // A cancelled stream ends the same way a finished one does — quietly — so the
                // reason has to be established before anything acts on it. Without this, a
                // disconnect is scored as a server that closed early and feeds the backoff.
                guard !Task.isCancelled else { return }

                // A clean close is the server exercising its right to disconnect, which
                // 2025-11-25 (SEP-1699) explicitly permits and expects clients to poll
                // through. Whether it delivered anything first does not change what happened:
                // scoring a quiet close as trouble climbs the backoff until a healthy but
                // idle server is checked once an hour.
                //
                // Failures escalate — that is the `catch` below. This path is only ever a
                // stream that ended without error.
                attempt = delivered ? 0 : StreamBackoff.pollingAttempt
            } catch {
                attempt += 1
                let logger = Logger(label: "MCPClient.StreamableHTTPTransport")
                // logging: why the server stream dropped, which no caller is awaiting
                logger.debug("server stream dropped: \(error.localizedDescription)")
            }
        }
    }

    /// Asks the server to open its stream.
    ///
    /// - Parameter resuming: Whether to carry `Last-Event-ID` and pick up where the previous
    ///   stream stopped.
    /// - Returns: The stream body, or `nil` if the server offers no such channel.
    private func openServerStream(resuming stream: StreamableHTTPSession.StreamKind?) async throws -> HTTPClientResponse.Body? {
        guard let client = httpClient else { return nil }

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "Accept", value: "text/event-stream")
        for (key, value) in await session.headers(resuming: stream) {
            request.headers.replaceOrAdd(name: key, value: value)
        }
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }
        if let authorization, let header = try await authorization(false) {
            request.headers.replaceOrAdd(name: "Authorization", value: header)
        }

        let response = try await client.execute(request, timeout: .seconds(Int64(connectionTimeout)))

        // 405 is a conformant server saying it originates no messages. Not a failure, and not
        // something to retry: the answer will not change.
        guard response.status.code != 405 else { return nil }
        guard (200...299).contains(response.status.code) else {
            throw MCPError.requestFailed(
                code: Int(response.status.code),
                message: "HTTP \(response.status.code) opening the server stream",
                data: nil)
        }
        return response.body
    }

    /// The headers currently sent with each request. Test visibility only.
    var currentHeaders: [String: String] { headers }

    /// Create the HTTP client for subsequent requests.
    public func connect() async throws {
        httpClient = makeHTTPClient()
        isConnected = true
    }

    /// Send a DELETE request to terminate the session and shut down the HTTP client.
    public func disconnect() async throws {
        defer { isConnected = false }

        // Terminate the session on the server if we have a session ID
        if let client = httpClient, let sid = await session.sessionID {
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = .DELETE
            request.headers.add(name: "Mcp-Session-Id", value: sid)
            for (key, value) in headers {
                request.headers.replaceOrAdd(name: key, value: value)
            }
            // silent: best-effort session termination during disconnect
            _ = try? await client.execute(request, timeout: .seconds(Int64(connectionTimeout)))
        }

        serverStreamTask?.cancel()
        serverStreamTask = nil

        // lifecycle: every response pump started by `send(_:)` is cancelled here, which is
        // what stops a task reading a body nobody is waiting for.
        for pump in responsePumps {
            pump.cancel()
        }
        responsePumps.removeAll()

        await session.clear()
        messageQueue.removeAll()

        // Fail any waiting receive() call
        messageContinuation?.resume(throwing: MCPError.connectionFailed(reason: "Disconnected"))
        messageContinuation = nil

        if let client = httpClient {
            httpClient = nil
            // silent: best-effort shutdown during disconnect
            try? await client.shutdown()
        }
    }

    /// Post a JSON-RPC message to the MCP endpoint and enqueue the response.
    public func send(_ data: Data) async throws {
        guard let client = httpClient, isConnected else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        var response = try await attempt(data, on: client, forcingRefresh: false)

        // One retry, and only for a refusal. A token can stop working before it expires here
        // — the grant is revoked, the clock drifted, the dynamic client registration lapsed —
        // and none of that is visible to a transport that only refreshes on schedule. The
        // retry asks for a token obtained now rather than one the clock still approves of.
        //
        // Once, not in a loop: a server refusing a token that was just refreshed is refusing
        // the grant, and every further attempt spends another rotation to be told the same
        // thing. Without a provider there is nothing to refresh, so the refusal stands.
        if response.status.code == 401, authorization != nil {
            response = try await attempt(data, on: client, forcingRefresh: true)
        }

        // A 404 answering a request that carried a session id is the server saying it has
        // forgotten the session — not that the endpoint is missing. Holding on to it would
        // send every later request into the same wall, and the caller cannot re-initialize
        // while the transport still believes in a session the server has dropped.
        if response.status.code == 404, await session.sessionID != nil {
            await session.clear()
        }

        // 202 Accepted = notification acknowledged, no response body
        if response.status.code == 202 {
            return
        }

        guard (200...299).contains(response.status.code) else {
            throw MCPError.requestFailed(
                code: Int(response.status.code),
                message: "HTTP \(response.status.code) from POST to \(url.absoluteString)",
                data: nil
            )
        }

        // Capture the session id the server assigned. `adopt` ignores a nil, because a later
        // response that simply does not repeat the header has not revoked anything.
        await session.adopt(sessionID: response.headers.first(name: "Mcp-Session-Id"))

        let contentType = response.headers.first(name: "Content-Type")

        // An SSE response may be held open while the server works, emitting events as it goes.
        // Consumed incrementally and in the background, so `send(_:)` returns once the request
        // has been answered rather than when the work finishes — a progress notification
        // delivered after the response closes is not a progress notification.
        if StreamableHTTPBodyDecoder.isEventStream(contentType) {
            let requestID = Self.requestID(of: data)
            let pump = Task {
                // Captured strongly: these tasks are owned by this transport and cancelled in
                // `disconnect()`, so there is no cycle to break — and a `weak self` here would
                // let a body be abandoned mid-response rather than drained or cancelled.
                await self.consume(response.body, forRequest: requestID)
            }
            // lifecycle: cancelled in `disconnect()`, along with every other response pump.
            responsePumps.append(pump)
            prunePumps()
            return
        }

        // A single JSON document has nothing to stream, and routing it through the incremental
        // path would be machinery for no gain.
        let body = try await response.body.collect(upTo: 10 * 1024 * 1024) // 10MB limit
        let payloads = try StreamableHTTPBodyDecoder.decode(
            body: Data(buffer: body),
            contentType: contentType)

        for payload in payloads {
            enqueueMessage(payload)
        }
    }

    /// Feeds an SSE response body into the receive queue, event by event.
    ///
    /// Errors are logged rather than thrown: nothing is awaiting this task, and a body that
    /// died mid-response has already delivered whatever it delivered. The caller learns about
    /// it the way it learns about any missing response — the request it is waiting on does not
    /// arrive — which is the same outcome the collected path produced.
    private func consume(_ body: HTTPClientResponse.Body, forRequest requestID: String?) async {
        do {
            for try await event in SSEEventStream.events(from: body) {
                // Recorded before the payload is delivered: a consumer that acts on the
                // message and then drops the connection should resume after this event, not
                // before it.
                if let id = event.id, let requestID {
                    await session.record(eventID: id, for: .post(requestID: requestID))
                }
                enqueueMessage(Data(event.data.utf8))
            }
        } catch {
            let logger = Logger(label: "MCPClient.StreamableHTTPTransport")
            // logging: a response stream that died, which the waiting caller sees only as silence
            logger.warning("response stream ended in failure: \(error.localizedDescription)")

            // Picked back up rather than abandoned. 2025-11-25 (SEP-1699) is specific about
            // how: resumption is always via `GET`, whichever stream dropped — the request is
            // *not* re-issued, because that would run the work a second time. The `GET` carries
            // the last event id seen here, and the server continues from it.
            //
            // A clean end is not a drop and never reaches this path: the response completed,
            // and asking to resume it would ask for a replay of something already delivered.
            await resumeResponseStream(forRequest: requestID)
        }
    }

    /// Reconnects a response stream that was cut off, continuing from its last event.
    ///
    /// Silent when there is nothing to resume from. A stream that dropped before delivering
    /// anything has no id to continue from, and a `GET` without one asks the server to start
    /// something it has no way to relate to the request that died.
    private func resumeResponseStream(forRequest requestID: String?) async {
        guard let requestID else { return }
        let stream = StreamableHTTPSession.StreamKind.post(requestID: requestID)
        guard await session.lastEventID(for: stream) != nil else { return }

        do {
            guard let body = try await openServerStream(resuming: stream) else { return }
            for try await event in SSEEventStream.events(from: body) {
                if Task.isCancelled { return }
                if let id = event.id {
                    await session.record(eventID: id, for: stream)
                }
                enqueueMessage(Data(event.data.utf8))
            }
        } catch {
            // One attempt. A resume that fails leaves the caller where it already was — a
            // request with no answer — and retrying a stream the server has stopped feeding is
            // how a lost response becomes a loop.
            let logger = Logger(label: "MCPClient.StreamableHTTPTransport")
            // logging: the second failure, after which the request is genuinely lost
            logger.warning("resuming a dropped response stream failed: \(error.localizedDescription)")
        }
    }

    /// Forgets pumps that have finished, so a long session does not accumulate them.
    private func prunePumps() {
        responsePumps.removeAll { $0.isCancelled }
    }

    /// The headers 2026-07-28 mirrors out of a request body.
    ///
    /// `Mcp-Name` is absent when the body has no name to mirror. An empty header is a *value*,
    /// and a server would compare it against a body field that does not exist.
    ///
    /// - Parameter data: The JSON-RPC request as it will be sent.
    /// - Returns: The headers to add, encoded for transport.
    static func mirroredHeaders(of data: Data) -> [String: String] {
        // A body that will not parse has nothing to mirror, and the request carries those same
        // bytes to a server that will say so far more usefully than this could.
        // silent: an unparseable body has no method to mirror; the server reports it
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let method = fields["method"] as? String else {
            return [:]
        }

        var headers = ["Mcp-Method": MCPHeaderValue.encode(method)]

        // `params.name` for tools and prompts, `params.uri` for resources. Whichever the body
        // carries is the one the server will compare against.
        let params = fields["params"] as? [String: Any]
        if let name = params?["name"] as? String ?? params?["uri"] as? String {
            headers["Mcp-Name"] = MCPHeaderValue.encode(name)
        }
        return headers
    }

    /// The JSON-RPC id of an outgoing request, for keying its response stream.
    ///
    /// A notification carries none, and its response stream is not resumable — there is
    /// nothing to correlate a replay with.
    private static func requestID(of data: Data) -> String? {
        // silent: a body that will not parse has no id to key a stream by
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let id = fields["id"] else { return nil }
        if let text = id as? String { return text }
        if let number = id as? NSNumber { return number.stringValue }
        return nil
    }

    /// The last event seen on a request's response stream. Test visibility only.
    func lastEventID(forRequest requestID: String) async -> String? {
        await session.lastEventID(for: .post(requestID: requestID))
    }

    /// Makes one attempt, with a freshly resolved `Authorization` header.
    ///
    /// - Parameters:
    ///   - data: The JSON-RPC payload.
    ///   - client: The HTTP client to send on.
    ///   - forcingRefresh: Passed to the provider. `true` only on a retry after a refusal.
    /// - Returns: The response, whatever its status — the caller decides what a status means.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the request could not be made, or
    ///   whatever the provider threw. A provider that fails **fails the send**: continuing
    ///   without the header would reach the server as a `401`, which reads as a credential
    ///   problem at the far end rather than a local one.
    private func attempt(
        _ data: Data,
        on client: HTTPClient,
        forcingRefresh: Bool
    ) async throws -> HTTPClientResponse {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: "application/json, text/event-stream")
        // Session id, negotiated protocol version, and a resume marker if one applies — the
        // session decides which of those a request carries, so the rule lives in one testable
        // place rather than inline here.
        for (key, value) in await session.headers() {
            request.headers.replaceOrAdd(name: key, value: value)
        }

        // `Mcp-Method` and `Mcp-Name`, mirrored from the body so intermediaries can route
        // without parsing it. Derived from the bytes being sent rather than passed in
        // alongside them: a server that reads the body MUST reject a request whose headers
        // disagree with it, and deriving makes agreement structural instead of a thing to
        // remember at every call site.
        //
        // 2026-07-28 onward only. These headers do not exist in earlier revisions, and a
        // server validating against a revision it does not implement has no reason to expect
        // them.
        if await session.mirrorsRequestMetadata {
            for (key, value) in Self.mirroredHeaders(of: data) {
                request.headers.replaceOrAdd(name: key, value: value)
            }
        }
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }

        // After the static headers, so a live session wins over a token pasted into
        // configuration. Both present means the pasted one is the leftover.
        if let authorization {
            if let header = try await authorization(forcingRefresh) {
                request.headers.replaceOrAdd(name: "Authorization", value: header)
            } else {
                // `nil` means not signed in, which is a request with no header — not one
                // carrying `Bearer` and nothing after it.
                request.headers.remove(name: "Authorization")
            }
        }

        request.body = .bytes(data)

        do {
            return try await client.execute(request, timeout: .seconds(Int64(connectionTimeout)))
        } catch {
            throw MCPError.connectionFailed(reason: error.localizedDescription)
        }
    }

    /// Return the next queued response, or suspend until one arrives from a ``send(_:)`` call.
    public func receive() async throws -> Data {
        guard isConnected else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.messageContinuation = continuation
        }
    }

    // MARK: - HTTP Client Factory

    private func makeHTTPClient() -> HTTPClient {
        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        if trustSelfSignedCertificates {
            tlsConfig.certificateVerification = .none
        }

        var config = HTTPClient.Configuration(
            tlsConfiguration: tlsConfig
        )
        config.timeout.connect = .seconds(Int64(connectionTimeout))

        return HTTPClient(configuration: config)
    }

    // MARK: - Message Handling

    private func enqueueMessage(_ data: Data) {
        if let continuation = messageContinuation {
            messageContinuation = nil
            continuation.resume(returning: data)
        } else {
            messageQueue.append(data)
        }
    }
}
