import Testing
import Foundation
@testable import MCPClient

// MockURLProtocol requires URLProtocol.client (Apple only)
#if !canImport(FoundationNetworking)

@Suite("HTTPSSETransport", .serialized)
struct HTTPSSETransportTests {

    // MARK: - Initialization

    @Test("Initializes with URL and default parameters")
    func initWithDefaults() {
        let _ = HTTPSSETransport(url: URL(string: "https://mcp.example.com/sse")!)
        // Should not throw — just verifying init doesn't crash
    }

    @Test("Initializes with custom headers and timeout")
    func initWithCustomParams() {
        let _ = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!,
            headers: ["Authorization": "Bearer token123"],
            connectionTimeout: 60.0,
            maxReconnectAttempts: 5,
            reconnectBaseDelay: 2.0
        )
    }

    // MARK: - Connect

    @Test("Connect extracts endpoint URL from SSE endpoint event")
    func connectExtractsEndpoint() async throws {
        let baseURL = "https://mcp.example.com"
        let sseURL = "\(baseURL)/sse"
        let sseBody = "event: endpoint\ndata: /messages?sessionId=abc123\n\n"

        MockURLProtocol.reset()
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: sseBody.data(using: .utf8) ?? Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            urlSessionConfiguration: mockSessionConfiguration()
        )

        try await transport.connect()
        // If connect() succeeds, it parsed the endpoint event correctly
    }

    @Test("Connect throws connectionFailed when server unreachable")
    func connectThrowsOnUnreachable() async {
        MockURLProtocol.reset()
        // No response registered — will get connection error

        let transport = HTTPSSETransport(
            url: URL(string: "https://unreachable.example.com/sse")!,
            maxReconnectAttempts: 0,
            urlSessionConfiguration: mockSessionConfiguration()
        )

        do {
            try await transport.connect()
            Issue.record("Expected connectionFailed error")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("Connect throws connectionFailed when no endpoint event received")
    func connectThrowsOnMissingEndpoint() async {
        let sseURL = "https://mcp.example.com/sse"
        // Server sends data but no endpoint event
        let sseBody = "data: not an endpoint\n\n"

        MockURLProtocol.reset()
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: sseBody.data(using: .utf8) ?? Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            maxReconnectAttempts: 0,
            urlSessionConfiguration: mockSessionConfiguration()
        )

        do {
            try await transport.connect()
            Issue.record("Expected connectionFailed error")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    // MARK: - Send

    @Test("Send posts JSON-RPC data to endpoint URL")
    func sendPostsToEndpoint() async throws {
        let baseURL = "https://mcp.example.com"
        let sseURL = "\(baseURL)/sse"
        let messagesURL = "\(baseURL)/messages?sessionId=abc123"

        MockURLProtocol.reset()
        // SSE endpoint event
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: "event: endpoint\ndata: /messages?sessionId=abc123\n\nevent: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}\n\n".data(using: .utf8) ?? Data()
        )
        // POST response
        MockURLProtocol.registerResponse(
            for: messagesURL,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.connect()

        let jsonRPC = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}".data(using: .utf8) ?? Data()
        try await transport.send(jsonRPC)

        // Verify a POST was made to the messages endpoint
        let requests = MockURLProtocol.getRecordedRequests()
        let postRequests = requests.filter { $0.httpMethod == "POST" }
        #expect(postRequests.count >= 1)
    }

    @Test("Send throws connectionFailed when not connected")
    func sendThrowsWhenNotConnected() async {
        let transport = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!,
            urlSessionConfiguration: mockSessionConfiguration()
        )

        let data = "{}".data(using: .utf8) ?? Data()
        do {
            try await transport.send(data)
            Issue.record("Expected connectionFailed error")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    @Test("Send throws requestFailed on HTTP error response")
    func sendThrowsOnHTTPError() async throws {
        let baseURL = "https://mcp.example.com"
        let sseURL = "\(baseURL)/sse"
        let messagesURL = "\(baseURL)/messages?sessionId=abc123"

        MockURLProtocol.reset()
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: "event: endpoint\ndata: /messages?sessionId=abc123\n\nevent: message\ndata: {}\n\n".data(using: .utf8) ?? Data()
        )
        MockURLProtocol.registerResponse(
            for: messagesURL,
            statusCode: 500,
            headers: [:],
            body: Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.connect()

        do {
            try await transport.send("{}".data(using: .utf8) ?? Data())
            Issue.record("Expected requestFailed error")
        } catch let error as MCPError {
            guard case .requestFailed = error else {
                Issue.record("Expected requestFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    // MARK: - Receive

    @Test("Receive returns JSON-RPC data from SSE message event")
    func receiveReturnsJSONRPC() async throws {
        let sseURL = "https://mcp.example.com/sse"
        let jsonResponse = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}"
        let sseBody = "event: endpoint\ndata: /messages\n\nevent: message\ndata: \(jsonResponse)\n\n"

        MockURLProtocol.reset()
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: sseBody.data(using: .utf8) ?? Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.connect()

        let data = try await transport.receive()
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(decoded.id == 1)
    }

    @Test("Receive throws connectionFailed when not connected")
    func receiveThrowsWhenNotConnected() async {
        let transport = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!,
            urlSessionConfiguration: mockSessionConfiguration()
        )

        do {
            _ = try await transport.receive()
            Issue.record("Expected connectionFailed error")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }
    }

    // MARK: - Disconnect

    @Test("Disconnect can be called without error")
    func disconnectSucceeds() async throws {
        let sseURL = "https://mcp.example.com/sse"
        MockURLProtocol.reset()
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: "event: endpoint\ndata: /messages\n\n".data(using: .utf8) ?? Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.connect()
        try await transport.disconnect()
    }

    @Test("Disconnect without connect does not throw")
    func disconnectWithoutConnect() async throws {
        let transport = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!,
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.disconnect()
    }

    // MARK: - Custom Headers

    @Test("Custom headers are sent with SSE connection request")
    func customHeadersSent() async throws {
        let sseURL = "https://mcp.example.com/sse"
        MockURLProtocol.reset()
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: "event: endpoint\ndata: /messages\n\n".data(using: .utf8) ?? Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            headers: ["Authorization": "Bearer test-token"],
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.connect()

        let requests = MockURLProtocol.getRecordedRequests()
        let sseRequest = requests.first { $0.url?.absoluteString == sseURL }
        #expect(sseRequest != nil)
        // Check allHTTPHeaderFields which captures all headers set on the request
        let authHeader = sseRequest?.allHTTPHeaderFields?["Authorization"]
        #expect(authHeader == "Bearer test-token")
    }

    // MARK: - POST Response Body

    @Test("Send enqueues POST response body for receive")
    func sendEnqueuesPostResponseBody() async throws {
        // Some MCP servers return JSON-RPC responses in the POST response body
        // rather than via the SSE stream. Verify send() enqueues this for receive().
        let baseURL = "https://mcp.example.com"
        let sseURL = "\(baseURL)/sse"
        let messagesURL = "\(baseURL)/messages?sessionId=abc123"
        let jsonResponse = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2024-11-05\"}}"

        MockURLProtocol.reset()
        // SSE: only endpoint event, no message events
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: "event: endpoint\ndata: /messages?sessionId=abc123\n\n".data(using: .utf8) ?? Data()
        )
        // POST: returns JSON-RPC response in body
        MockURLProtocol.registerResponse(
            for: messagesURL,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: jsonResponse.data(using: .utf8) ?? Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.connect()

        let request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}".data(using: .utf8) ?? Data()
        try await transport.send(request)

        // receive() should return the response from the POST body
        let data = try await transport.receive()
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(decoded.id == 1)
    }

    @Test("Send does not enqueue empty POST response body")
    func sendDoesNotEnqueueEmptyBody() async throws {
        let baseURL = "https://mcp.example.com"
        let sseURL = "\(baseURL)/sse"
        let messagesURL = "\(baseURL)/messages?sessionId=abc123"
        let jsonResponse = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}}"

        MockURLProtocol.reset()
        // SSE: endpoint + message event (response comes via SSE, not POST body)
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: "event: endpoint\ndata: /messages?sessionId=abc123\n\nevent: message\ndata: \(jsonResponse)\n\n".data(using: .utf8) ?? Data()
        )
        // POST: empty response body
        MockURLProtocol.registerResponse(
            for: messagesURL,
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data()
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            urlSessionConfiguration: mockSessionConfiguration()
        )
        try await transport.connect()

        let request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}".data(using: .utf8) ?? Data()
        try await transport.send(request)

        // receive() should return the SSE message, not a duplicate from POST
        let data = try await transport.receive()
        let decoded = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(decoded.id == 1)
    }

    // MARK: - Reconnection

    @Test("Reconnect attempt on stream termination")
    func reconnectOnStreamTermination() async throws {
        // When the SSE stream drops, transport should attempt reconnection
        // before throwing connectionFailed. This test verifies multiple
        // connection attempts are made.
        let sseURL = "https://mcp.example.com/sse"
        MockURLProtocol.reset()
        // First attempt: stream ends without endpoint event (simulates drop)
        // After max retries, should throw connectionFailed
        MockURLProtocol.registerResponse(
            for: sseURL,
            statusCode: 200,
            headers: ["Content-Type": "text/event-stream"],
            body: Data() // Empty body — stream ends immediately
        )

        let transport = HTTPSSETransport(
            url: URL(string: sseURL)!,
            maxReconnectAttempts: 2,
            reconnectBaseDelay: 0.01, // Fast for tests
            urlSessionConfiguration: mockSessionConfiguration()
        )

        do {
            try await transport.connect()
            Issue.record("Expected connectionFailed after max retries")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
        }

        // Should have made multiple attempts (initial + retries)
        let requests = MockURLProtocol.getRecordedRequests()
        #expect(requests.count >= 2)
    }

    // MARK: - Helpers

    private func mockSessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return config
    }
}

#endif
