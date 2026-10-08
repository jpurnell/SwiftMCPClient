import Foundation
import WebSocketKit
import NIOCore
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
    private let serverTrust: ServerTrust
    private var eventLoopGroup: (any EventLoopGroup)?
    private var webSocket: WebSocket?
    private var isConnected: Bool = false

    /// Queue of received messages from WebSocket frames.
    private var messageQueue: [Data] = []

    /// Continuation for waiting `receive()` calls when no messages are queued.
    private var messageContinuation: CheckedContinuation<Data, any Error>?

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
        self.serverTrust = .system
    }

    /// The TLS configuration a `wss://` connection is made with.
    nonisolated var tlsConfiguration: TLSConfiguration {
        serverTrust.makeTLSConfiguration()
    }

    /// Establish a WebSocket connection to the MCP server.
    public func connect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        let tlsConfig = tlsConfiguration

        var upgradeHeaders = HTTPHeaders()
        for (key, value) in headers {
            upgradeHeaders.add(name: key, value: value)
        }

        let scheme = url.scheme ?? "ws"
        let useTLS = scheme == "wss"

        do {
            let ws = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<WebSocket, any Error>) in
                WebSocket.connect(
                    to: url.absoluteString,
                    headers: upgradeHeaders,
                    configuration: .init(
                        tlsConfiguration: useTLS ? tlsConfig : nil
                    ),
                    on: group
                ) { ws in
                    continuation.resume(returning: ws)
                }.whenFailure { error in
                    continuation.resume(throwing: error)
                }
            }

            self.webSocket = ws
            self.isConnected = true
            setupHandlers(ws)
        } catch {
            // silent: best-effort cleanup after failed connect
            try? await group.shutdownGracefully()
            eventLoopGroup = nil
            throw MCPError.connectionFailed(reason: Self.describe(connectFailure: error))
        }
    }

    /// What a failed connect may say about itself.
    ///
    /// `WebSocketKit` describes a refused upgrade by printing the whole response head: the
    /// status, and every header the server sent with it — a `Location`, a `Set-Cookie`,
    /// whatever it chose. That text is the server's, and it has no business in an error the
    /// caller will log. The status is the part that says what happened, so the status is
    /// what is kept.
    ///
    /// - Parameter error: What `WebSocket.connect` failed with.
    /// - Returns: A description that quotes nothing the server sent but its status code.
    static func describe(connectFailure error: any Error) -> String {
        if case .invalidResponseStatus(let head) = error as? WebSocketClient.Error {
            return "The server answered the WebSocket upgrade with HTTP \(head.status.code)"
        }
        return error.localizedDescription
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
    public func send(_ data: Data) async throws {
        guard let ws = webSocket, isConnected else {
            throw MCPError.connectionFailed(reason: "WebSocketTransport is not connected")
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        try await ws.send(text)
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
