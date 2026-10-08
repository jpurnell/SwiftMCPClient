import Foundation
import Logging
import WebSocketKit
import NIOCore
import NIOHTTP1
import NIOSSL
import NIOFoundationCompat
import NIOPosix

/// A transport that communicates with an MCP server over WebSocket.
///
/// `WebSocketTransport` uses `WebSocketKit` (Swift NIO) to send and
/// receive JSON-RPC messages as WebSocket text frames. Works identically
/// on macOS and Linux.
///
/// ## Usage
///
/// ```swift
/// let transport = WebSocketTransport(
///     url: URL(string: "wss://mcp.example.com/ws")!
/// )
/// let client = MCPClientConnection(transport: transport)
/// let info = try await client.initialize(clientName: "my-app", clientVersion: "1.0")
/// ```
///
/// ## The URL
///
/// `wss://` connects over TLS, verified against `serverTrust`; `ws://` connects in plaintext.
/// The scheme is read case-insensitively, and any other scheme — `https://` included — fails
/// ``connect()`` before anything is sent, rather than being connected to as plaintext.
///
/// Plaintext is permitted, as it is on the HTTP transports: it is how a server on loopback or
/// a private network is reached. When `ws://` names another machine and a header or an
/// `authorization:` provider is configured, a warning is logged, because that credential is
/// about to cross the network unencrypted.
///
/// ## Authorization
///
/// The upgrade request is the only HTTP request this transport makes, so it is the one that
/// carries the credential. Static `headers` go on it. An `authorization:` provider, if there
/// is one, is asked for a current `Authorization` header first and its answer replaces a
/// static one — and if the server answers the upgrade `401`, it is asked once more for a
/// token obtained now and the upgrade is tried again, once. The rules are the HTTP
/// transports': `nil` sends no `Authorization` header, and a provider that throws fails
/// ``connect()``.
///
/// ## Redirects
///
/// The upgrade request is never redirected. `WebSocketKit` sends one `GET` and treats any
/// answer but `101 Switching Protocols` as a failed upgrade, so a `3xx` fails ``connect()``
/// with ``MCPError/connectionFailed(reason:)`` naming the status, and nothing is sent to
/// wherever its `Location` pointed.
///
/// ## Reconnection
///
/// If the WebSocket connection drops, create a new transport instance —
/// `WebSocketTransport` does not auto-reconnect.
public actor WebSocketTransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]

    /// Asked for a current `Authorization` header before the upgrade request.
    private let authorization: AuthorizationProvider?
    private let connectionTimeout: TimeAmount
    private let serverTrust: ServerTrust
    private var eventLoopGroup: (any EventLoopGroup)?
    private var webSocket: WebSocket?
    private var isConnected: Bool = false

    /// Queue of received messages from WebSocket frames.
    private var messageQueue: [Data] = []

    /// Continuation for waiting `receive()` calls when no messages are queued.
    private var messageContinuation: CheckedContinuation<Data, any Error>?

    /// How long ``connect()`` waits when no other limit is given.
    static let defaultConnectionTimeout: TimeInterval = 30.0

    /// Creates a new WebSocket transport.
    ///
    /// - Parameters:
    ///   - url: The WebSocket URL to connect to (ws:// or wss://).
    ///   - headers: Optional HTTP headers to include in the upgrade request.
    ///   - serverTrust: Which certificate roots a `wss://` server may chain to. Defaults to
    ///     ``ServerTrust/system``. For a self-signed or privately issued certificate, supply
    ///     it with ``ServerTrust/onlyRoots(_:)`` or ``ServerTrust/additionalRoots(_:)``; the
    ///     chain and the hostname are verified either way.
    public init(
        url: URL,
        headers: [String: String] = [:],
        serverTrust: ServerTrust = .system
    ) {
        self.url = url
        self.headers = headers
        self.authorization = nil
        self.connectionTimeout = .seconds(clamping: Self.defaultConnectionTimeout)
        self.serverTrust = serverTrust
    }

    /// Creates a WebSocket transport whose upgrade request is authorised by a provider.
    ///
    /// - Parameters:
    ///   - url: The WebSocket URL to connect to (ws:// or wss://).
    ///   - headers: Optional HTTP headers to include in the upgrade request.
    ///   - authorization: Asked for a current `Authorization` header before the upgrade
    ///     request, and once more — for a token obtained now — if the server answers it
    ///     `401`. Its answer replaces an `Authorization` in `headers`; `nil` sends none.
    ///     Pass `nil` for no provider.
    ///   - connectionTimeout: How long ``connect()`` may take to complete the upgrade.
    ///     Default 30s. A server that accepts the connection and never answers fails
    ///     ``connect()`` when this runs out, rather than leaving it waiting.
    ///   - serverTrust: Which certificate roots a `wss://` server may chain to. Defaults to
    ///     ``ServerTrust/system``.
    public init(
        url: URL,
        headers: [String: String] = [:],
        authorization: AuthorizationProvider?,
        connectionTimeout: TimeInterval = 30.0,
        serverTrust: ServerTrust = .system
    ) {
        self.url = url
        self.headers = headers
        self.authorization = authorization
        self.connectionTimeout = .seconds(clamping: connectionTimeout)
        self.serverTrust = serverTrust
    }

    /// Removed: this did not trust a self-signed certificate, it disabled verification.
    ///
    /// Passing `true` set NIOSSL's `certificateVerification` to `.none`, which accepts any
    /// certificate from anyone. Supply the certificate instead — see ``ServerTrust``.
    ///
    /// - Parameters:
    ///   - url: The WebSocket URL to connect to.
    ///   - headers: Optional HTTP headers to include in the upgrade request.
    ///   - trustSelfSignedCertificates: Ignored. Verification is never disabled.
    @available(*, unavailable, message: "This disabled certificate verification entirely. Pass serverTrust: try .onlyRoots([.pemFile(path)]) (or .additionalRoots) with the server's certificate; omit the argument where it was false.")
    public init(
        url: URL,
        headers: [String: String] = [:],
        trustSelfSignedCertificates: Bool
    ) {
        self.url = url
        self.headers = headers
        self.authorization = nil
        self.connectionTimeout = .seconds(clamping: Self.defaultConnectionTimeout)
        self.serverTrust = .system
    }

    /// The TLS configuration a `wss://` connection is made with.
    nonisolated var tlsConfiguration: TLSConfiguration {
        serverTrust.makeTLSConfiguration()
    }

    /// Where an upgrade request goes, taken from the URL once and decided here.
    struct Target: Sendable, Equatable {
        /// Whether the connection is made over TLS.
        let usesTLS: Bool
        let host: String
        let port: Int
        /// The request path, still percent-encoded.
        let path: String
        /// The query, still percent-encoded.
        let query: String?
    }

    /// Reads the connection's target out of a URL, or refuses the URL.
    ///
    /// `WebSocketKit` chooses TLS by comparing the scheme with the exact string `wss`, and
    /// only asserts that it is one of the two. So `WSS://host` — the same scheme, RFC 3986
    /// §3.1 — and `https://host` were both connected to as *plaintext on port 80* in a
    /// release build. The decision is made here instead, case-insensitively, and what
    /// `WebSocketKit` is handed afterwards is always one of its two spellings.
    ///
    /// - Parameter url: The URL the transport was created with.
    /// - Returns: Where and how to connect.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` — nothing having been sent — if the
    ///   scheme is not `ws` or `wss`, or the URL names no host.
    static func target(of url: URL) throws -> Target {
        let scheme = url.scheme?.lowercased() ?? ""
        guard scheme == "ws" || scheme == "wss" else {
            // The scheme is the one part of the URL quoted: it is a protocol name, and it is
            // the mistake being reported.
            let found = scheme.isEmpty ? "none" : "'\(scheme.prefix(16))'"
            throw MCPError.connectionFailed(
                reason: "WebSocketTransport needs a ws:// or wss:// URL; this one's scheme is \(found). "
                    + "Nothing was sent")
        }
        guard let host = url.host, !host.isEmpty,
              let components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false) else {
            throw MCPError.connectionFailed(
                reason: "WebSocketTransport needs a URL that names a host. Nothing was sent")
        }
        let usesTLS = scheme == "wss"
        return Target(
            usesTLS: usesTLS,
            host: host,
            port: url.port ?? (usesTLS ? 443 : 80),
            path: components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath,
            query: components.percentEncodedQuery)
    }

    /// Establish a WebSocket connection to the MCP server.
    ///
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the URL is not a WebSocket URL, the
    ///   connection could not be made, the server refused the upgrade, or the upgrade did
    ///   not complete within the connection timeout — the reason names the kind of failure
    ///   and the server's origin, never its path or query; or whatever the `authorization:`
    ///   provider threw.
    public func connect() async throws {
        let target = try Self.target(of: url)

        HTTPOrigin.warnIfPlaintextToRemote(
            url, carriesCredentials: authorization != nil || !headers.isEmpty,
            label: "MCPClient.WebSocketTransport")

        do {
            try await upgrade(to: target, forcingRefresh: false)
        } catch let refusal as UpgradeFailure where refusal.status == 401 && authorization != nil {
            // One retry, and only for a refusal, as on the HTTP transports: a revoked grant
            // is invisible to a clock and arrives only as a `401`. The upgrade is this
            // transport's only request, so it is the only place that recovery can happen.
            do {
                try await upgrade(to: target, forcingRefresh: true)
            } catch let second as UpgradeFailure {
                throw MCPError.connectionFailed(reason: second.reason)
            }
        } catch let failure as UpgradeFailure {
            throw MCPError.connectionFailed(reason: failure.reason)
        }
    }

    /// Why one upgrade attempt failed.
    private struct UpgradeFailure: Error {
        /// The status the server answered with, if it answered.
        let status: UInt?
        /// The composed reason.
        let reason: String
    }

    /// Makes one upgrade attempt.
    ///
    /// - Parameters:
    ///   - target: Where to connect.
    ///   - forcingRefresh: Passed to the provider. `true` only on the retry after a `401`.
    /// - Throws: `UpgradeFailure` if the attempt failed, or whatever the provider threw.
    private func upgrade(to target: Target, forcingRefresh: Bool) async throws {
        var upgradeHeaders = HTTPHeaders()
        for (key, value) in headers {
            upgradeHeaders.replaceOrAdd(name: key, value: value)
        }
        // Over the static headers, so a live session wins over a token pasted into
        // configuration. A provider that fails fails the connect.
        if let authorization {
            if let header = try await authorization(forcingRefresh) {
                upgradeHeaders.replaceOrAdd(name: "Authorization", value: header)
            } else {
                upgradeHeaders.remove(name: "Authorization")
            }
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let configuration = WebSocketClient.Configuration(
            tlsConfiguration: target.usesTLS ? tlsConfiguration : nil)
        let limit = connectionTimeout

        // The first of three things to happen decides the attempt: the upgrade completes,
        // the connection fails, or the time runs out. `WebSocketKit` reports the first two
        // but has no limit of its own — and a peer that accepts the connection and then
        // says nothing, or hangs up, is reported as neither.
        let (outcomes, outcome) = AsyncStream<Result<WebSocket, any Error>>.makeStream(
            bufferingPolicy: .bufferingOldest(1))
        let timer = group.next().scheduleTask(in: limit) {
            outcome.yield(.failure(UpgradeTimedOut()))
        }
        WebSocket.connect(
            scheme: target.usesTLS ? "wss" : "ws",
            host: target.host,
            port: target.port,
            path: target.path,
            query: target.query,
            headers: upgradeHeaders,
            configuration: configuration,
            on: group
        ) { socket in
            outcome.yield(.success(socket))
        }.whenFailure { error in
            outcome.yield(.failure(error))
        }

        var first: Result<WebSocket, any Error> = .failure(UpgradeTimedOut())
        for await result in outcomes {
            first = result
            break
        }
        timer.cancel()
        outcome.finish()

        switch first {
        case .success(let socket):
            self.eventLoopGroup = group
            self.webSocket = socket
            self.isConnected = true
            setupHandlers(socket)
        case .failure(let error):
            // Shutting the group down closes whatever the attempt had open, a connection
            // that was still waiting included.
            do {
                try await group.shutdownGracefully()
            } catch {
                let logger = Logger(label: "MCPClient.WebSocketTransport")
                // logging: cleanup after a failed connect — the failure's kind and the configured origin
                logger.debug("event loop shutdown failed after a failed upgrade: \(TransportFailure.reason(for: error, reaching: url))")
            }
            throw UpgradeFailure(
                status: Self.status(ofRefusal: error),
                reason: Self.describe(connectFailure: error, reaching: url))
        }
    }

    /// The upgrade did not complete before the connection timeout.
    private struct UpgradeTimedOut: Error {}

    /// The status a refused upgrade was answered with, if that is what an error is.
    private static func status(ofRefusal error: any Error) -> UInt? {
        guard case .invalidResponseStatus(let head) = error as? WebSocketClient.Error else { return nil }
        return head.status.code
    }

    /// What a failed connect may say about itself.
    ///
    /// `WebSocketKit` describes a refused upgrade by printing the whole response head: the
    /// status, and every header the server sent with it — a `Location`, a `Set-Cookie`,
    /// whatever it chose. That text is the server's, and it has no business in an error the
    /// caller will log; nor does any other library's description of its own error. The
    /// reason is composed by ``TransportFailure`` from the error's type and case, and names
    /// the configured URL by origin only — so its path and its query, which is where a token
    /// goes on a WebSocket URL that cannot take a header, appear nowhere.
    ///
    /// - Parameters:
    ///   - error: What `WebSocket.connect` failed with.
    ///   - url: The URL the transport was created with.
    /// - Returns: A description that quotes nothing the server sent but its status code.
    static func describe(connectFailure error: any Error, reaching url: URL) -> String {
        if error is UpgradeTimedOut {
            return "Could not reach \(HTTPOrigin.description(of: url)): "
                + "no response before the deadline — the WebSocket upgrade was not completed in time"
        }
        return TransportFailure.reason(for: error, reaching: url)
    }

    /// Close the WebSocket and shut down the event loop.
    public func disconnect() async throws {
        if let ws = webSocket {
            // silent: best-effort close during disconnect
            try? await ws.close()
            webSocket = nil
        }

        isConnected = false
        messageQueue.removeAll()

        messageContinuation?.resume(throwing: MCPError.connectionFailed(reason: "Disconnected"))
        messageContinuation = nil

        if let group = eventLoopGroup {
            eventLoopGroup = nil
            // silent: best-effort shutdown during disconnect
            try? await group.shutdownGracefully()
        }
    }

    /// Send a JSON-RPC message as a WebSocket text frame.
    ///
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport is not connected,
    ///   the message is not UTF-8, or the frame could not be written.
    public func send(_ data: Data) async throws {
        guard let ws = webSocket, isConnected else {
            throw MCPError.connectionFailed(reason: "WebSocketTransport is not connected")
        }

        // A text frame is UTF-8 by definition. JSON-RPC always is; anything else is not sent
        // as an empty frame, which a server would answer as a parse error for a message the
        // caller never wrote.
        guard let text = String(data: data, encoding: .utf8) else {
            throw MCPError.connectionFailed(reason: "The message is not UTF-8 text and was not sent")
        }
        do {
            try await ws.send(text)
        } catch {
            throw MCPError.connectionFailed(reason: TransportFailure.reason(for: error, reaching: url))
        }
    }

    /// Return the next queued WebSocket message, or suspend until one arrives.
    public func receive() async throws -> Data {
        guard isConnected else {
            throw MCPError.connectionFailed(reason: "WebSocketTransport is not connected")
        }

        if !messageQueue.isEmpty {
            return messageQueue.removeFirst()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.messageContinuation = continuation
        }
    }

    // MARK: - Private

    private func setupHandlers(_ ws: WebSocket) {
        ws.onText { [weak self] _, text in
            guard let self = self else { return }
            if let data = text.data(using: .utf8) {
                Task { await self.enqueueMessage(data) }
            }
        }

        ws.onBinary { [weak self] _, buffer in
            guard let self = self else { return }
            let data = Data(buffer: buffer)
            Task { await self.enqueueMessage(data) }
        }

        ws.onClose.whenComplete { [weak self] _ in
            guard let self = self else { return }
            Task { await self.handleClose() }
        }
    }

    private func enqueueMessage(_ data: Data) {
        if let continuation = messageContinuation {
            messageContinuation = nil
            continuation.resume(returning: data)
        } else {
            messageQueue.append(data)
        }
    }

    private func handleClose() {
        isConnected = false
        if let continuation = messageContinuation {
            messageContinuation = nil
            continuation.resume(throwing: MCPError.connectionFailed(reason: "WebSocket closed"))
        }
    }
}
