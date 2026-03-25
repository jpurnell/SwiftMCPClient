import Testing
import Foundation
@testable import MCPClient

@Suite("MCPTypes")
struct MCPTypesTests {

    // MARK: - MCPTool

    @Test("MCPTool initializes with name only")
    func toolNameOnly() {
        let tool = MCPTool(name: "score_technical_seo")
        #expect(tool.name == "score_technical_seo")
        #expect(tool.description == nil)
        #expect(tool.inputSchema == nil)
    }

    @Test("MCPTool initializes with all fields")
    func toolAllFields() {
        let schema = AnyCodableValue.object(["type": .string("object")])
        let tool = MCPTool(name: "calculate_npv", description: "Calculate NPV", inputSchema: schema)
        #expect(tool.name == "calculate_npv")
        #expect(tool.description == "Calculate NPV")
        #expect(tool.inputSchema == schema)
    }

    @Test("MCPTool decodes from JSON")
    func toolDecodes() throws {
        let json = """
        {
            "name": "audit_meta_tags",
            "description": "Audit essential meta tags for SEO compliance.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"}
                },
                "required": ["title"]
            }
        }
        """
        let data = json.data(using: .utf8)!
        let tool = try JSONDecoder().decode(MCPTool.self, from: data)
        #expect(tool.name == "audit_meta_tags")
        #expect(tool.description == "Audit essential meta tags for SEO compliance.")
        #expect(tool.inputSchema != nil)
    }

    @Test("MCPTool is equatable")
    func toolEquatable() {
        let a = MCPTool(name: "test")
        let b = MCPTool(name: "test")
        let c = MCPTool(name: "other")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MCPToolResult

    @Test("MCPToolResult with text content")
    func toolResultText() {
        let content = MCPContent.text("Score: 75/100")
        let result = MCPToolResult(content: [content])
        #expect(result.content.count == 1)
        if case .text(let str, _) = result.content[0] {
            #expect(str == "Score: 75/100")
        } else {
            Issue.record("Expected text content")
        }
        #expect(result.isError == nil)
    }

    @Test("MCPToolResult with isError flag")
    func toolResultError() {
        let content = MCPContent.text("Tool execution failed")
        let result = MCPToolResult(content: [content], isError: true)
        #expect(result.isError == true)
    }

    @Test("MCPToolResult decodes from JSON")
    func toolResultDecodes() throws {
        let json = """
        {
            "content": [
                {"type": "text", "text": "Technical SEO Score: 74.8 / 100"}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPToolResult.self, from: data)
        #expect(result.content.count == 1)
        if case .text(let str, _) = result.content[0] {
            #expect(str == "Technical SEO Score: 74.8 / 100")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("MCPToolResult with multiple content blocks")
    func toolResultMultipleContent() throws {
        let json = """
        {
            "content": [
                {"type": "text", "text": "Part 1"},
                {"type": "text", "text": "Part 2"}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPToolResult.self, from: data)
        #expect(result.content.count == 2)
    }

    @Test("MCPToolResult decodes mixed content types from JSON")
    func toolResultMixedContent() throws {
        let json = """
        {
            "content": [
                {"type": "text", "text": "Analysis complete"},
                {"type": "image", "data": "iVBOR...", "mimeType": "image/png"}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPToolResult.self, from: data)
        #expect(result.content.count == 2)
        if case .text(let str, _) = result.content[0] {
            #expect(str == "Analysis complete")
        } else {
            Issue.record("Expected text content")
        }
        if case .image(let imgData, let mime, _) = result.content[1] {
            #expect(imgData == "iVBOR...")
            #expect(mime == "image/png")
        } else {
            Issue.record("Expected image content")
        }
    }

    // MARK: - MCPContent (discriminated union)

    @Test("MCPContent text case initializes")
    func contentText() {
        let content = MCPContent.text("hello")
        if case .text(let str, let annotations) = content {
            #expect(str == "hello")
            #expect(annotations == nil)
        } else {
            Issue.record("Expected text case")
        }
    }

    @Test("MCPContent text with annotations")
    func contentTextAnnotated() {
        let annotations = MCPAnnotations(audience: [.user], priority: 0.8)
        let content = MCPContent.text("hello", annotations: annotations)
        if case .text(let str, let ann) = content {
            #expect(str == "hello")
            #expect(ann?.priority == 0.8)
            #expect(ann?.audience == [.user])
        } else {
            Issue.record("Expected text case")
        }
    }

    @Test("MCPContent image case initializes")
    func contentImage() {
        let content = MCPContent.image(data: "base64data", mimeType: "image/png")
        if case .image(let data, let mimeType, let annotations) = content {
            #expect(data == "base64data")
            #expect(mimeType == "image/png")
            #expect(annotations == nil)
        } else {
            Issue.record("Expected image case")
        }
    }

    @Test("MCPContent resource case initializes")
    func contentResource() {
        let resource = MCPResourceContents.text(uri: "file:///a", mimeType: nil, text: "data")
        let content = MCPContent.resource(resource)
        if case .resource(let res, let annotations) = content {
            #expect(annotations == nil)
            if case .text(let uri, _, let text) = res {
                #expect(uri == "file:///a")
                #expect(text == "data")
            } else {
                Issue.record("Expected text resource")
            }
        } else {
            Issue.record("Expected resource case")
        }
    }

    @Test("MCPContent decodes text from JSON")
    func contentDecodesText() throws {
        let json = """
        {"type": "text", "text": "Score: 74.8"}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPContent.self, from: data)
        if case .text(let str, _) = content {
            #expect(str == "Score: 74.8")
        } else {
            Issue.record("Expected text case")
        }
    }

    @Test("MCPContent decodes image from JSON")
    func contentDecodesImage() throws {
        let json = """
        {"type": "image", "data": "iVBOR...", "mimeType": "image/png"}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPContent.self, from: data)
        if case .image(let imgData, let mime, _) = content {
            #expect(imgData == "iVBOR...")
            #expect(mime == "image/png")
        } else {
            Issue.record("Expected image case")
        }
    }

    @Test("MCPContent decodes resource from JSON")
    func contentDecodesResource() throws {
        let json = """
        {"type": "resource", "resource": {"uri": "file:///a.txt", "text": "contents"}}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPContent.self, from: data)
        if case .resource(let res, _) = content {
            if case .text(let uri, _, let text) = res {
                #expect(uri == "file:///a.txt")
                #expect(text == "contents")
            } else {
                Issue.record("Expected text resource")
            }
        } else {
            Issue.record("Expected resource case")
        }
    }

