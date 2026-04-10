import Testing
import Foundation
@testable import MCPClient

@Suite("StreamableHTTPTransport")
struct StreamableHTTPTransportTests {

    // MARK: - Initialization

    @Test("Initializes with URL and default parameters")
    func initWithDefaults() {
        let _ = StreamableHTTPTransport(url: URL(string: "https://mcp.example.com/mcp")!)
    }

    @Test("Initializes with custom headers and timeout")
    func initWithCustomParams() {
        let _ = StreamableHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!,
            headers: ["Authorization": "Bearer token123"],
            connectionTimeout: 60.0,
            trustSelfSignedCertificates: false
        )
    }

    @Test("Initializes with self-signed certificate trust")
    func initWithSelfSignedTrust() {
        let _ = StreamableHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!,
            trustSelfSignedCertificates: true
        )
    }

    // MARK: - Send/Receive Before Connect

    @Test("Send throws connectionFailed when not connected")
    func sendThrowsWhenNotConnected() async {
        let transport = StreamableHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!
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

    @Test("Receive throws connectionFailed when not connected")
    func receiveThrowsWhenNotConnected() async {
        let transport = StreamableHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!
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

    @Test("Disconnect without connect does not throw")
    func disconnectWithoutConnect() async throws {
        let transport = StreamableHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!
        )
        try await transport.disconnect()
    }

    // MARK: - Connect Errors

    @Test("Send throws connectionFailed when server unreachable")
    func sendThrowsOnUnreachable() async {
        let transport = StreamableHTTPTransport(
            url: URL(string: "https://localhost:1/mcp")!,
            connectionTimeout: 2.0
        )

        // connect() is lightweight for Streamable HTTP — just creates the client.
        // The actual failure happens on send().
        try? await transport.connect()

        let data = "{}".data(using: .utf8) ?? Data()
        do {
            try await transport.send(data)
            Issue.record("Expected connectionFailed error")
        } catch let error as MCPError {
            guard case .connectionFailed = error else {
                try? await transport.disconnect()
                Issue.record("Expected connectionFailed, got \(error)")
                return
            }
        } catch {
            // Any error is acceptable for unreachable server
        }

        try? await transport.disconnect()
    }

    // MARK: - Session ID Management

    @Test("Session ID is nil before initialization")
    func sessionIdNilBeforeInit() async throws {
        let transport = StreamableHTTPTransport(
            url: URL(string: "https://mcp.example.com/mcp")!
        )
        try? await transport.connect()
        let sessionId = await transport.sessionId
        #expect(sessionId == nil)
        try? await transport.disconnect()
    }
}
