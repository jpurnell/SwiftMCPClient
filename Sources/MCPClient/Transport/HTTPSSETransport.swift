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
/// ## Reconnection
///
/// If the SSE stream drops during ``connect()``, the transport automatically
/// retries up to ``maxReconnectAttempts`` times with exponential backoff
/// starting from ``reconnectBaseDelay``.
///
/// ## Cross-Platform
///
/// Uses `AsyncHTTPClient` (Swift NIO) for HTTP and TLS, providing identical
/// behavior on macOS and Linux. Self-signed certificate support works on
/// all platforms via NIO SSL.
public actor HTTPSSETransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private let connectionTimeout: TimeInterval
    private let maxReconnectAttempts: Int
    private let reconnectBaseDelay: TimeInterval
    private let trustSelfSignedCertificates: Bool

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
    ///   - connectionTimeout: Maximum time to wait for the initial endpoint event. Default 30s.
    ///   - maxReconnectAttempts: Number of reconnection attempts on stream drop. Default 3.
    ///   - reconnectBaseDelay: Base delay for exponential backoff in seconds. Default 1.0.
    ///   - trustSelfSignedCertificates: Accept self-signed or invalid TLS certificates.
    ///     **Use only for development/testing** — this disables certificate validation.
    ///     Works on both macOS and Linux.
    public init(
        url: URL,
        headers: [String: String] = [:],
        connectionTimeout: TimeInterval = 30.0,
        maxReconnectAttempts: Int = 3,
        reconnectBaseDelay: TimeInterval = 1.0,
        trustSelfSignedCertificates: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.connectionTimeout = connectionTimeout
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBaseDelay = reconnectBaseDelay
        self.trustSelfSignedCertificates = trustSelfSignedCertificates
    }

    public func connect() async throws {
        var lastError: (any Error)?

        for attempt in 0...maxReconnectAttempts {
            if attempt > 0 {
                let delay = reconnectBaseDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                try await performConnect()
                return
            } catch {
                lastError = error
                // Clean up the HTTP client on failure so it doesn't leak
                if let client = httpClient {
                    httpClient = nil
                    try? await client.shutdown()
                }
            }
        }

        throw lastError ?? MCPError.connectionFailed(
            reason: "Failed to connect after \(maxReconnectAttempts) retries"
        )
    }

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
            try? await client.shutdown()
        }
    }

    public func send(_ data: Data) async throws {
        guard let endpointURL = endpointURL, let client = httpClient else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        var request = HTTPClientRequest(url: endpointURL.absoluteString)
        request.method = .POST
        request.headers.add(name: "Content-Type", value: "application/json")
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
        let client = makeHTTPClient()
        self.httpClient = client

        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        request.headers.add(name: "Accept", value: "text/event-stream")
        request.headers.add(name: "Cache-Control", value: "no-cache")
        for (key, value) in headers {
            request.headers.replaceOrAdd(name: key, value: value)
        }

        let response: HTTPClientResponse
        do {
            response = try await client.execute(request, timeout: .seconds(Int64(connectionTimeout)))
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
                    guard let resolvedEndpoint = URL(
                        string: event.data, relativeTo: url
                    )?.absoluteURL else {
                        throw MCPError.connectionFailed(
                            reason: "Invalid endpoint URL: \(event.data)"
                        )
                    }

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

    /// Continue reading SSE messages in the background using the same iterator.
    private func startBackgroundStream(
        iterator: sending HTTPClientResponse.Body.AsyncIterator,
        parser: sending SSEParser
    ) {
        nonisolated(unsafe) var iterator = iterator
        nonisolated(unsafe) var parser = parser
        streamTask = Task { [weak self] in
            do {
                while let buffer = try await iterator.next() {
                    guard let self = self else { return }
                    guard let text = String(buffer: buffer, encoding: .utf8) else { continue }
                    let events = parser.append(text)

                    for event in events {
                        if event.event == "message" || event.event == nil {
                            if let data = event.data.data(using: .utf8) {
                                await self.enqueueMessage(data)
                            }
                        }
                    }
                }
            } catch {
                // Stream ended or errored
            }

            // Stream has ended
            guard let self = self else { return }
            await self.handleStreamEnd()
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
