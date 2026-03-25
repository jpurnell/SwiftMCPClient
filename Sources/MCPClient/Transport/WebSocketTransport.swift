import Foundation

// URLSessionWebSocketTask is not available on Linux (swift-corelibs-foundation).
// WebSocketTransport is Apple-platforms only.
#if !canImport(FoundationNetworking)

/// A transport that communicates with an MCP server over WebSocket.
///
/// `WebSocketTransport` uses `URLSessionWebSocketTask` (Foundation) to
/// send and receive JSON-RPC messages as WebSocket text frames. No external
/// dependencies are required.
///
/// > Note: This transport is only available on Apple platforms.
/// > Linux does not support `URLSessionWebSocketTask`.
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
    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var isConnected: Bool = false

    /// Creates a new WebSocket transport.
    ///
    /// - Parameters:
    ///   - url: The WebSocket URL to connect to (ws:// or wss://).
    ///   - headers: Optional HTTP headers to include in the upgrade request.
    public init(url: URL, headers: [String: String] = [:]) {
        self.url = url
        self.headers = headers
    }

    public func connect() async throws {
        var request = URLRequest(url: url)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        task.resume()

        self.session = session
        self.webSocketTask = task
        self.isConnected = true
    }

    public func disconnect() async throws {
        guard let task = webSocketTask else { return }
        task.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
    }

    public func send(_ data: Data) async throws {
        guard let task = webSocketTask, isConnected else {
            throw MCPError.connectionFailed(reason: "WebSocketTransport is not connected")
        }

        let message = URLSessionWebSocketTask.Message.string(
            String(data: data, encoding: .utf8) ?? ""
        )
        try await task.send(message)
    }

    public func receive() async throws -> Data {
        guard let task = webSocketTask, isConnected else {
            throw MCPError.connectionFailed(reason: "WebSocketTransport is not connected")
        }

        let message = try await task.receive()
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else {
                throw MCPError.invalidResponse
            }
            return data
        case .data(let data):
            return data
        @unknown default:
            throw MCPError.invalidResponse
        }
    }
}

#endif
