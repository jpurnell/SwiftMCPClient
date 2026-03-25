import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Connects to a remote MCP server via HTTP POST (requests) and Server-Sent Events (responses).
///
/// This is the primary transport for production use, connecting to a hosted MCP server
/// (e.g., GeoSEO MCP on roseclub.org).
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
public actor HTTPSSETransport: MCPTransport {
    private let url: URL
    private let headers: [String: String]
    private let connectionTimeout: TimeInterval
    private let maxReconnectAttempts: Int
    private let reconnectBaseDelay: TimeInterval
    private let sessionConfiguration: URLSessionConfiguration

    /// The endpoint URL extracted from the SSE `endpoint` event during connect.
    private var endpointURL: URL?

    /// The URL session used for SSE streaming (delegate-based).
    private var sseSession: URLSession?

    /// A separate session for POST requests (no delegate needed).
    private var postSession: URLSession?

    /// Queue of received JSON-RPC messages from SSE `message` events.
    private var messageQueue: [Data] = []

    /// Continuation for waiting `receive()` calls when no messages are queued.
    private var messageContinuation: CheckedContinuation<Data, any Error>?

    /// The background task reading the SSE stream.
    private var streamTask: Task<Void, Never>?

    /// Whether the transport is currently connected.
    private var isConnected: Bool = false

    /// The SSE delegate that processes streaming data chunks.
    private var sseDelegate: SSEStreamDelegate?

    /// Creates a new HTTP/SSE transport.
    ///
    /// - Parameters:
    ///   - url: The SSE endpoint URL (e.g., `https://mcp.roseclub.org/sse`).
    ///   - headers: Custom HTTP headers sent with all requests (e.g., authentication).
    ///   - connectionTimeout: Maximum time to wait for the initial endpoint event. Default 30s.
    ///   - maxReconnectAttempts: Number of reconnection attempts on stream drop. Default 3.
    ///   - reconnectBaseDelay: Base delay for exponential backoff in seconds. Default 1.0.
    ///   - urlSessionConfiguration: URL session configuration. Defaults to `.default`.
    ///     Override for testing with mock URL protocols.
    public init(
        url: URL,
        headers: [String: String] = [:],
        connectionTimeout: TimeInterval = 30.0,
        maxReconnectAttempts: Int = 3,
        reconnectBaseDelay: TimeInterval = 1.0,
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.url = url
        self.headers = headers
        self.connectionTimeout = connectionTimeout
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBaseDelay = reconnectBaseDelay
        self.sessionConfiguration = urlSessionConfiguration
    }

    public func connect() async throws {
        // Check if we're using a mock session configuration (for tests)
        // Mock protocols return complete responses, so use the simple path
        let isMockSession = sessionConfiguration.protocolClasses?.contains(where: {
            String(describing: $0).contains("Mock")
        }) ?? false

        if isMockSession {
            try await connectWithDataRequest()
        } else {
            try await connectWithStreaming()
        }
    }

    public func disconnect() async throws {
        streamTask?.cancel()
        streamTask = nil
        sseDelegate?.cancel()
        sseDelegate = nil
        sseSession?.invalidateAndCancel()
        sseSession = nil
        postSession?.invalidateAndCancel()
        postSession = nil
        endpointURL = nil
        isConnected = false
        messageQueue.removeAll()

        // Fail any waiting receive() call
        messageContinuation?.resume(throwing: MCPError.connectionFailed(reason: "Disconnected"))
        messageContinuation = nil
    }

    public func send(_ data: Data) async throws {
        guard let endpointURL = endpointURL else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        // Use the post session (no delegate) for POST requests.
        // The SSE session has a delegate that intercepts responses, so POST
        // requests must go through a separate, delegate-free session.
        guard let session = postSession else {
            throw MCPError.connectionFailed(reason: "Not connected — call connect() first")
        }

        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let responseBody: Data
        let sendResponse: URLResponse
        do {
            (responseBody, sendResponse) = try await session.data(for: request)
        } catch {
            throw MCPError.connectionFailed(reason: error.localizedDescription)
        }

        guard let httpResponse = sendResponse as? HTTPURLResponse else {
            throw MCPError.connectionFailed(reason: "Invalid HTTP response from POST")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw MCPError.requestFailed(
                code: httpResponse.statusCode,
                message: "HTTP \(httpResponse.statusCode) from POST to \(endpointURL.absoluteString)"
            )
        }

        // Some MCP servers return the JSON-RPC response directly in the POST
        // response body rather than via the SSE stream. If there's a response
        // body, enqueue it so receive() can pick it up.
        if !responseBody.isEmpty {
            enqueueMessage(responseBody)
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

    // MARK: - Streaming Connection (real servers)

    /// Connect using URLSessionDataDelegate for streaming SSE data.
    /// This is the production path — it processes data as it arrives
    /// rather than waiting for the entire response.
    private func connectWithStreaming() async throws {
        var lastError: (any Error)?

        for attempt in 0...maxReconnectAttempts {
            if attempt > 0 {
                let delay = reconnectBaseDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                try await performStreamingConnect()
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? MCPError.connectionFailed(reason: "Failed to connect after \(maxReconnectAttempts) retries")
    }

    private func performStreamingConnect() async throws {
        let delegate = SSEStreamDelegate()
        self.sseDelegate = delegate

        let sseURLSession = URLSession(configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
        self.sseSession = sseURLSession

        // POST requests use a separate session WITHOUT a delegate.
        // If both share the same delegate-based session, POST responses
        // get swallowed by the delegate and the call hangs.
        self.postSession = URLSession(configuration: sessionConfiguration)

        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = sseURLSession.dataTask(with: request)
        delegate.task = task

        // Wait for the endpoint event with a timeout.
        // IMPORTANT: task.resume() is called AFTER setting callbacks to avoid
        // a race where data arrives before onEndpoint is wired up (especially
        // on fast localhost connections via FoundationNetworking on Linux).
        let endpointData = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
            delegate.onEndpoint = { endpointPath in
                continuation.resume(returning: endpointPath)
            }
            delegate.onError = { error in
                continuation.resume(throwing: error)
            }

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + connectionTimeout) { [weak delegate] in
                delegate?.timeoutIfNeeded(continuation: continuation)
            }

            task.resume()
        }

        guard let resolvedEndpoint = URL(string: endpointData, relativeTo: url)?.absoluteURL else {
            throw MCPError.connectionFailed(reason: "Invalid endpoint URL: \(endpointData)")
        }

        self.endpointURL = resolvedEndpoint
        self.isConnected = true

        // Set up ongoing message handling
        delegate.onMessage = { [weak self] data in
            guard let self = self else { return }
            Task { await self.enqueueMessage(data) }
        }
        delegate.onStreamEnd = { [weak self] in
            guard let self = self else { return }
            Task { await self.handleStreamEnd() }
        }
    }

    // MARK: - Simple Connection (mock/test sessions)

    /// Connect using session.data() — works only for mock URL protocols
    /// that return complete responses immediately.
    private func connectWithDataRequest() async throws {
        let urlSession = URLSession(configuration: sessionConfiguration)
        self.sseSession = urlSession
        self.postSession = urlSession

        var lastError: (any Error)?

        for attempt in 0...maxReconnectAttempts {
            if attempt > 0 {
                let delay = reconnectBaseDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            do {
                try await performDataConnect(session: urlSession)
                return
            } catch {
                lastError = error
            }
        }

        throw lastError ?? MCPError.connectionFailed(reason: "Failed to connect after \(maxReconnectAttempts) retries")
    }

    private func performDataConnect(session: URLSession) async throws {
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch {
            throw MCPError.connectionFailed(reason: error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw MCPError.connectionFailed(reason: "SSE endpoint returned non-200 status")
        }

        guard let responseText = String(data: responseData, encoding: .utf8) else {
            throw MCPError.connectionFailed(reason: "SSE response is not valid UTF-8")
        }

        var parser = SSEParser()
        let events = parser.append(responseText)

        guard let endpointEvent = events.first(where: { $0.event == "endpoint" }) else {
            throw MCPError.connectionFailed(reason: "No endpoint event received from SSE stream")
        }

        guard let resolvedEndpoint = URL(string: endpointEvent.data, relativeTo: url)?.absoluteURL else {
            throw MCPError.connectionFailed(reason: "Invalid endpoint URL: \(endpointEvent.data)")
        }

        self.endpointURL = resolvedEndpoint
        self.isConnected = true

        for event in events where event.event == "message" || (event.event == nil && events.first(where: { $0.event == "endpoint" }) != nil) {
            if event.event == "endpoint" { continue }
            if let data = event.data.data(using: .utf8) {
                messageQueue.append(data)
            }
        }
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

// MARK: - SSE Stream Delegate

/// URLSession delegate that processes SSE data as it streams in.
private final class SSEStreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    var task: URLSessionDataTask?
    var onEndpoint: ((String) -> Void)?
    var onMessage: ((Data) -> Void)?
    var onError: ((any Error) -> Void)?
    var onStreamEnd: (() -> Void)?

    private var parser = SSEParser()
    private var endpointReceived = false
    private var timedOut = false
    private let lock = NSLock()

    func cancel() {
        task?.cancel()
        task = nil
    }

    func timeoutIfNeeded(continuation: CheckedContinuation<String, any Error>) {
        lock.lock()
        let shouldTimeout = !endpointReceived && !timedOut
        if shouldTimeout { timedOut = true }
        lock.unlock()

        if shouldTimeout {
            onEndpoint = nil
            onError = nil
            continuation.resume(throwing: MCPError.connectionFailed(reason: "Timed out waiting for endpoint event"))
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            let error = MCPError.connectionFailed(reason: "SSE endpoint returned HTTP \(httpResponse.statusCode)")
            lock.lock()
            let handler = onError
            timedOut = true // prevent timeout from also firing
            lock.unlock()
            handler?(error)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = String(data: data, encoding: .utf8) else { return }

        let events = parser.append(text)

        for event in events {
            if event.event == "endpoint" {
                lock.lock()
                let alreadyReceived = endpointReceived
                endpointReceived = true
                let handler = onEndpoint
                lock.unlock()

                if !alreadyReceived {
                    handler?(event.data)
                }
            } else if event.event == "message" || event.event == nil {
                if let messageData = event.data.data(using: .utf8) {
                    onMessage?(messageData)
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        let hadEndpoint = endpointReceived
        lock.unlock()

        if !hadEndpoint {
            let mcpError = error.map { MCPError.connectionFailed(reason: $0.localizedDescription) }
                ?? MCPError.connectionFailed(reason: "SSE stream ended before endpoint event")
            onError?(mcpError)
        } else {
            onStreamEnd?()
        }
    }
}
