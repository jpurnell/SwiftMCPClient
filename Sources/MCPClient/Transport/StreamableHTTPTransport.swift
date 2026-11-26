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
/// ## Redirects Stay on the Configured Origin
///
/// Every request — each `POST`, the server stream's `GET`, a resumption `GET`, the closing
/// `DELETE` — follows a redirect only to the origin of `url`: the same scheme, host and port.
/// A redirect anywhere else — another host or port, `http` for `https`, or `https` for
/// `http` — is not followed and nothing is sent to it: no header, no `Mcp-Session-Id`, no
/// body.
///
/// Within the origin, a redirect is followed only if it repeats the request as it was sent.
/// A `GET` follows any of `301`, `302`, `303`, `307` and `308`. A `POST` follows `307` and
/// `308` only: the other three would repeat it as a `GET` with no body, which drops the
/// JSON-RPC message, so they are refused — as is a `303` answering the `DELETE`. At most five
/// are followed, and a loop is refused.
///
/// Every refusal is ``MCPError/redirectRejected(destination:reason:)``, and none is retried:
/// ``send(_:)`` fails with it; the server stream, which nobody is awaiting, logs the refusal
/// at error level and stops rather than reconnecting.
///
/// ## Ending the Session
///
/// ``disconnect()`` sends `DELETE` with the session id, authenticated like every other
/// request: the `authorization:` provider is asked once, without forcing a refresh, and the
/// wait for it shares the `DELETE`'s deadline (`connectionTimeout`). If the provider does not
/// answer in time, or throws, no `DELETE` is sent — it is not sent unauthenticated — and the
/// reason is logged.
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

    /// Which tool parameters are mirrored into headers, by tool name.
    ///
    /// Learned from tool definitions, which only the connection sees — so it installs them
    /// here. The mirroring itself stays in the transport, next to the other headers derived
    /// from the body, because that is what keeps header and body in agreement.
    private var parameterHeaders: [String: [String: String]] = [:]

    /// Whether the server-initiated stream should be opened after initialization.
    private let opensServerStream: Bool

    /// The one server-initiated stream, while it is running.
    ///
    /// One at a time: the specification permits a single `GET` stream, and a client that opens
    /// another on every prompt leaks them server-side.
    private var serverStreamTask: Task<Void, Never>?

    /// Why the server-initiated stream's loop ended, once it has.
    ///
    /// The loop runs for the life of the transport unless something ends it for good, and
    /// "it will not be reopened" is otherwise visible only as the absence of a request. Kept
    /// so that a test — or a debugger — can ask what happened instead of waiting to see what
    /// does not.
    enum ServerStreamEnding: Sendable, Equatable {
        /// The server answered `405`: it originates no messages.
        case notOffered
        /// The `GET` was answered with a redirect this client does not follow.
        case redirectRefused
        /// The transport was disconnected.
        case cancelled
        /// The stream carried an event larger than ``MCPResponseLimits/maximumEventBytes``.
        case eventTooLarge
    }

    /// Why the server stream's loop ended; `nil` while it is running or was never started.
    private(set) var serverStreamEnding: ServerStreamEnding?

    /// Whether every response stream handed to the background has finished — delivered,
    /// failed, and, if it was going to be, resumed. Test visibility only.
    private(set) var finishedResponsePumps = 0
    private var startedResponsePumps = 0

    /// Whether no response stream is still being read in the background. Test visibility only.
    var responseStreamsAreIdle: Bool { finishedResponsePumps == startedResponsePumps }

    /// Tasks draining SSE response bodies into the receive queue.
    ///
    /// One per in-flight streaming response. They outlive `send(_:)` deliberately — that is
    /// what lets a response be consumed while the server is still writing it.
    private var responsePumps: [Task<Void, Never>] = []

    private var headers: [String: String]

    /// Asked for a current `Authorization` header before each request.
    private let authorization: AuthorizationProvider?
    private let connectionTimeout: TimeAmount
    private let serverTrust: ServerTrust

    /// How much one response body, and one event, may hold.
    private let limits: MCPResponseLimits

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

    /// Where this transport's diagnostics go.
    ///
    /// A `Logger` of its own rather than one made at each call site, so that what the
    /// transport says can be observed: a test hands it a logger that records, through
    /// ``useDiagnostics(_:)``. Nothing outside the module can replace it.
    private var logger = Logger(label: "MCPClient.StreamableHTTPTransport")

    /// Whether the plaintext-credentials warning has been written by this transport.
    private var hasWarnedOfPlaintext = false

    /// Sends this transport's diagnostics to another logger. Test visibility only.
    ///
    /// - Parameter logger: The logger to write to from now on.
    func useDiagnostics(_ logger: Logger) {
        self.logger = logger
    }

    /// Warns — once in this transport's life — that configured credentials are about to
    /// cross a network unencrypted.
    private func warnOfPlaintextOnce() {
        guard !hasWarnedOfPlaintext else { return }
        hasWarnedOfPlaintext = HTTPOrigin.warnIfPlaintextToRemote(
            url, carriesCredentials: authorization != nil || !headers.isEmpty, logger: logger)
    }

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
    ///   - serverTrust: Which certificate roots an `https://` server may chain to. Defaults
    ///     to ``ServerTrust/system``. For a self-signed or privately issued certificate,
    ///     supply it with ``ServerTrust/onlyRoots(_:)`` or ``ServerTrust/additionalRoots(_:)``;
    ///     the chain and the hostname are verified either way.
    ///   - limits: How much one response body, and one Server-Sent Event, may hold before
    ///     the read is abandoned with ``MCPError/responseTooLarge(limit:reason:)``. Defaults
    ///     to ``MCPResponseLimits/standard``, 10 MiB each.
    public init(
        url: URL,
        headers: [String: String] = [:],
        authorization: AuthorizationProvider? = nil,
        openServerStream: Bool = true,
        connectionTimeout: TimeInterval = 30.0,
        serverTrust: ServerTrust = .system,
        limits: MCPResponseLimits = .standard
    ) {
        self.url = url
        self.headers = headers
        self.authorization = authorization
        self.opensServerStream = openServerStream
        self.connectionTimeout = .seconds(clamping: connectionTimeout)
        self.serverTrust = serverTrust
        self.limits = limits
    }

    /// Removed: this did not trust a self-signed certificate, it disabled verification.
    ///
    /// Passing `true` set NIOSSL's `certificateVerification` to `.none`, which accepts any
    /// certificate from anyone. Supply the certificate instead — see ``ServerTrust``.
    ///
    /// - Parameters:
    ///   - url: The MCP endpoint URL.
    ///   - headers: Custom HTTP headers sent with all requests.
    ///   - authorization: Asked for a current `Authorization` header.
    ///   - openServerStream: Whether to open the client-initiated `GET` stream.
    ///   - connectionTimeout: Maximum time to wait for each HTTP request.
    ///   - trustSelfSignedCertificates: Ignored. Verification is never disabled.
    @available(*, unavailable, message: "This disabled certificate verification entirely. Pass serverTrust: try .onlyRoots([.pemFile(path)]) (or .additionalRoots) with the server's certificate; omit the argument where it was false.")
    public init(
        url: URL,
        headers: [String: String] = [:],
        authorization: AuthorizationProvider? = nil,
        openServerStream: Bool = true,
        connectionTimeout: TimeInterval = 30.0,
        trustSelfSignedCertificates: Bool
    ) {
        self.url = url
        self.headers = headers
        self.authorization = authorization
        self.opensServerStream = openServerStream
        self.connectionTimeout = .seconds(clamping: connectionTimeout)
        self.serverTrust = .system
        self.limits = .standard
    }

    /// The TLS configuration every request is made with.
    nonisolated var tlsConfiguration: TLSConfiguration {
        serverTrust.makeTLSConfiguration()
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

    /// Records which tool parameters carry `x-mcp-header` annotations.
    ///
    /// - Parameter headers: Header name by parameter name, keyed by tool name — as the tool
    ///   definitions declared it.
    public func useParameterHeaders(_ headers: [String: [String: String]]) {
        parameterHeaders = headers
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
            guard !Task.isCancelled else {
                serverStreamEnding = .cancelled
                return
            }

            do {
                guard let body = try await openServerStream(resuming: isReconnect ? .get : nil) else {
                    serverStreamEnding = .notOffered
                    return
                }
                isReconnect = true
                var delivered = false
                for try await event in events(in: body) {
                    guard !Task.isCancelled else {
                        serverStreamEnding = .cancelled
                        return
                    }
                    if let id = event.id {
                        await session.record(eventID: id, for: .get)
                    }
                    enqueue(event)
                    delivered = true
                }

                // A cancelled stream ends the same way a finished one does — quietly — so the
                // reason has to be established before anything acts on it. Without this, a
                // disconnect is scored as a server that closed early and feeds the backoff.
                guard !Task.isCancelled else {
                    serverStreamEnding = .cancelled
                    return
                }

                // A clean close is the server exercising its right to disconnect, which
                // 2025-11-25 (SEP-1699) explicitly permits and expects clients to poll
                // through. Whether it delivered anything first does not change what happened:
                // scoring a quiet close as trouble climbs the backoff until a healthy but
                // idle server is checked once an hour.
                //
                // Failures escalate — that is the `catch` below. This path is only ever a
                // stream that ended without error.
                attempt = delivered ? 0 : StreamBackoff.pollingAttempt
            } catch MCPError.redirectRejected {
                // The server answered, and the answer was "open it somewhere else". That is
                // not a dropped stream and asking again gets the same answer, so the loop
                // ends here rather than backing off into it forever. Request and response
                // carry on without this channel. The refusal itself is logged, at error, where
                // it was made; this says what it cost.
                // logging: the consequence of a refused redirect — no value from the request or the response
                logger.warning("the server stream will not be reopened: its GET was answered with a redirect this client does not follow")
                serverStreamEnding = .redirectRefused
                return
            } catch let MCPError.responseTooLarge(_, reason) {
                // Not reconnected. A reconnect carries the last event id seen, and the server
                // answers it with the event that follows — this one, at the same size. Request
                // and response carry on without the channel.
                // logging: swift-log has no privacy annotations; the limit and the configured origin — nothing the server sent
                logger.error("the server stream will not be reopened: \(reason)")
                serverStreamEnding = .eventTooLarge
                return
            } catch {
                attempt += 1
                // logging: why the server stream dropped, which no caller is awaiting — the failure's kind and the configured origin
                logger.debug("server stream dropped: \(TransportFailure.reason(for: error, reaching: url))")
            }
        }
        serverStreamEnding = .cancelled
    }

    /// The events in a response body, each held to ``MCPResponseLimits/maximumEventBytes``.
    private func events(in body: HTTPClientResponse.Body) -> AsyncThrowingStream<SSEEvent, any Error> {
        SSEEventStream.events(from: body, maximumEventBytes: limits.maximumEventBytes, reaching: url)
    }

    /// Asks the server to open its stream.
    ///
    /// - Parameter resuming: Whether to carry `Last-Event-ID` and pick up where the previous
    ///   stream stopped.
    /// - Returns: The stream body, or `nil` if the server offers no such channel.
    /// - Throws: ``MCPError/redirectRejected(destination:reason:)`` if the `GET` is answered
    ///   with a redirect that is not followed.
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

        let response = try await redirects.execute(
            request, on: client, timeout: connectionTimeout, authorization: authorization)

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
        // Reused rather than replaced. `AsyncHTTPClient` traps in `deinit` if a client was
        // never shut down, so overwriting a live one here does not leak quietly — it kills the
        // process with a `Fatal error` at whatever point the orphan is collected.
        //
        // Nothing called this twice until `MCPConnectionFactory` did, which begins a session
        // optimistically and connects again when it falls back. The defect was older than the
        // factory; the factory is only what reached it.
        guard httpClient == nil else {
            isConnected = true
            return
        }
        warnOfPlaintextOnce()
        httpClient = makeHTTPClient()
        isConnected = true
    }

    /// Send a DELETE request to terminate the session and shut down the HTTP client.
    ///
    /// The `DELETE` is authenticated like every other request: the `authorization:`
    /// provider is asked for a current header — once, without forcing a refresh — and that
    /// header goes on it. The ask and the `DELETE` share one deadline, the connection
    /// timeout, so a provider that cannot answer (its authorization server is down, say)
    /// delays this by at most that long. If no credential arrives in time, or the provider
    /// throws, **no `DELETE` is sent**: an unauthenticated termination is the request the
    /// server refuses, and the reason is logged instead. The server then expires the session
    /// on its own schedule.
    public func disconnect() async throws {
        defer { isConnected = false }

        // Terminate the session on the server if we have a session ID
        if let client = httpClient, let sid = await session.sessionID {
            await terminateSession(sid, on: client)
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

    /// Tells the server the session is over. Best effort, bounded, and never unauthenticated
    /// when there is a provider to authenticate it.
    private func terminateSession(_ sid: String, on client: HTTPClient) async {
        // One deadline for asking the provider and for the request it authorises.
        let deadline = NIODeadline.now() + connectionTimeout

        // The credential is resolved here, once, and handed to the request as a fixed
        // answer: a redirected `DELETE` re-uses it rather than asking again, because a second
        // ask would be a second wait.
        var credential: AuthorizationProvider?
        if let authorization {
            switch await BoundedAuthorization.ask(
                authorization, within: .nanoseconds(connectionTimeout.nanoseconds)) {
            case .header(let header):
                credential = { _ in header }
            case .timedOut:
                // logging: why the server was not told — no value from the request or the provider
                logger.warning("session termination was not sent: the authorization provider did not answer before the deadline, and it is not sent unauthenticated")
                return
            case .failed(let kind):
                // logging: why the server was not told — the provider's error by type name only
                logger.warning("session termination was not sent: the authorization provider failed (\(kind)), and it is not sent unauthenticated")
                return
            }
        }

        let remaining = deadline - NIODeadline.now()
        guard remaining > .zero else {
            // logging: why the server was not told — no value from the request
            logger.warning("session termination was not sent: the deadline passed while the credential was being obtained")
            return
        }

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .DELETE
        request.headers.add(name: "Mcp-Session-Id", value: sid)
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }
        do {
            // Through the same door as every other request, so a redirected `DELETE`
            // cannot carry the session id somewhere a `POST` would not have gone.
            _ = try await redirects.execute(
                request, on: client, timeout: remaining, authorization: credential)
        } catch {
            // Best effort: the session is being abandoned either way, and the server
            // expires what it is not told about.
            // logging: a session the server was not told had ended — the failure's kind and the configured origin
            logger.debug("session termination was not delivered: \(TransportFailure.reason(for: error, reaching: url))")
        }
    }

    /// Post a JSON-RPC message to the MCP endpoint and enqueue the response.
    ///
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` for a status that is not a
    ///   success, naming the endpoint by origin and path only — never its query;
    ///   ``MCPError/redirectRejected(destination:reason:)`` if the server redirects the POST
    ///   off the configured origin, answers it with a `301`, `302` or `303` — which cannot
    ///   carry a `POST` — or redirects it in a loop or more than five times;
    ///   ``MCPError/responseTooLarge(limit:reason:)`` if a JSON response body is larger than
    ///   ``MCPResponseLimits/maximumResponseBytes``;
    ///   ``MCPError/connectionFailed(reason:)`` if the request could not be made or its
    ///   response body could not be read, with a reason that names the kind of failure and
    ///   the server's origin.
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
            // A server that refuses at the HTTP layer may still answer in JSON-RPC, and the code
            // and data in that answer are what a caller decides from (`-32022` lists the versions
            // the server speaks). Surfaced as the error, with the status it travelled under
            // logged rather than lost; any other body keeps the status as the code.
            if let rpcError = await HTTPErrorBody.jsonRPCError(in: response.body) {
                let logger = Logger(label: "MCPClient.StreamableHTTPTransport")
                // logging: a JSON-RPC refusal that travelled under a non-2xx status; the status, the code and the configured origin
                logger.debug("HTTP \(response.status.code) from POST to \(HTTPOrigin.redacted(url)) carried JSON-RPC error \(rpcError.code)")
                throw MCPError.requestFailed(
                    code: rpcError.code, message: rpcError.message, data: rpcError.data)
            }
            throw MCPError.requestFailed(
                code: Int(response.status.code),
                message: "HTTP \(response.status.code) from POST to \(HTTPOrigin.redacted(url))",
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
            let requestIDValue = Self.requestIDValue(of: data)
            startedResponsePumps += 1
            let pump = Task {
                // Captured strongly: these tasks are owned by this transport and cancelled in
                // `disconnect()`, so there is no cycle to break — and a `weak self` here would
                // let a body be abandoned mid-response rather than drained or cancelled.
                await self.consume(response.body, forRequest: requestID, idValue: requestIDValue)
            }
            // lifecycle: cancelled in `disconnect()`, along with every other response pump.
            responsePumps.append(pump)
            prunePumps()
            return
        }

        // A single JSON document has nothing to stream, and routing it through the incremental
        // path would be machinery for no gain.
        let body = try await MCPResponseLimits.collect(
            response, upTo: limits.maximumResponseBytes, from: url)
        let payloads = try StreamableHTTPBodyDecoder.decode(
            body: Data(buffer: body),
            contentType: contentType)

        for payload in payloads {
            enqueueMessage(payload)
        }
    }

    /// Queues an event's payload, unless the event carries none.
    ///
    /// A server may send an event with an id and an empty `data:` line — a keep-alive, or a
    /// priming event before the real one. The reference implementation does exactly that once a
    /// 2025-11-25 session is negotiated. Such an event is not a message: handing it to a
    /// JSON-RPC decoder reports the response as invalid when the server did nothing wrong and
    /// the real response arrives a moment later.
    ///
    /// - Parameter event: The event as decoded.
    private func enqueue(_ event: SSEEvent) {
        let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return }
        enqueueMessage(Data(event.data.utf8))
    }

    /// Feeds an SSE response body into the receive queue, event by event.
    ///
    /// Errors are logged rather than thrown: nothing is awaiting this task. But the caller **is** waiting,
    /// and a request whose response can no longer arrive must not leave it so. When the stream ends in
    /// failure and the response did not arrive by it or by a resumption, the request is answered here with
    /// a JSON-RPC error carrying its id (see ``failLostRequest(_:)``). Before this, the caller waited on a
    /// request that had no answer coming, past its own timeout (SwiftMCPServer's R1 finding F1).
    private func consume(
        _ body: HTTPClientResponse.Body, forRequest requestID: String?, idValue: JSONRPCRequestID?
    ) async {
        // Counted on every way out, a resumption included: "idle" means nothing is still
        // being read, not merely that the first body ended.
        defer { finishedResponsePumps += 1 }
        var answered = false
        do {
            for try await event in events(in: body) {
                // Recorded before the payload is delivered: a consumer that acts on the
                // message and then drops the connection should resume after this event, not
                // before it.
                if let id = event.id, let requestID {
                    await session.record(eventID: id, for: .post(requestID: requestID))
                }
                if let requestID, Self.answers(event.data, requestID: requestID) { answered = true }
                enqueue(event)
            }
        } catch let MCPError.responseTooLarge(_, reason) {
            // Not resumed: a resumption asks for the events after the last one seen, and the
            // first of those is the one that was too large. The request it answered is lost,
            // and so is failed, below.
            // logging: swift-log has no privacy annotations; the limit and the configured origin — nothing the server sent
            logger.error("abandoned a response stream: \(reason)")
            if !answered { failLostRequest(idValue) }
        } catch {
            // logging: a response stream that died, which the waiting caller sees only as silence — the failure's kind and the configured origin
            logger.warning("response stream ended in failure: \(TransportFailure.reason(for: error, reaching: url))")

            // Picked back up rather than abandoned. 2025-11-25 (SEP-1699) is specific about
            // how: resumption is always via `GET`, whichever stream dropped — the request is
            // *not* re-issued, because that would run the work a second time. The `GET` carries
            // the last event id seen here, and the server continues from it.
            //
            // A clean end is not a drop and never reaches this path: the response completed,
            // and asking to resume it would ask for a replay of something already delivered.
            if !answered {
                answered = await resumeResponseStream(forRequest: requestID)
            }
            // Nothing can bring the response back: nothing to resume from, a resumption that failed, or one
            // that ended without it. The caller is told, rather than left to wait.
            if !answered { failLostRequest(idValue) }
        }
    }

    /// Answers a request whose response is lost with a JSON-RPC error carrying its id.
    ///
    /// Silent when the pump was cancelled (the transport is going away and its receive loop with it) or when
    /// the request had no id to carry. The message is fixed text: nothing the server sent is echoed.
    private func failLostRequest(_ id: JSONRPCRequestID?) {
        guard !Task.isCancelled, let id else { return }
        let object: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id.jsonObject,
            "error": [
                "code": -32000,
                "message": "The response stream ended before the response arrived."
            ] as [String: Any],
        ]
        // silent: a dictionary of strings and numbers always serialises; there is nothing to report if it somehow did not
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        enqueueMessage(data)
    }

    /// Whether an event's data is the response (a result or an error) to the request with this id.
    static func answers(_ data: String, requestID: String) -> Bool {
        // silent: data that is not JSON is not a response, and is delivered or rejected by the caller as before
        guard let object = try? JSONSerialization.jsonObject(with: Data(data.utf8)),
              let fields = object as? [String: Any],
              fields["result"] != nil || fields["error"] != nil,
              let id = fields["id"] else { return false }
        if let text = id as? String { return text == requestID }
        if let number = id as? NSNumber { return number.stringValue == requestID }
        return false
    }

    /// A request's JSON-RPC id with its type kept, so an error built for it matches what the caller sent.
    struct JSONRPCRequestID: Sendable, Equatable {
        private enum Value: Sendable, Equatable { case string(String), integer(Int64) }
        private let value: Value

        init?(_ any: Any) {
            if let text = any as? String { value = .string(text) }
            else if let number = any as? NSNumber, !(any is Bool), let integer = Int64(exactly: number) {
                value = .integer(integer)
            } else { return nil }
        }

        /// The id as `JSONSerialization` takes it.
        var jsonObject: Any {
            switch value {
            case .string(let text): return text
            case .integer(let integer): return integer
            }
        }
    }

    /// The id of a request body with its type kept, or `nil` for a notification or a body that will not parse.
    static func requestIDValue(of data: Data) -> JSONRPCRequestID? {
        // silent: a body that will not parse has no id to answer
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              let id = fields["id"] else { return nil }
        return JSONRPCRequestID(id)
    }

    /// Reconnects a response stream that was cut off, continuing from its last event.
    ///
    /// Silent when there is nothing to resume from. A stream that dropped before delivering
    /// anything has no id to continue from, and a `GET` without one asks the server to start
    /// something it has no way to relate to the request that died.
    ///
    /// - Returns: Whether the request's response arrived over the resumed stream. `false` for every
    ///   other outcome, which is the caller's cue to fail the request.
    private func resumeResponseStream(forRequest requestID: String?) async -> Bool {
        guard let requestID else { return false }
        let stream = StreamableHTTPSession.StreamKind.post(requestID: requestID)
        guard await session.lastEventID(for: stream) != nil else { return false }

        var answered = false
        do {
            guard let body = try await openServerStream(resuming: stream) else { return false }
            for try await event in events(in: body) {
                if Task.isCancelled { return answered }
                if let id = event.id {
                    await session.record(eventID: id, for: stream)
                }
                if Self.answers(event.data, requestID: requestID) { answered = true }
                enqueue(event)
            }
            // A cancelled iteration ends quietly rather than throwing, and "ended without the response" is a
            // conclusion drawn from how the loop ended: cancellation is checked first, so a transport being
            // disconnected is not mistaken for a stream that lost its response.
            try Task.checkCancellation()
            return answered
        } catch is CancellationError {
            // logging: the transport was disconnected while a dropped stream was being resumed; no failure, no origin
            logger.debug("resuming a dropped response stream was cancelled")
            return answered
        } catch {
            // One attempt. A resume that fails leaves the caller where it already was — a
            // request with no answer — and retrying a stream the server has stopped feeding is
            // how a lost response becomes a loop.
            // logging: the second failure, after which the request is genuinely lost — the failure's kind and the configured origin
            logger.warning("resuming a dropped response stream failed: \(TransportFailure.reason(for: error, reaching: url))")
            return answered
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

    /// The `Mcp-Param-*` headers for a `tools/call`, from the annotations the tool declared.
    ///
    /// An argument the call omits produces no header: an empty header is a *value*, and the
    /// server compares headers against the body. Only the annotated arguments are mirrored —
    /// mirroring the rest would put tool inputs in front of every intermediary on the path.
    ///
    /// - Parameter data: The request as it will be sent.
    /// - Returns: The headers to add.
    private func mirroredParameters(of data: Data) -> [String: String] {
        // A body that will not parse has no arguments to mirror, and the server receives those
        // same bytes and reports the problem far better than this could.
        // silent: an unparseable body has no arguments to mirror; the server reports it
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let fields = object as? [String: Any],
              fields["method"] as? String == "tools/call",
              let params = fields["params"] as? [String: Any],
              let tool = params["name"] as? String,
              let annotations = parameterHeaders[tool],
              let arguments = params["arguments"] as? [String: Any] else {
            return [:]
        }

        var headers: [String: String] = [:]
        for (parameter, headerName) in annotations {
            guard let value = arguments[parameter], !(value is NSNull) else { continue }
            headers["Mcp-Param-\(headerName)"] = MCPHeaderValue.encode(Self.headerText(value))
        }
        return headers
    }

    /// A primitive argument as the specification says to spell it in a header.
    ///
    /// Booleans are lowercase and integers are decimal, because a server compares this against
    /// the body value and `true` is not `1`.
    private static func headerText(_ value: Any) -> String {
        if let text = value as? String { return text }
        if let flag = value as? Bool { return flag ? "true" : "false" }
        if let number = value as? NSNumber { return number.stringValue }
        return String(describing: value)
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
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the request could not be made,
    ///   ``MCPError/redirectRejected(destination:reason:)`` if it was redirected off the
    ///   configured origin, or whatever the provider threw. A provider that fails **fails the
    ///   send**: continuing without the header would reach the server as a `401`, which reads
    ///   as a credential problem at the far end rather than a local one.
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
            for (key, value) in mirroredParameters(of: data) {
                request.headers.replaceOrAdd(name: key, value: value)
            }
        }
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }

        request.body = .bytes(data)

        // The provider's token is applied there — after the static headers, so a live session
        // wins over a token pasted into configuration — and again for each request a redirect
        // turns this into.
        return try await redirects.execute(
            request, on: client, timeout: connectionTimeout,
            authorization: authorization, forcingRefresh: forcingRefresh)
    }

    /// How every request this transport makes is sent: redirects are followed on the origin
    /// of `url` and nowhere else.
    private var redirects: SameOriginRedirects {
        SameOriginRedirects(configured: url, loggerLabel: "MCPClient.StreamableHTTPTransport")
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
        serverTrust.makeHTTPClient(connectTimeout: connectionTimeout)
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
