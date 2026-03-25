import Testing
import Foundation
@testable import MCPClient

@Suite("MCPResourceTypes")
struct MCPResourceTypesTests {

    // MARK: - MCPAnnotations

    @Test("Annotations with audience and priority")
    func annotationsAllFields() {
        let annotations = MCPAnnotations(audience: [.user, .assistant], priority: 0.8)
        #expect(annotations.audience == [.user, .assistant])
        #expect(annotations.priority == 0.8)
    }

    @Test("Annotations with nil fields")
    func annotationsNil() {
        let annotations = MCPAnnotations()
        #expect(annotations.audience == nil)
        #expect(annotations.priority == nil)
    }

    @Test("Annotations decodes from JSON")
    func annotationsDecodes() throws {
        let json = """
        {"audience": ["user"], "priority": 0.5}
        """
        let data = json.data(using: .utf8)!
        let annotations = try JSONDecoder().decode(MCPAnnotations.self, from: data)
        #expect(annotations.audience == [.user])
        #expect(annotations.priority == 0.5)
    }

    @Test("Annotations round-trips through JSON")
    func annotationsRoundTrip() throws {
        let original = MCPAnnotations(audience: [.assistant], priority: 1.0)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPAnnotations.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - MCPResource

    @Test("Resource initializes with required fields only")
    func resourceRequired() {
        let resource = MCPResource(uri: "file:///data.txt", name: "data")
        #expect(resource.uri == "file:///data.txt")
        #expect(resource.name == "data")
        #expect(resource.description == nil)
        #expect(resource.mimeType == nil)
        #expect(resource.size == nil)
        #expect(resource.annotations == nil)
    }

    @Test("Resource initializes with all fields")
    func resourceAllFields() {
        let annotations = MCPAnnotations(audience: [.user], priority: 0.9)
        let resource = MCPResource(
            uri: "file:///report.pdf",
            name: "Report",
            description: "Q4 financial report",
            mimeType: "application/pdf",
            size: 1024,
            annotations: annotations
        )
        #expect(resource.uri == "file:///report.pdf")
        #expect(resource.name == "Report")
        #expect(resource.description == "Q4 financial report")
        #expect(resource.mimeType == "application/pdf")
        #expect(resource.size == 1024)
        #expect(resource.annotations?.priority == 0.9)
    }

    @Test("Resource decodes from JSON")
    func resourceDecodes() throws {
        let json = """
        {
            "uri": "file:///logs/app.log",
            "name": "Application Logs",
            "description": "Recent application log output",
            "mimeType": "text/plain",
            "size": 4096
        }
        """
        let data = json.data(using: .utf8)!
        let resource = try JSONDecoder().decode(MCPResource.self, from: data)
        #expect(resource.uri == "file:///logs/app.log")
        #expect(resource.name == "Application Logs")
        #expect(resource.mimeType == "text/plain")
        #expect(resource.size == 4096)
    }

    @Test("Resource decodes with annotations")
    func resourceDecodesAnnotations() throws {
        let json = """
        {
            "uri": "file:///data.csv",
            "name": "Data",
            "annotations": {"audience": ["user", "assistant"], "priority": 0.7}
        }
        """
        let data = json.data(using: .utf8)!
        let resource = try JSONDecoder().decode(MCPResource.self, from: data)
        #expect(resource.annotations?.audience == [.user, .assistant])
        #expect(resource.annotations?.priority == 0.7)
    }

    @Test("Resource is equatable")
    func resourceEquatable() {
        let a = MCPResource(uri: "file:///a.txt", name: "A")
        let b = MCPResource(uri: "file:///a.txt", name: "A")
        let c = MCPResource(uri: "file:///b.txt", name: "B")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Resource round-trips through JSON")
    func resourceRoundTrip() throws {
        let original = MCPResource(
            uri: "file:///test.json",
            name: "Test",
            description: "A test resource",
            mimeType: "application/json",
            size: 512,
            annotations: MCPAnnotations(audience: [.user], priority: 0.5)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPResource.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - MCPResourceTemplate

    @Test("ResourceTemplate initializes with required fields only")
    func templateRequired() {
        let template = MCPResourceTemplate(uriTemplate: "file:///logs/{name}.log", name: "Log File")
        #expect(template.uriTemplate == "file:///logs/{name}.log")
        #expect(template.name == "Log File")
        #expect(template.description == nil)
        #expect(template.mimeType == nil)
        #expect(template.annotations == nil)
    }

    @Test("ResourceTemplate initializes with all fields")
    func templateAllFields() {
        let template = MCPResourceTemplate(
            uriTemplate: "db:///{table}/schema",
            name: "Table Schema",
            description: "Database table schema",
            mimeType: "application/json",
            annotations: MCPAnnotations(priority: 0.3)
        )
        #expect(template.uriTemplate == "db:///{table}/schema")
        #expect(template.description == "Database table schema")
        #expect(template.annotations?.priority == 0.3)
    }

    @Test("ResourceTemplate decodes from JSON")
    func templateDecodes() throws {
        let json = """
        {
            "uriTemplate": "file:///users/{userId}/profile",
            "name": "User Profile",
            "description": "Profile for a specific user",
            "mimeType": "application/json"
        }
        """
        let data = json.data(using: .utf8)!
        let template = try JSONDecoder().decode(MCPResourceTemplate.self, from: data)
        #expect(template.uriTemplate == "file:///users/{userId}/profile")
        #expect(template.name == "User Profile")
    }

    @Test("ResourceTemplate is equatable")
    func templateEquatable() {
        let a = MCPResourceTemplate(uriTemplate: "a:///{x}", name: "A")
        let b = MCPResourceTemplate(uriTemplate: "a:///{x}", name: "A")
        let c = MCPResourceTemplate(uriTemplate: "b:///{y}", name: "B")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MCPResourceContents

    @Test("ResourceContents text variant")
    func contentsText() {
        let contents = MCPResourceContents.text(uri: "file:///a.txt", mimeType: "text/plain", text: "hello")
        if case .text(let uri, let mime, let text) = contents {
            #expect(uri == "file:///a.txt")
            #expect(mime == "text/plain")
            #expect(text == "hello")
        } else {
            Issue.record("Expected text variant")
        }
    }

    @Test("ResourceContents blob variant")
    func contentsBlob() {
        let contents = MCPResourceContents.blob(uri: "file:///img.png", mimeType: "image/png", blob: "iVBOR...")
        if case .blob(let uri, let mime, let blob) = contents {
            #expect(uri == "file:///img.png")
            #expect(mime == "image/png")
            #expect(blob == "iVBOR...")
        } else {
            Issue.record("Expected blob variant")
        }
    }

    @Test("ResourceContents text decodes from JSON")
    func contentsTextDecodes() throws {
        let json = """
        {"uri": "file:///readme.md", "mimeType": "text/markdown", "text": "# Hello"}
        """
        let data = json.data(using: .utf8)!
        let contents = try JSONDecoder().decode(MCPResourceContents.self, from: data)
        if case .text(let uri, let mime, let text) = contents {
            #expect(uri == "file:///readme.md")
            #expect(mime == "text/markdown")
            #expect(text == "# Hello")
        } else {
            Issue.record("Expected text variant")
        }
    }

    @Test("ResourceContents blob decodes from JSON")
    func contentsBlobDecodes() throws {
        let json = """
        {"uri": "file:///image.png", "mimeType": "image/png", "blob": "aGVsbG8="}
        """
        let data = json.data(using: .utf8)!
        let contents = try JSONDecoder().decode(MCPResourceContents.self, from: data)
        if case .blob(let uri, let mime, let blob) = contents {
            #expect(uri == "file:///image.png")
            #expect(mime == "image/png")
            #expect(blob == "aGVsbG8=")
        } else {
            Issue.record("Expected blob variant")
        }
    }

    @Test("ResourceContents text without mimeType")
    func contentsTextNoMime() throws {
        let json = """
        {"uri": "file:///data.txt", "text": "content"}
        """
        let data = json.data(using: .utf8)!
        let contents = try JSONDecoder().decode(MCPResourceContents.self, from: data)
        if case .text(_, let mime, _) = contents {
            #expect(mime == nil)
        } else {
            Issue.record("Expected text variant")
        }
    }

    @Test("ResourceContents text round-trips through JSON")
    func contentsTextRoundTrip() throws {
        let original = MCPResourceContents.text(uri: "file:///a.txt", mimeType: "text/plain", text: "data")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPResourceContents.self, from: data)
        #expect(decoded == original)
    }

    @Test("ResourceContents blob round-trips through JSON")
    func contentsBlobRoundTrip() throws {
        let original = MCPResourceContents.blob(uri: "file:///b.bin", mimeType: "application/octet-stream", blob: "AQID")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPResourceContents.self, from: data)
        #expect(decoded == original)
    }

    @Test("ResourceContents is equatable")
    func contentsEquatable() {
        let a = MCPResourceContents.text(uri: "file:///a", mimeType: nil, text: "x")
        let b = MCPResourceContents.text(uri: "file:///a", mimeType: nil, text: "x")
        let c = MCPResourceContents.blob(uri: "file:///a", mimeType: nil, blob: "x")
        #expect(a == b)
        #expect(a != c)
    }
}
