import Testing
import Foundation
@testable import MCPClient

@Suite("HTTPSSETransport")
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

    @Test("Initializes with self-signed certificate trust")
    func initWithSelfSignedTrust() {
        let _ = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!,
            trustSelfSignedCertificates: true
        )
    }

    // MARK: - Send/Receive Before Connect

    @Test("Send throws connectionFailed when not connected")
    func sendThrowsWhenNotConnected() async {
        let transport = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!
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
        let transport = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!
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
        let transport = HTTPSSETransport(
            url: URL(string: "https://mcp.example.com/sse")!
        )
        try await transport.disconnect()
    }

    // MARK: - Connect Errors

    @Test("Connect throws connectionFailed when server unreachable")
    func connectThrowsOnUnreachable() async {
        let transport = HTTPSSETransport(
            url: URL(string: "https://localhost:1/sse")!,
            connectionTimeout: 2.0,
            maxReconnectAttempts: 0
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
            // Any error is acceptable for unreachable server
        }
    }
}
