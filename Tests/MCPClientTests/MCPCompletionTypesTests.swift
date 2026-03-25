import Testing
import Foundation
@testable import MCPClient

@Suite("MCPCompletionTypes")
struct MCPCompletionTypesTests {

    @Test("CompletionRef prompt case")
    func refPrompt() {
        let ref = MCPCompletionRef.prompt(name: "code_review")
        if case .prompt(let name) = ref {
            #expect(name == "code_review")
        } else {
            Issue.record("Expected prompt ref")
        }
    }

    @Test("CompletionRef resource case")
    func refResource() {
        let ref = MCPCompletionRef.resource(uri: "file:///data")
        if case .resource(let uri) = ref {
            #expect(uri == "file:///data")
        } else {
            Issue.record("Expected resource ref")
        }
    }

    @Test("CompletionRef is equatable")
    func refEquatable() {
        #expect(MCPCompletionRef.prompt(name: "a") == MCPCompletionRef.prompt(name: "a"))
        #expect(MCPCompletionRef.prompt(name: "a") != MCPCompletionRef.resource(uri: "a"))
    }

    @Test("CompletionResult decodes from JSON")
    func resultDecodes() throws {
        let json = """
        {"values": ["python", "pytorch", "pyside"], "total": 10, "hasMore": true}
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPCompletionResult.self, from: data)
        #expect(result.values == ["python", "pytorch", "pyside"])
        #expect(result.total == 10)
        #expect(result.hasMore == true)
    }

    @Test("CompletionResult with minimal fields")
    func resultMinimal() throws {
        let json = """
        {"values": []}
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPCompletionResult.self, from: data)
        #expect(result.values.isEmpty)
        #expect(result.total == nil)
        #expect(result.hasMore == nil)
    }

    @Test("CompletionResult round-trips through JSON")
    func resultRoundTrip() throws {
        let original = MCPCompletionResult(values: ["a", "b"], total: 5, hasMore: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPCompletionResult.self, from: data)
        #expect(decoded.values == original.values)
        #expect(decoded.total == original.total)
        #expect(decoded.hasMore == original.hasMore)
    }
}
