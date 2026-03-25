import Testing
import Foundation
@testable import MCPClient

@Suite("MCPRootTypes")
struct MCPRootTypesTests {

    @Test("Root initializes with URI only")
    func rootURIOnly() {
        let root = MCPRoot(uri: "file:///project")
        #expect(root.uri == "file:///project")
        #expect(root.name == nil)
    }

    @Test("Root initializes with all fields")
    func rootAllFields() {
        let root = MCPRoot(uri: "file:///home/user/repos/backend", name: "Backend")
        #expect(root.uri == "file:///home/user/repos/backend")
        #expect(root.name == "Backend")
    }

    @Test("Root decodes from JSON")
    func rootDecodes() throws {
        let json = """
        {"uri": "file:///project", "name": "My Project"}
        """
        let data = json.data(using: .utf8)!
        let root = try JSONDecoder().decode(MCPRoot.self, from: data)
        #expect(root.uri == "file:///project")
        #expect(root.name == "My Project")
    }

    @Test("Root is equatable")
    func rootEquatable() {
        let a = MCPRoot(uri: "file:///a", name: "A")
        let b = MCPRoot(uri: "file:///a", name: "A")
        let c = MCPRoot(uri: "file:///b")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Root round-trips through JSON")
    func rootRoundTrip() throws {
        let original = MCPRoot(uri: "file:///test", name: "Test")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPRoot.self, from: data)
        #expect(decoded == original)
    }
}
