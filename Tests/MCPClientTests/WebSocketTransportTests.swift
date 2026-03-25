import Testing
import Foundation
@testable import MCPClient

@Suite("WebSocketTransport")
struct WebSocketTransportTests {

    @Test("WebSocketTransport initializes with URL")
    func initWithURL() {
        let url = URL(string: "ws://localhost:8080/mcp")!
        let transport = WebSocketTransport(url: url)
        // Should not crash — transport created but not connected
        _ = transport
    }

    @Test("WebSocketTransport initializes with custom headers")
    func initWithHeaders() {
        let url = URL(string: "wss://mcp.example.com/ws")!
        let transport = WebSocketTransport(url: url, headers: ["Authorization": "Bearer token"])
        _ = transport
    }

    @Test("Send before connect throws")
    func sendBeforeConnect() async throws {
        let url = URL(string: "ws://localhost:1/mcp")!
        let transport = WebSocketTransport(url: url)

        await #expect(throws: MCPError.self) {
            try await transport.send("{}".data(using: .utf8)!)
        }
    }

    @Test("Receive before connect throws")
    func receiveBeforeConnect() async throws {
        let url = URL(string: "ws://localhost:1/mcp")!
        let transport = WebSocketTransport(url: url)

        await #expect(throws: MCPError.self) {
            _ = try await transport.receive()
        }
    }

    @Test("Disconnect without connect does not throw")
    func disconnectWithoutConnect() async throws {
        let url = URL(string: "ws://localhost:1/mcp")!
        let transport = WebSocketTransport(url: url)
        try await transport.disconnect()
    }
}
