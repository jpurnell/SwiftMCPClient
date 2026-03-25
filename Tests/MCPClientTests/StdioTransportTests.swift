import Testing
import Foundation
@testable import MCPClient

#if os(macOS) || os(Linux)

@Suite("StdioTransport")
struct StdioTransportTests {

    // MARK: - Initialization

    @Test("Initializes with command and default parameters")
    func initWithDefaults() {
        let transport = StdioTransport(command: "/usr/bin/cat")
        // Should not throw — just stores config
        _ = transport
    }

    @Test("Initializes with custom arguments and environment")
    func initWithCustomArgs() {
        let transport = StdioTransport(
            command: "/usr/bin/env",
            arguments: ["python3", "-m", "mcp_server"],
            environment: ["MCP_LOG_LEVEL": "debug"]
        )
        _ = transport
    }

    // MARK: - Connect + Send + Receive with cat

    @Test("Connect spawns subprocess and send/receive round-trips via cat")
    func roundTripWithCat() async throws {
        let transport = StdioTransport(command: "/bin/cat")
        try await transport.connect()

        // cat echoes stdin to stdout — send a JSON-RPC message, get it back
        let message = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        let data = message.data(using: .utf8)!
        try await transport.send(data)

        let received = try await transport.receive()
        let receivedString = String(data: received, encoding: .utf8)
        #expect(receivedString == message)

        try await transport.disconnect()
    }

    @Test("Multiple send/receive cycles work correctly")
    func multipleCycles() async throws {
        let transport = StdioTransport(command: "/bin/cat")
        try await transport.connect()

        for i in 1...3 {
            let msg = "{\"jsonrpc\":\"2.0\",\"id\":\(i),\"method\":\"ping\"}"
            try await transport.send(msg.data(using: .utf8)!)
            let received = try await transport.receive()
            let text = String(data: received, encoding: .utf8)
            #expect(text == msg)
        }

        try await transport.disconnect()
    }

    // MARK: - Error Handling

    @Test("Connect throws processSpawnFailed for invalid command")
    func connectInvalidCommand() async throws {
        let transport = StdioTransport(command: "/nonexistent/command/that/does/not/exist")

        await #expect(throws: MCPError.self) {
            try await transport.connect()
        }
    }

    @Test("Send throws when not connected")
    func sendBeforeConnect() async throws {
        let transport = StdioTransport(command: "/bin/cat")
        let data = "test".data(using: .utf8)!

        await #expect(throws: MCPError.self) {
            try await transport.send(data)
        }
    }

    @Test("Receive throws when not connected")
    func receiveBeforeConnect() async throws {
        let transport = StdioTransport(command: "/bin/cat")

        await #expect(throws: MCPError.self) {
            _ = try await transport.receive()
        }
    }

    // MARK: - Disconnect

    @Test("Disconnect can be called without error")
    func disconnectAfterConnect() async throws {
        let transport = StdioTransport(command: "/bin/cat")
        try await transport.connect()
        try await transport.disconnect()
    }

    @Test("Disconnect without connect does not throw")
    func disconnectWithoutConnect() async throws {
        let transport = StdioTransport(command: "/bin/cat")
        try await transport.disconnect()
    }

    @Test("Send after disconnect throws")
    func sendAfterDisconnect() async throws {
        let transport = StdioTransport(command: "/bin/cat")
        try await transport.connect()
        try await transport.disconnect()

        let data = "test".data(using: .utf8)!
        await #expect(throws: MCPError.self) {
            try await transport.send(data)
        }
    }

    // MARK: - Process Termination

    @Test("Receive throws transportClosed when process exits")
    func receiveAfterProcessExit() async throws {
        // /usr/bin/true exits immediately with 0
        let transport = StdioTransport(command: "/usr/bin/true")
        try await transport.connect()

        // Give the process a moment to exit
        try await Task.sleep(for: .milliseconds(100))

        await #expect(throws: MCPError.self) {
            _ = try await transport.receive()
        }
    }
}

#endif