    @Test("MCPContent decodes text with annotations from JSON")
    func contentDecodesTextAnnotated() throws {
        let json = """
        {"type": "text", "text": "hello", "annotations": {"audience": ["user"], "priority": 0.5}}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPContent.self, from: data)
        if case .text(let str, let ann) = content {
            #expect(str == "hello")
            #expect(ann?.audience == [.user])
            #expect(ann?.priority == 0.5)
        } else {
            Issue.record("Expected text case")
        }
    }

    @Test("MCPContent round-trips through JSON")
    func contentRoundTrip() throws {
        let original = MCPContent.text("round-trip test", annotations: MCPAnnotations(audience: [.assistant], priority: 0.3))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPContent.self, from: data)
        #expect(decoded == original)
    }

    @Test("MCPContent image round-trips through JSON")
    func contentImageRoundTrip() throws {
        let original = MCPContent.image(data: "abc123", mimeType: "image/jpeg")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPContent.self, from: data)
        #expect(decoded == original)
    }

    @Test("MCPContent is equatable")
    func contentEquatable() {
        let a = MCPContent.text("hello")
        let b = MCPContent.text("hello")
        let c = MCPContent.text("world")
        let d = MCPContent.image(data: "x", mimeType: "image/png")
        #expect(a == b)
        #expect(a != c)
        #expect(a != d)
    }

    @Test("MCPContent unknown type throws DecodingError")
    func contentUnknownType() throws {
        let json = """
        {"type": "video", "data": "abc"}
        """
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(MCPContent.self, from: data)
        }
    }

    // MARK: - ServerCapabilities

    @Test("ServerCapabilities with tools")
    func capabilitiesWithTools() {
        let caps = ServerCapabilities(tools: ToolsCapability(listChanged: true))
        #expect(caps.tools?.listChanged == true)
    }

    @Test("ServerCapabilities without tools")
    func capabilitiesWithoutTools() {
        let caps = ServerCapabilities()
        #expect(caps.tools == nil)
    }

    @Test("ServerCapabilities decodes from JSON")
    func capabilitiesDecodes() throws {
        let json = """
        {"tools": {"listChanged": false}}
        """
        let data = json.data(using: .utf8)!
        let caps = try JSONDecoder().decode(ServerCapabilities.self, from: data)
        #expect(caps.tools?.listChanged == false)
        #expect(caps.resources == nil)
        #expect(caps.prompts == nil)
    }

    @Test("ServerCapabilities with resources")
    func capabilitiesWithResources() {
        let caps = ServerCapabilities(resources: ResourcesCapability(subscribe: true, listChanged: true))
        #expect(caps.resources?.subscribe == true)
        #expect(caps.resources?.listChanged == true)
    }

    @Test("ServerCapabilities with prompts")
    func capabilitiesWithPrompts() {
        let caps = ServerCapabilities(prompts: PromptsCapability(listChanged: true))
        #expect(caps.prompts?.listChanged == true)
    }

    @Test("ServerCapabilities decodes all capabilities from JSON")
    func capabilitiesDecodesAll() throws {
        let json = """
        {
            "tools": {"listChanged": true},
            "resources": {"subscribe": true, "listChanged": false},
            "prompts": {"listChanged": true}
        }
        """
        let data = json.data(using: .utf8)!
        let caps = try JSONDecoder().decode(ServerCapabilities.self, from: data)
        #expect(caps.tools?.listChanged == true)
        #expect(caps.resources?.subscribe == true)
        #expect(caps.resources?.listChanged == false)
        #expect(caps.prompts?.listChanged == true)
    }

    @Test("ResourcesCapability with subscribe only")
    func resourcesCapabilitySubscribe() {
        let cap = ResourcesCapability(subscribe: true)
        #expect(cap.subscribe == true)
        #expect(cap.listChanged == nil)
    }

    @Test("PromptsCapability with no options")
    func promptsCapabilityEmpty() {
        let cap = PromptsCapability()
        #expect(cap.listChanged == nil)
    }

    // MARK: - ClientCapabilities

    @Test("ClientCapabilities defaults to empty")
    func clientCapabilitiesDefault() {
        let caps = ClientCapabilities()
        #expect(caps.roots == nil)
        #expect(caps.sampling == nil)
    }

    @Test("ClientCapabilities with roots")
    func clientCapabilitiesRoots() {
        let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
        #expect(caps.roots?.listChanged == true)
    }

    @Test("ClientCapabilities encodes to JSON")
    func clientCapabilitiesEncodes() throws {
        let caps = ClientCapabilities(roots: RootsCapability(listChanged: true))
        let data = try JSONEncoder().encode(caps)
        let decoded = try JSONDecoder().decode(ClientCapabilities.self, from: data)
        #expect(decoded.roots?.listChanged == true)
    }

    @Test("ClientCapabilities empty encodes to empty object")
    func clientCapabilitiesEmptyEncodes() throws {
        let caps = ClientCapabilities()
        let data = try JSONEncoder().encode(caps)
        let json = String(data: data, encoding: .utf8)!
        #expect(json == "{}")
    }

    // MARK: - ServerCapabilities logging

    @Test("ServerCapabilities with logging")
    func capabilitiesWithLogging() {
        let caps = ServerCapabilities(logging: LoggingCapability())
        #expect(caps.logging != nil)
    }

    @Test("ServerCapabilities decodes logging from JSON")
    func capabilitiesDecodesLogging() throws {
        let json = """
        {
            "tools": {"listChanged": true},
            "logging": {}
        }
        """
        let data = json.data(using: .utf8)!
        let caps = try JSONDecoder().decode(ServerCapabilities.self, from: data)
        #expect(caps.tools?.listChanged == true)
        #expect(caps.logging != nil)
    }

    // MARK: - InitializeResult

    @Test("InitializeResult decodes from full MCP response")
    func initializeResultDecodes() throws {
        let json = """
        {
            "protocolVersion": "2024-11-05",
            "capabilities": {
                "tools": {"listChanged": true}
            },
            "serverInfo": {
                "name": "geoseo-mcp",
                "version": "1.0.0"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(InitializeResult.self, from: data)
        #expect(result.protocolVersion == "2024-11-05")
        #expect(result.capabilities.tools?.listChanged == true)
        #expect(result.serverInfo.name == "geoseo-mcp")
        #expect(result.serverInfo.version == "1.0.0")
    }

    // MARK: - Edge Cases

    @Test("MCPTool with empty name")
    func toolEmptyName() {
        let tool = MCPTool(name: "")
        #expect(tool.name == "")
    }

    @Test("MCPToolResult with empty content array")
    func toolResultEmptyContent() {
        let result = MCPToolResult(content: [])
        #expect(result.content.isEmpty)
    }
}
