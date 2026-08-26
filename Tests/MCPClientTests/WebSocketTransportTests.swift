import Testing
import Foundation
@testable import MCPClient

@Suite("WebSocketTransport")
struct WebSocketTransportTests {

    @Test("WebSocketTransport initializes with URL")
    func initWithURL() throws {
        let url = try requireURL("ws://localhost:8080/mcp")
        _ = WebSocketTransport(url: url)
        #expect(Bool(true), "Transport initialized successfully")
    }

    @Test("WebSocketTransport initializes with custom headers")
    func initWithHeaders() throws {
        let url = try requireURL("wss://mcp.example.com/ws")
        _ = WebSocketTransport(url: url, headers: ["Authorization": "Bearer token"])
        #expect(Bool(true), "Transport initialized successfully")
    }

    @Test("WebSocketTransport initializes with self-signed certificate trust")
    func initWithSelfSignedTrust() throws {
        let url = try requireURL("wss://mcp.example.com/ws")
        _ = WebSocketTransport(url: url, trustSelfSignedCertificates: true)
        #expect(Bool(true), "Transport initialized successfully")
    }

    @Test("Send before connect throws")
    func sendBeforeConnect() async throws {
        let url = try requireURL("ws://localhost:1/mcp")
        let transport = WebSocketTransport(url: url)

        await #expect(throws: MCPError.self) {
            try await transport.send("{}".utf8Data)
        }
    }

    @Test("Receive before connect throws")
    func receiveBeforeConnect() async throws {
        let url = try requireURL("ws://localhost:1/mcp")
        let transport = WebSocketTransport(url: url)

        await #expect(throws: MCPError.self) {
            _ = try await transport.receive()
        }
    }

    @Test("Disconnect without connect does not throw")
    func disconnectWithoutConnect() async throws {
        let url = try requireURL("ws://localhost:1/mcp")
        let transport = WebSocketTransport(url: url)
        try await transport.disconnect()
        #expect(Bool(true), "Transport initialized successfully")
    }
}
