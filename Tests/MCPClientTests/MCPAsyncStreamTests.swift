import Testing
import Foundation
@testable import MCPClient

@Suite("AsyncSequence Streaming API")
struct MCPAsyncStreamTests {

    @Test("progressUpdates filters only progress notifications")
    func progressUpdatesStream() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "test", "version": "0.1"}
            }
        }
        """)
        // Enqueue notifications: progress, log, progress
        await transport.enqueueResponse("""
        {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "t1", "progress": 0.5, "total": 1.0}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "hello"}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": "t1", "progress": 1.0, "total": 1.0}}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        // Collect from typed stream
        var progressValues: [Double] = []
        let stream = await client.progressUpdates
        // Give dispatcher time to consume messages
        try await Task.sleep(for: .milliseconds(100))

        for await p in stream {
            progressValues.append(p.progress)
            if progressValues.count >= 2 { break }
        }
        #expect(progressValues == [0.5, 1.0])
    }

    @Test("logMessages filters only log notifications")
    func logMessagesStream() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "test", "version": "0.1"}
            }
        }
        """)
        await transport.enqueueResponse("""
        {"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "warning", "data": "disk low"}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        try await Task.sleep(for: .milliseconds(100))

        var messages: [MCPLogMessage] = []
        let stream = await client.logMessages
        for await msg in stream {
            messages.append(msg)
            if messages.count >= 1 { break }
        }
        #expect(messages.count == 1)
        #expect(messages[0].level == .warning)
    }

    @Test("toolListChanges yields Void on change")
    func toolListChangesStream() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "test", "version": "0.1"}
            }
        }
        """)
        await transport.enqueueResponse("""
        {"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        try await Task.sleep(for: .milliseconds(100))

        var count = 0
        let stream = await client.toolListChanges
        for await _ in stream {
            count += 1
            if count >= 1 { break }
        }
        #expect(count == 1)
    }

    @Test("resourceUpdates yields URI strings")
    func resourceUpdatesStream() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "serverInfo": {"name": "test", "version": "0.1"}
            }
        }
        """)
        await transport.enqueueResponse("""
        {"jsonrpc": "2.0", "method": "notifications/resources/updated", "params": {"uri": "file:///data.json"}}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        try await Task.sleep(for: .milliseconds(100))

        var uris: [String] = []
        let stream = await client.resourceUpdates
        for await uri in stream {
            uris.append(uri)
            if uris.count >= 1 { break }
        }
        #expect(uris == ["file:///data.json"])
    }
}
