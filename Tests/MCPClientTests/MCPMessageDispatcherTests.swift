import Testing
import Foundation
@testable import MCPClient

@Suite("MCPMessageDispatcher")
struct MCPMessageDispatcherTests {

    // MARK: - IncomingMessage.parse

    @Test("Parses response message (has id, result, no method)")
    func parseResponse() {
        let json = """
        {"jsonrpc":"2.0","id":1,"result":{"tools":[]}}
        """.data(using: .utf8)!
        let msg = IncomingMessage.parse(json)
        if case .response(let r) = msg {
            #expect(r.id == 1)
            #expect(r.result != nil)
        } else {
            Issue.record("Expected response, got \(String(describing: msg))")
        }
    }

    @Test("Parses error response")
    func parseErrorResponse() {
        let json = """
        {"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Not found"}}
        """.data(using: .utf8)!
        let msg = IncomingMessage.parse(json)
        if case .response(let r) = msg {
            #expect(r.id == 2)
            #expect(r.error?.code == -32601)
        } else {
            Issue.record("Expected response")
        }
    }

    @Test("Parses notification (has method, no id)")
    func parseNotification() {
        let json = """
        {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"t","progress":1}}
        """.data(using: .utf8)!
        let msg = IncomingMessage.parse(json)
        if case .notification(let method, _) = msg {
            #expect(method == "notifications/progress")
        } else {
            Issue.record("Expected notification, got \(String(describing: msg))")
        }
    }

    @Test("Parses server-to-client request (has id and method)")
    func parseIncomingRequest() {
        let json = """
        {"jsonrpc":"2.0","id":5,"method":"roots/list"}
        """.data(using: .utf8)!
        let msg = IncomingMessage.parse(json)
        if case .request(let id, let method, _) = msg {
            #expect(id == 5)
            #expect(method == "roots/list")
        } else {
            Issue.record("Expected request, got \(String(describing: msg))")
        }
    }

    @Test("Returns nil for invalid JSON")
    func parseInvalid() {
        let data = "not json".data(using: .utf8)!
        #expect(IncomingMessage.parse(data) == nil)
    }

    // MARK: - Dispatcher response routing

    @Test("Routes buffered response to waiting continuation")
    func routesBufferedResponse() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"ok":true}}
        """)

        try await transport.connect()
        let dispatcher = MCPMessageDispatcher(transport: transport)
        await dispatcher.start()

        // Give read loop time to buffer the response
        try await Task.sleep(for: .milliseconds(50))

        let response = try await dispatcher.waitForResponse(id: 1)
        #expect(response.id == 1)
        #expect(response.result != nil)

        await dispatcher.stop()
    }

    @Test("Routes multiple responses to correct callers by ID")
    func routesMultipleResponses() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"value":"first"}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"value":"second"}}
        """)

        try await transport.connect()
        let dispatcher = MCPMessageDispatcher(transport: transport)
        await dispatcher.start()

        // Let read loop buffer both
        try await Task.sleep(for: .milliseconds(50))

        let r1 = try await dispatcher.waitForResponse(id: 1)
        let r2 = try await dispatcher.waitForResponse(id: 2)

        #expect(r1.id == 1)
        #expect(r2.id == 2)

        await dispatcher.stop()
    }

    // MARK: - Notification routing

    @Test("Routes notifications to stream")
    func routesNotifications() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","method":"notifications/tools/list_changed"}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{}}
        """)

        try await transport.connect()
        let dispatcher = MCPMessageDispatcher(transport: transport)

        let stream = await dispatcher.notificationStream
        let notificationTask = Task<MCPNotification?, Never> {
            for await notification in stream {
                return notification
            }
            return nil
        }

        await dispatcher.start()

        // Let read loop process both messages
        try await Task.sleep(for: .milliseconds(50))

        let response = try await dispatcher.waitForResponse(id: 1)
        #expect(response.id == 1)

        await dispatcher.stop()

        let notification = await notificationTask.value
        if case .toolsListChanged = notification {
            // pass
        } else {
            Issue.record("Expected toolsListChanged, got \(String(describing: notification))")
        }
    }

    @Test("Progress notification routes to stream")
    func routesProgressNotification() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","method":"notifications/progress","params":{"progressToken":"tok","progress":50,"total":100}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{}}
        """)

        try await transport.connect()
        let dispatcher = MCPMessageDispatcher(transport: transport)

        let stream = await dispatcher.notificationStream
        let notificationTask = Task<MCPNotification?, Never> {
            for await n in stream { return n }
            return nil
        }

        await dispatcher.start()
        try await Task.sleep(for: .milliseconds(50))

        _ = try await dispatcher.waitForResponse(id: 1)
        await dispatcher.stop()

        let notification = await notificationTask.value
        if case .progress(let p) = notification {
            #expect(p.progress == 50)
            #expect(p.total == 100)
        } else {
            Issue.record("Expected progress, got \(String(describing: notification))")
        }
    }

    // MARK: - Stop behavior

    @Test("Stop fails pending requests with transportClosed")
    func stopFailsPending() async throws {
        let transport = MockTransport()
        try await transport.connect()

        let dispatcher = MCPMessageDispatcher(transport: transport)
        // Don't start — we just want to test stop() with a registered continuation

        let task = Task<JSONRPCResponse?, Error> {
            try await dispatcher.waitForResponse(id: 99)
        }

        // Give continuation time to register
        try await Task.sleep(for: .milliseconds(20))
        await dispatcher.stop()

        do {
            _ = try await task.value
            Issue.record("Expected error")
        } catch {
            #expect(error is MCPError)
        }
    }

    // MARK: - Incoming request handling

    @Test("Routes incoming request to handler and sends response")
    func routesIncomingRequest() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":10,"method":"roots/list"}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"ok":true}}
        """)

        try await transport.connect()
        let dispatcher = MCPMessageDispatcher(transport: transport)

        await dispatcher.setIncomingRequestHandler { id, method, params in
            if method == "roots/list" {
                return .object(["roots": .array([
                    .object(["uri": .string("file:///project"), "name": .string("Project")])
                ])])
            }
            return nil
        }

        await dispatcher.start()
        try await Task.sleep(for: .milliseconds(50))

        let response = try await dispatcher.waitForResponse(id: 1)
        #expect(response.id == 1)

        // Give handler time to send response
        try await Task.sleep(for: .milliseconds(50))

        let sent = await transport.sentMessages()
        var foundRootsResponse = false
        for msg in sent {
            if let json = try? JSONDecoder().decode([String: AnyCodableValue].self, from: msg),
               case .integer(10) = json["id"],
               case .object(let result) = json["result"],
               case .array(_) = result["roots"] {
                foundRootsResponse = true
            }
        }
        #expect(foundRootsResponse)

        await dispatcher.stop()
    }
}
