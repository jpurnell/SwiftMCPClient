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
/// ## Reconnection
///
/// If the WebSocket connection drops, create a new transport instance —
/// `WebSocketTransport` does not auto-reconnect.
public actor WebSocketTransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private let trustSelfSignedCertificates: Bool
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
    ///   - trustSelfSignedCertificates: Accept self-signed or invalid TLS certificates.
    ///     Works on both macOS and Linux.
    public init(
        url: URL,
        headers: [String: String] = [:],
        trustSelfSignedCertificates: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.trustSelfSignedCertificates = trustSelfSignedCertificates
    }

    public func connect() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoopGroup = group

        var tlsConfig = TLSConfiguration.makeClientConfiguration()
        if trustSelfSignedCertificates {
            tlsConfig.certificateVerification = .none
        }

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
            try? await group.shutdownGracefully()
            eventLoopGroup = nil
            throw MCPError.connectionFailed(reason: error.localizedDescription)
        }
    }

    public func disconnect() async throws {
        if let ws = webSocket {
            try? await ws.close()
            webSocket = nil
        }

        isConnected = false
        messageQueue.removeAll()

        messageContinuation?.resume(throwing: MCPError.connectionFailed(reason: "Disconnected"))
        messageContinuation = nil

        if let group = eventLoopGroup {
            eventLoopGroup = nil
            try? await group.shutdownGracefully()
        }
    }

    public func send(_ data: Data) async throws {
        guard let ws = webSocket, isConnected else {
            throw MCPError.connectionFailed(reason: "WebSocketTransport is not connected")
        }

        let text = String(data: data, encoding: .utf8) ?? ""
        try await ws.send(text)
    }

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
