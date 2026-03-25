import Testing
import Foundation
@testable import MCPClient

@Suite("MCPClientConnection")
struct MCPClientConnectionTests {

    // MARK: - Initialize

    @Test("initialize sends correct JSON-RPC request and returns server capabilities")
    func initializeGoldenPath() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {"listChanged": true}
                },
                "serverInfo": {
                    "name": "geoseo-mcp",
                    "version": "1.0.0"
                }
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        let result = try await client.initialize(clientName: "geo-audit", clientVersion: "0.1.0")

        #expect(result.protocolVersion == "2024-11-05")
        #expect(result.serverInfo.name == "geoseo-mcp")
        #expect(result.serverInfo.version == "1.0.0")
        #expect(result.capabilities.tools?.listChanged == true)

        // Verify the sent messages: initialize request + notifications/initialized
        let sent = await transport.sentMessages()
        #expect(sent.count == 2)
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[0])
        #expect(request.method == "initialize")
        #expect(request.id == 1)
    }

    @Test("initialize sends client capabilities in request")
    func initializeSendsCapabilities() async throws {
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

        let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(
            clientName: "test",
            clientVersion: "0.1",
            capabilities: caps
        )

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[0])
        // Verify capabilities are in the params
        guard case .object(let params) = request.params,
              case .object(let capObj) = params["capabilities"],
              case .object(let rootsObj) = capObj["roots"],
              case .bool(let listChanged) = rootsObj["listChanged"] else {
            Issue.record("Expected roots capability in request params")
            return
        }
        #expect(listChanged == true)
    }

    @Test("callTool includes progressToken in _meta when provided")
    func callToolWithProgressToken() async throws {
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
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "content": [{"type": "text", "text": "done"}]
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        _ = try await client.callTool(
            name: "slow_tool",
            arguments: [:],
            progressToken: .string("token-123")
        )

        let sent = await transport.sentMessages()
        // sent[0] = initialize, sent[1] = notifications/initialized, sent[2] = tools/call
        let callRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[2])
        guard case .object(let params) = callRequest.params,
              case .object(let meta) = params["_meta"],
              case .string(let token) = meta["progressToken"] else {
            Issue.record("Expected _meta.progressToken in request params")
            return
        }
        #expect(token == "token-123")
    }

    @Test("callTool omits _meta when no progressToken")
    func callToolWithoutProgressToken() async throws {
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
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "content": [{"type": "text", "text": "done"}]
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        _ = try await client.callTool(name: "fast_tool")

        let sent = await transport.sentMessages()
        let callRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[2])
        guard case .object(let params) = callRequest.params else {
            Issue.record("Expected object params")
            return
        }
        #expect(params["_meta"] == nil)
    }

    @Test("initialize connects transport before sending")
    func initializeConnects() async throws {
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

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        #expect(await transport.state.isConnected())
    }

    // MARK: - List Tools

    @Test("listTools returns array of tool definitions")
    func listToolsGoldenPath() async throws {
        let transport = MockTransport()
        // Initialize response
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "test", "version": "0.1"}
            }
        }
        """)
        // listTools response
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "tools": [
                    {
                        "name": "score_technical_seo",
                        "description": "Calculate technical SEO score"
                    },
                    {
                        "name": "audit_meta_tags",
                        "description": "Audit meta tags"
                    }
                ]
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        let tools = try await client.listTools()

        #expect(tools.count == 2)
        #expect(tools[0].name == "score_technical_seo")
        #expect(tools[0].description == "Calculate technical SEO score")
        #expect(tools[1].name == "audit_meta_tags")
    }

    @Test("listTools returns empty array when no tools")
    func listToolsEmpty() async throws {
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
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {"tools": []}
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        let tools = try await client.listTools()

        #expect(tools.isEmpty)
    }

    @Test("listTools sends correct JSON-RPC method")
    func listToolsSendsCorrectMethod() async throws {
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
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {"tools": []}
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        _ = try await client.listTools()

        let sent = await transport.sentMessages()
        // initialize request + notification + listTools = 3
        #expect(sent.count == 3)
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[2])
        #expect(request.method == "tools/list")
        #expect(request.id == 2)
    }

    // MARK: - Call Tool

    @Test("callTool sends correct request and returns result")
    func callToolGoldenPath() async throws {
        let transport = MockTransport()
        // Initialize
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "test", "version": "0.1"}
            }
        }
        """)
        // callTool
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "content": [
                    {
                        "type": "text",
                        "text": "Technical SEO Composite Score\\nOverall Score: 74.8 / 100"
                    }
                ]
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        let result = try await client.callTool(
            name: "score_technical_seo",
            arguments: [
                "ssr_score": .number(95),
                "meta_tags_score": .number(75),
                "crawlability_score": .number(95),
                "security_score": .number(0),
                "core_web_vitals_score": .number(85),
                "mobile_score": .number(85),
                "url_score": .number(80),
                "server_response_score": .number(90)
            ]
        )

        #expect(result.content.count == 1)
        if case .text(let str, _) = result.content[0] {
            #expect(str.contains("74.8"))
        } else {
            Issue.record("Expected text content")
        }
        #expect(result.isError == nil)
    }

    @Test("callTool sends arguments in request params")
    func callToolSendsArguments() async throws {
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
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {"content": [{"type": "text", "text": "ok"}]}
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        _ = try await client.callTool(
            name: "test_tool",
            arguments: ["key": .string("value")]
        )

        let sent = await transport.sentMessages()
        // init request + notification + callTool = index 2
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[2])
        #expect(request.method == "tools/call")

        // Verify params contain name and arguments
        if case .object(let params) = request.params {
            #expect(params["name"] == .string("test_tool"))
            #expect(params["arguments"] == .object(["key": .string("value")]))
        } else {
            Issue.record("Expected params to be an object")
        }
    }

    @Test("callTool with empty arguments")
    func callToolEmptyArguments() async throws {
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
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {"content": [{"type": "text", "text": "ok"}]}
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        let result = try await client.callTool(name: "no_args_tool")

        #expect(result.content.count == 1)
    }

    @Test("callTool returns result with isError true")
    func callToolReturnsError() async throws {
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
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "content": [{"type": "text", "text": "Tool failed: invalid input"}],
                "isError": true
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        let result = try await client.callTool(name: "failing_tool")

        #expect(result.isError == true)
        if case .text(let str, _) = result.content[0] {
            #expect(str == "Tool failed: invalid input")
        } else {
            Issue.record("Expected text content")
        }
    }

    // MARK: - notifications/initialized

    @Test("initialize sends notifications/initialized after handshake")
    func initializeSendsNotification() async throws {
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

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        let sent = await transport.sentMessages()
        // Should have 2 messages: initialize request + notifications/initialized
        #expect(sent.count == 2)

        // Second message should be a notification (no id)
        let notificationJSON = try JSONDecoder().decode([String: AnyCodableValue].self, from: sent[1])
        #expect(notificationJSON["method"] == .string("notifications/initialized"))
        #expect(notificationJSON["jsonrpc"] == .string("2.0"))
        // Must NOT have an id field
        #expect(notificationJSON["id"] == nil)
    }

    // MARK: - ping

    @Test("ping sends ping request and returns true on success")
    func pingGoldenPath() async throws {
        let transport = MockTransport()
        // Initialize response
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"test","version":"0.1"}}}
        """)
        // Ping response — empty result object
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{}}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        let alive = try await client.ping()

        #expect(alive == true)

        // Verify the ping request was sent correctly
        let sent = await transport.sentMessages()
        // initialize request + notification + ping = 3
        let pingData = sent.last!
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: pingData)
        #expect(request.method == "ping")
    }

    // MARK: - Configurable Protocol Version

    @Test("initialize uses default protocol version 2024-11-05")
    func initializeDefaultVersion() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"test","version":"0.1"}}}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[0])
        if case .object(let params) = request.params {
            #expect(params["protocolVersion"] == .string("2024-11-05"))
        } else {
            Issue.record("Expected params to be an object")
        }
    }

    @Test("initialize uses custom protocol version when specified")
    func initializeCustomVersion() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-01-01","capabilities":{},"serverInfo":{"name":"test","version":"0.1"}}}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(
            clientName: "test",
            clientVersion: "0.1",
            protocolVersion: "2025-01-01"
        )

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[0])
        if case .object(let params) = request.params {
            #expect(params["protocolVersion"] == .string("2025-01-01"))
        } else {
            Issue.record("Expected params to be an object")
        }
    }

    // MARK: - Pagination

    @Test("listTools returns all tools across multiple pages")
    func listToolsPaginated() async throws {
        let transport = MockTransport()
        // Initialize
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"test","version":"0.1"}}}
        """)
        // First page with cursor
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "tools": [{"name": "tool_a", "description": "A"}],
                "nextCursor": "page2"
            }
        }
        """)
        // Second page, no cursor (last page)
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 3,
            "result": {
                "tools": [{"name": "tool_b", "description": "B"}]
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        let tools = try await client.listTools()

        #expect(tools.count == 2)
        #expect(tools[0].name == "tool_a")
        #expect(tools[1].name == "tool_b")
    }

    @Test("listTools sends cursor in subsequent page requests")
    func listToolsSendsCursor() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"test","version":"0.1"}}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"a"}],"nextCursor":"cursor123"}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":3,"result":{"tools":[{"name":"b"}]}}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        _ = try await client.listTools()

        let sent = await transport.sentMessages()
        // initialize request + notification + first listTools + second listTools = 4
        let secondListRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[3])
        #expect(secondListRequest.method == "tools/list")
        if case .object(let params) = secondListRequest.params {
            #expect(params["cursor"] == .string("cursor123"))
        } else {
            Issue.record("Expected params with cursor")
        }
    }

    // MARK: - Request ID Incrementing

    @Test("Request IDs auto-increment across calls")
    func requestIDsIncrement() async throws {
        let transport = MockTransport()
        // 3 responses: initialize, listTools, callTool
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":{},"serverInfo":{"name":"t","version":"0.1"}}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"tools":[]}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"ok"}]}}
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "t", clientVersion: "0.1")
        _ = try await client.listTools()
        _ = try await client.callTool(name: "test")

        let sent = await transport.sentMessages()
        // init request + notification + listTools + callTool = 4
        #expect(sent.count == 4)

        // Requests are at indices 0, 2, 3 (index 1 is the notification)
        let id1 = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[0]).id
        let id2 = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[2]).id
        let id3 = try JSONDecoder().decode(JSONRPCRequest.self, from: sent[3]).id

        #expect(id1 == 1)
        #expect(id2 == 2)
        #expect(id3 == 3)
    }

    // MARK: - Protocol Version Validation

    @Test("initialize accepts server with different protocol version")
    func initializeAcceptsDifferentVersion() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {
                "protocolVersion": "2025-03-26",
                "capabilities": {},
                "serverInfo": {"name": "test", "version": "0.1"}
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        let result = try await client.initialize(clientName: "test", clientVersion: "0.1")
        #expect(result.protocolVersion == "2025-03-26")
        #expect(result.serverInfo.name == "test")
    }

    @Test("initialize succeeds when protocol version matches")
    func initializeSucceedsOnVersionMatch() async throws {
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

        let client = MCPClientConnection(transport: transport)
        let result = try await client.initialize(clientName: "test", clientVersion: "0.1")
        #expect(result.protocolVersion == "2024-11-05")
    }

    // MARK: - Error Handling

    @Test("Throws requestFailed when server returns JSON-RPC error")
    func throwsOnJSONRPCError() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 1,
            "error": {
                "code": -32601,
                "message": "Method not found"
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)

        await #expect(throws: MCPError.self) {
            _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        }
    }

    @Test("Throws invalidResponse when response cannot be decoded")
    func throwsOnMalformedResponse() async throws {
        let transport = MockTransport()
        await transport.enqueueResponse("not json at all")

        let client = MCPClientConnection(transport: transport)

        await #expect(throws: (any Error).self) {
            _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        }
    }

    @Test("Throws connectionFailed when transport fails to connect")
    func throwsOnConnectionFailure() async throws {
        let transport = MockTransport()
        await transport.setConnectError(.connectionFailed(reason: "refused"))

        let client = MCPClientConnection(transport: transport)

        await #expect(throws: MCPError.self) {
            _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        }
    }

    @Test("Throws when no response available from transport")
    func throwsWhenNoResponse() async throws {
        let transport = MockTransport()
        // No responses enqueued — transport will throw on receive

        let client = MCPClientConnection(transport: transport)

        await #expect(throws: (any Error).self) {
            _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        }
    }

    // MARK: - Helpers

    /// Creates an initialized client with mock transport, ready for method calls.
    private func makeInitializedClient(capabilities: String = "{}") async throws -> (MCPClientConnection, MockTransport) {
        let transport = MockTransport()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2024-11-05","capabilities":\(capabilities),"serverInfo":{"name":"test","version":"0.1"}}}
        """)
        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        return (client, transport)
    }

    // MARK: - List Resources

    @Test("listResources returns array of resource definitions")
    func listResourcesGoldenPath() async throws {
        let (client, transport) = try await makeInitializedClient(
            capabilities: "{\"resources\":{\"subscribe\":true}}"
        )
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "resources": [
                    {"uri": "file:///logs/app.log", "name": "App Logs", "mimeType": "text/plain"},
                    {"uri": "file:///config.json", "name": "Config", "description": "App configuration"}
                ]
            }
        }
        """)

        let resources = try await client.listResources()
        #expect(resources.count == 2)
        #expect(resources[0].uri == "file:///logs/app.log")
        #expect(resources[0].name == "App Logs")
        #expect(resources[0].mimeType == "text/plain")
        #expect(resources[1].description == "App configuration")
    }

    @Test("listResources returns empty array when no resources")
    func listResourcesEmpty() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"resources":[]}}
        """)

        let resources = try await client.listResources()
        #expect(resources.isEmpty)
    }

    @Test("listResources paginates with cursor")
    func listResourcesPaginated() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"resources":[{"uri":"a://1","name":"A"}],"nextCursor":"pg2"}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":3,"result":{"resources":[{"uri":"b://2","name":"B"}]}}
        """)

        let resources = try await client.listResources()
        #expect(resources.count == 2)
        #expect(resources[0].uri == "a://1")
        #expect(resources[1].uri == "b://2")
    }

    @Test("listResources sends correct method")
    func listResourcesSendsMethod() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"resources":[]}}
        """)

        _ = try await client.listResources()

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "resources/list")
    }

    // MARK: - List Resource Templates

    @Test("listResourceTemplates returns templates")
    func listResourceTemplatesGoldenPath() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "resourceTemplates": [
                    {"uriTemplate": "file:///users/{id}/profile", "name": "User Profile", "mimeType": "application/json"}
                ]
            }
        }
        """)

        let templates = try await client.listResourceTemplates()
        #expect(templates.count == 1)
        #expect(templates[0].uriTemplate == "file:///users/{id}/profile")
        #expect(templates[0].name == "User Profile")
    }

    @Test("listResourceTemplates returns empty array")
    func listResourceTemplatesEmpty() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"resourceTemplates":[]}}
        """)

        let templates = try await client.listResourceTemplates()
        #expect(templates.isEmpty)
    }

    @Test("listResourceTemplates paginates")
    func listResourceTemplatesPaginated() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"resourceTemplates":[{"uriTemplate":"a:///{x}","name":"A"}],"nextCursor":"pg2"}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":3,"result":{"resourceTemplates":[{"uriTemplate":"b:///{y}","name":"B"}]}}
        """)

        let templates = try await client.listResourceTemplates()
        #expect(templates.count == 2)
    }

    // MARK: - Read Resource

    @Test("readResource returns text contents")
    func readResourceText() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "contents": [
                    {"uri": "file:///readme.md", "mimeType": "text/markdown", "text": "# Hello"}
                ]
            }
        }
        """)

        let contents = try await client.readResource(uri: "file:///readme.md")
        #expect(contents.count == 1)
        if case .text(let uri, let mime, let text) = contents[0] {
            #expect(uri == "file:///readme.md")
            #expect(mime == "text/markdown")
            #expect(text == "# Hello")
        } else {
            Issue.record("Expected text contents")
        }
    }

    @Test("readResource returns blob contents")
    func readResourceBlob() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "contents": [
                    {"uri": "file:///image.png", "mimeType": "image/png", "blob": "iVBOR..."}
                ]
            }
        }
        """)

        let contents = try await client.readResource(uri: "file:///image.png")
        #expect(contents.count == 1)
        if case .blob(_, let mime, let blob) = contents[0] {
            #expect(mime == "image/png")
            #expect(blob == "iVBOR...")
        } else {
            Issue.record("Expected blob contents")
        }
    }

    @Test("readResource returns multiple contents")
    func readResourceMultiple() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "contents": [
                    {"uri": "file:///a.txt", "text": "A"},
                    {"uri": "file:///b.txt", "text": "B"}
                ]
            }
        }
        """)

        let contents = try await client.readResource(uri: "file:///dir")
        #expect(contents.count == 2)
    }

    @Test("readResource sends correct request with uri")
    func readResourceSendsURI() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"contents":[{"uri":"file:///a.txt","text":"x"}]}}
        """)

        _ = try await client.readResource(uri: "file:///a.txt")

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "resources/read")
        if case .object(let params) = request.params {
            #expect(params["uri"] == .string("file:///a.txt"))
        } else {
            Issue.record("Expected params with uri")
        }
    }

    // MARK: - Subscribe / Unsubscribe Resource

    @Test("subscribeResource sends correct request")
    func subscribeResourceSendsRequest() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{}}
        """)

        try await client.subscribeResource(uri: "file:///watched.log")

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "resources/subscribe")
        if case .object(let params) = request.params {
            #expect(params["uri"] == .string("file:///watched.log"))
        } else {
            Issue.record("Expected params with uri")
        }
    }

    @Test("unsubscribeResource sends correct request")
    func unsubscribeResourceSendsRequest() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{}}
        """)

        try await client.unsubscribeResource(uri: "file:///watched.log")

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "resources/unsubscribe")
        if case .object(let params) = request.params {
            #expect(params["uri"] == .string("file:///watched.log"))
        } else {
            Issue.record("Expected params with uri")
        }
    }

    // MARK: - List Prompts

    @Test("listPrompts returns array of prompt definitions")
    func listPromptsGoldenPath() async throws {
        let (client, transport) = try await makeInitializedClient(
            capabilities: "{\"prompts\":{\"listChanged\":true}}"
        )
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "prompts": [
                    {
                        "name": "code_review",
                        "description": "Review code for issues",
                        "arguments": [{"name": "code", "required": true}]
                    },
                    {"name": "summarize"}
                ]
            }
        }
        """)

        let prompts = try await client.listPrompts()
        #expect(prompts.count == 2)
        #expect(prompts[0].name == "code_review")
        #expect(prompts[0].description == "Review code for issues")
        #expect(prompts[0].arguments?.count == 1)
        #expect(prompts[0].arguments?[0].required == true)
        #expect(prompts[1].name == "summarize")
    }

    @Test("listPrompts returns empty array")
    func listPromptsEmpty() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"prompts":[]}}
        """)

        let prompts = try await client.listPrompts()
        #expect(prompts.isEmpty)
    }

    @Test("listPrompts paginates with cursor")
    func listPromptsPaginated() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"prompts":[{"name":"a"}],"nextCursor":"pg2"}}
        """)
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":3,"result":{"prompts":[{"name":"b"}]}}
        """)

        let prompts = try await client.listPrompts()
        #expect(prompts.count == 2)
        #expect(prompts[0].name == "a")
        #expect(prompts[1].name == "b")
    }

    @Test("listPrompts sends correct method")
    func listPromptsSendsMethod() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"prompts":[]}}
        """)

        _ = try await client.listPrompts()

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "prompts/list")
    }

    // MARK: - Get Prompt

    @Test("getPrompt returns messages")
    func getPromptGoldenPath() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "description": "Code review prompt",
                "messages": [
                    {"role": "user", "content": {"type": "text", "text": "Review this code: print('hello')"}},
                    {"role": "assistant", "content": {"type": "text", "text": "I'll review the code."}}
                ]
            }
        }
        """)

        let result = try await client.getPrompt(name: "code_review", arguments: ["code": "print('hello')"])
        #expect(result.description == "Code review prompt")
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[1].role == .assistant)
    }

    @Test("getPrompt sends correct request with arguments")
    func getPromptSendsArguments() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"messages":[{"role":"user","content":{"type":"text","text":"Hi"}}]}}
        """)

        _ = try await client.getPrompt(name: "greet", arguments: ["name": "Alice"])

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "prompts/get")
        if case .object(let params) = request.params {
            #expect(params["name"] == .string("greet"))
            #expect(params["arguments"] == .object(["name": .string("Alice")]))
        } else {
            Issue.record("Expected params object")
        }
    }

    @Test("getPrompt with empty arguments")
    func getPromptEmptyArgs() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"messages":[{"role":"user","content":{"type":"text","text":"Default"}}]}}
        """)

        let result = try await client.getPrompt(name: "default_prompt")
        #expect(result.messages.count == 1)
    }

    @Test("getPrompt with image content")
    func getPromptImageContent() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "messages": [
                    {"role": "user", "content": {"type": "image", "data": "iVBOR...", "mimeType": "image/png"}}
                ]
            }
        }
        """)

        let result = try await client.getPrompt(name: "analyze_image")
        if case .image(let data, let mimeType, _) = result.messages[0].content {
            #expect(data == "iVBOR...")
            #expect(mimeType == "image/png")
        } else {
            Issue.record("Expected image content")
        }
    }

    @Test("getPrompt with embedded resource content")
    func getPromptResourceContent() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0", "id": 2,
            "result": {
                "messages": [
                    {"role": "user", "content": {"type": "resource", "resource": {"uri": "file:///data.csv", "text": "a,b,c"}}}
                ]
            }
        }
        """)

        let result = try await client.getPrompt(name: "analyze_data")
        if case .resource(let contents, _) = result.messages[0].content {
            if case .text(let uri, _, let text) = contents {
                #expect(uri == "file:///data.csv")
                #expect(text == "a,b,c")
            } else {
                Issue.record("Expected text resource")
            }
        } else {
            Issue.record("Expected resource content")
        }
    }

    // MARK: - Set Log Level

    @Test("setLogLevel sends correct request")
    func setLogLevelSendsRequest() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{}}
        """)

        try await client.setLogLevel(.warning)

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "logging/setLevel")
        if case .object(let params) = request.params {
            #expect(params["level"] == .string("warning"))
        } else {
            Issue.record("Expected params with level")
        }
    }

    // MARK: - Cancel Request

    @Test("cancelRequest sends correct notification")
    func cancelRequestSendsNotification() async throws {
        let (client, transport) = try await makeInitializedClient()

        try await client.cancelRequest(id: 5, reason: "User cancelled")

        let sent = await transport.sentMessages()
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: sent.last!)
        #expect(json["method"] == .string("notifications/cancelled"))
        #expect(json["id"] == nil) // Notifications have no id
        if case .object(let params) = json["params"] {
            #expect(params["requestId"] == .integer(5))
            #expect(params["reason"] == .string("User cancelled"))
        } else {
            Issue.record("Expected params")
        }
    }

    @Test("cancelRequest without reason")
    func cancelRequestNoReason() async throws {
        let (client, transport) = try await makeInitializedClient()

        try await client.cancelRequest(id: 3)

        let sent = await transport.sentMessages()
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: sent.last!)
        if case .object(let params) = json["params"] {
            #expect(params["requestId"] == .integer(3))
            #expect(params["reason"] == nil)
        } else {
            Issue.record("Expected params")
        }
    }

    // MARK: - Completion

    @Test("complete with prompt ref sends correct request")
    func completePromptRef() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"completion":{"values":["python","pytorch"],"total":5,"hasMore":true}}}
        """)

        let result = try await client.complete(
            ref: .prompt(name: "code_review"),
            argumentName: "language",
            argumentValue: "py"
        )

        #expect(result.values == ["python", "pytorch"])
        #expect(result.total == 5)
        #expect(result.hasMore == true)

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        #expect(request.method == "completion/complete")
        if case .object(let params) = request.params,
           case .object(let ref) = params["ref"] {
            #expect(ref["type"] == .string("ref/prompt"))
            #expect(ref["name"] == .string("code_review"))
        } else {
            Issue.record("Expected params with ref")
        }
    }

    @Test("complete with resource ref")
    func completeResourceRef() async throws {
        let (client, transport) = try await makeInitializedClient()
        await transport.enqueueResponse("""
        {"jsonrpc":"2.0","id":2,"result":{"completion":{"values":["users","uploads"]}}}
        """)

        let result = try await client.complete(
            ref: .resource(uri: "file:///{path}"),
            argumentName: "path",
            argumentValue: "u"
        )

        #expect(result.values == ["users", "uploads"])

        let sent = await transport.sentMessages()
        let request = try JSONDecoder().decode(JSONRPCRequest.self, from: sent.last!)
        if case .object(let params) = request.params,
           case .object(let ref) = params["ref"] {
            #expect(ref["type"] == .string("ref/resource"))
            #expect(ref["uri"] == .string("file:///{path}"))
        } else {
            Issue.record("Expected params with ref")
        }
    }

    // MARK: - Disconnect

    @Test("disconnect stops dispatcher and disconnects transport")
    func disconnectCleansUp() async throws {
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

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        #expect(await transport.state.isConnected())

        try await client.disconnect()
        #expect(await !transport.state.isConnected())
    }

    @Test("disconnect can be called before initialize without error")
    func disconnectBeforeInitialize() async throws {
        let transport = MockTransport()
        let client = MCPClientConnection(transport: transport)
        try await client.disconnect()
        // Should not throw
    }

    // MARK: - Request Timeouts

    @Test("Request times out when server does not respond")
    func requestTimeout() async throws {
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
        // No response enqueued for the ping — it will hang

        let client = MCPClientConnection(transport: transport, requestTimeout: .milliseconds(50))
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        await #expect(throws: MCPError.self) {
            _ = try await client.ping()
        }
    }

    @Test("Methods throw after disconnect")
    func methodsThrowAfterDisconnect() async throws {
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

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")
        try await client.disconnect()

        await #expect(throws: Error.self) {
            _ = try await client.ping()
        }
    }

    // MARK: - Roots

    @Test("notifyRootsChanged sends correct notification")
    func notifyRootsChangedSendsNotification() async throws {
        let (client, transport) = try await makeInitializedClient()

        try await client.notifyRootsChanged()

        let sent = await transport.sentMessages()
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: sent.last!)
        #expect(json["method"] == .string("notifications/roots/list_changed"))
        #expect(json["id"] == nil)
    }

    // MARK: - Sampling

    @Test("setSamplingHandler routes sampling/createMessage to handler")
    func samplingHandler() async throws {
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
        // Enqueue a sampling/createMessage incoming request
        await transport.enqueueResponse("""
        {
            "jsonrpc": "2.0",
            "id": 99,
            "method": "sampling/createMessage",
            "params": {
                "messages": [{"role": "user", "content": {"type": "text", "text": "What is 2+2?"}}],
                "maxTokens": 50
            }
        }
        """)

        let client = MCPClientConnection(transport: transport)
        _ = try await client.initialize(clientName: "test", clientVersion: "0.1")

        await client.setSamplingHandler { request in
            #expect(request.maxTokens == 50)
            #expect(request.messages.count == 1)
            return MCPSamplingResult(
                role: .assistant,
                content: .text("4"),
                model: "test-model",
                stopReason: "endTurn"
            )
        }

        // Poll for the response — Linux CI can be slower than 100ms
        var responseSent: [String: AnyCodableValue]?
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            let sent = await transport.sentMessages()
            responseSent = sent.compactMap { data -> [String: AnyCodableValue]? in
                try? JSONDecoder().decode([String: AnyCodableValue].self, from: data)
            }.first { obj in
                if case .integer(99) = obj["id"] { return true }
                return false
            }
            if responseSent != nil { break }
        }
        #expect(responseSent != nil)
    }

    // MARK: - Notifications Stream

    @Test("notifications property returns stream")
    func notificationsStream() async throws {
        let (client, _) = try await makeInitializedClient()
        // Just verify we can access the stream without error
        let stream = await client.notifications
        _ = stream
    }
}
