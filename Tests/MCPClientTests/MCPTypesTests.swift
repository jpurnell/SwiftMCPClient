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
        let content = MCPContent(type: "text", text: "Score: 75/100")
        let result = MCPToolResult(content: [content])
        #expect(result.content.count == 1)
        #expect(result.content[0].text == "Score: 75/100")
        #expect(result.isError == nil)
    }

    @Test("MCPToolResult with isError flag")
    func toolResultError() {
        let content = MCPContent(type: "text", text: "Tool execution failed")
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
        #expect(result.content[0].type == "text")
        #expect(result.content[0].text == "Technical SEO Score: 74.8 / 100")
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

    // MARK: - MCPContent

    @Test("MCPContent with text type")
    func contentText() {
        let content = MCPContent(type: "text", text: "hello")
        #expect(content.type == "text")
        #expect(content.text == "hello")
        #expect(content.mimeType == nil)
    }

    @Test("MCPContent with mimeType")
    func contentWithMime() {
        let content = MCPContent(type: "resource", text: nil, mimeType: "application/json")
        #expect(content.type == "resource")
        #expect(content.text == nil)
        #expect(content.mimeType == "application/json")
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
