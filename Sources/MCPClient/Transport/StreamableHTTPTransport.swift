import Foundation
import AsyncHTTPClient
import NIOCore
import NIOHTTP1
import NIOFoundationCompat
import NIOSSL

/// Connects to a remote MCP server via Streamable HTTP (MCP spec 2025-03-26).
///
/// All communication flows through a single `POST /mcp` endpoint. The server
/// returns JSON-RPC responses directly in the POST response body. Session
/// continuity is maintained via the `Mcp-Session-Id` header.
///
/// ## Protocol Flow
///
/// 1. **Connect:** Creates the HTTP client (no network call needed).
/// 2. **Send:** POSTs JSON-RPC to `/mcp`. Captures `Mcp-Session-Id` from
///    the response headers. Enqueues the response body for ``receive()``.
/// 3. **Receive:** Returns the next queued response, or suspends until one
///    arrives from a ``send()`` call.
/// 4. **Disconnect:** Sends `DELETE /mcp` with session ID to terminate the
///    session, then shuts down the HTTP client.
///
/// ## Advantages Over Legacy SSE
///
/// - No long-lived SSE connection to maintain
/// - Each request is self-contained (better for ephemeral/serverless environments)
/// - Session survives connection drops (server tracks state via session ID)
///
/// ## Cross-Platform
///
/// Uses `AsyncHTTPClient` (Swift NIO) for HTTP and TLS, providing identical
/// behavior on macOS and Linux.
public actor StreamableHTTPTransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private let connectionTimeout: TimeInterval
    private let trustSelfSignedCertificates: Bool

    /// The HTTP client used for all requests.
    private var httpClient: HTTPClient?

    /// Session ID returned by the server on initialize.
    public private(set) var sessionId: String?

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
    ///   - connectionTimeout: Maximum time to wait for each HTTP request. Default 30s.
    ///   - trustSelfSignedCertificates: Accept self-signed or invalid TLS certificates.
    ///     **Use only for development/testing** — this disables certificate validation.
    public init(
        url: URL,
        headers: [String: String] = [:],
        connectionTimeout: TimeInterval = 30.0,
        trustSelfSignedCertificates: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.connectionTimeout = connectionTimeout
        self.trustSelfSignedCertificates = trustSelfSignedCertificates
    }

    public func connect() async throws {
        httpClient = makeHTTPClient()
        isConnected = true
    }

    public func disconnect() async throws {
        defer { isConnected = false }

        // Terminate the session on the server if we have a session ID
        if let client = httpClient, let sid = sessionId {
            var request = HTTPClientRequest(url: url.absoluteString)
            request.method = .DELETE
            request.headers.add(name: "Mcp-Session-Id", value: sid)
            for (key, value) in headers {
                request.headers.replaceOrAdd(name: key, value: value)
            }
            _ = try? await client.execute(request, timeout: .seconds(Int64(connectionTimeout)))
        }

        sessionId = nil
        messageQueue.removeAll()

        // Fail any waiting receive() call
        messageContinuation?.resume(throwing: MCPError.connectionFailed(reason: "Disconnected"))
        messageContinuation = nil

        if let client = httpClient {
            httpClient = nil
            try? await client.shutdown()
        }
    }

    public func send(_ data: Data) async throws {
        guard let client = httpClient, isConnected else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
        request.headers.add(name: "Accept", value: "application/json, text/event-stream")
        if let sid = sessionId {
            request.headers.add(name: "Mcp-Session-Id", value: sid)
        }
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }
        request.body = .bytes(data)

        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, timeout: .seconds(Int64(connectionTimeout)))
        } catch {
            throw MCPError.connectionFailed(reason: error.localizedDescription)
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

        // Capture session ID from response headers
        if let sid = response.headers.first(name: "Mcp-Session-Id") {
            sessionId = sid
        }

        // Read response body — the JSON-RPC result
        let body = try await response.body.collect(upTo: 10 * 1024 * 1024) // 10MB limit
        let responseData = Data(buffer: body)
        if !responseData.isEmpty {
            enqueueMessage(responseData)
        }
    }

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
