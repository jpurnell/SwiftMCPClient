import Testing
import Foundation
@testable import MCPClient

@Suite("MCPSamplingTypes")
struct MCPSamplingTypesTests {

    // MARK: - MCPSamplingRequest

    @Test("SamplingRequest initializes with required fields")
    func requestInit() {
        let msg = MCPSamplingMessage(role: .user, content: .text("Hello"))
        let request = MCPSamplingRequest(messages: [msg], maxTokens: 100)
        #expect(request.messages.count == 1)
        #expect(request.maxTokens == 100)
        #expect(request.systemPrompt == nil)
        #expect(request.temperature == nil)
    }

    @Test("SamplingRequest initializes with all fields")
    func requestInitFull() {
        let msg = MCPSamplingMessage(role: .user, content: .text("Hello"))
        let prefs = MCPModelPreferences(
            hints: [MCPModelHint(name: "claude")],
            costPriority: 0.3,
            speedPriority: 0.5,
            intelligencePriority: 0.9
        )
        let request = MCPSamplingRequest(
            messages: [msg],
            modelPreferences: prefs,
            systemPrompt: "Be helpful",
            includeContext: "thisServer",
            temperature: 0.7,
            maxTokens: 500,
            stopSequences: ["END"],
            metadata: .object(["key": .string("value")])
        )
        #expect(request.systemPrompt == "Be helpful")
        #expect(request.includeContext == "thisServer")
        #expect(request.temperature == 0.7)
        #expect(request.stopSequences == ["END"])
        #expect(request.modelPreferences?.hints?.first?.name == "claude")
        #expect(request.modelPreferences?.intelligencePriority == 0.9)
    }

    @Test("SamplingRequest decodes from JSON")
    func requestDecodes() throws {
        let json = """
        {
            "messages": [
                {"role": "user", "content": {"type": "text", "text": "What is 2+2?"}}
            ],
            "maxTokens": 50,
            "systemPrompt": "Be concise"
        }
        """
        let data = json.data(using: .utf8)!
        let request = try JSONDecoder().decode(MCPSamplingRequest.self, from: data)
        #expect(request.messages.count == 1)
        #expect(request.maxTokens == 50)
        #expect(request.systemPrompt == "Be concise")
    }

    @Test("SamplingRequest round-trips through JSON")
    func requestRoundTrip() throws {
        let msg = MCPSamplingMessage(role: .user, content: .text("Test"))
        let original = MCPSamplingRequest(messages: [msg], maxTokens: 100)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPSamplingRequest.self, from: data)
        #expect(decoded.maxTokens == 100)
        #expect(decoded.messages.count == 1)
    }

    // MARK: - MCPSamplingMessage

    @Test("SamplingMessage initializes correctly")
    func messageInit() {
        let msg = MCPSamplingMessage(role: .assistant, content: .text("Hi"))
        #expect(msg.role == .assistant)
        if case .text(let str, _) = msg.content {
            #expect(str == "Hi")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("SamplingMessage is equatable")
    func messageEquatable() {
        let a = MCPSamplingMessage(role: .user, content: .text("X"))
        let b = MCPSamplingMessage(role: .user, content: .text("X"))
        let c = MCPSamplingMessage(role: .assistant, content: .text("X"))
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MCPModelPreferences

    @Test("ModelPreferences defaults to nil fields")
    func prefsDefault() {
        let prefs = MCPModelPreferences()
        #expect(prefs.hints == nil)
        #expect(prefs.costPriority == nil)
    }

    @Test("ModelPreferences decodes from JSON")
    func prefsDecodes() throws {
        let json = """
        {
            "hints": [{"name": "gpt-4"}, {"name": "claude"}],
            "costPriority": 0.2,
            "speedPriority": 0.8,
            "intelligencePriority": 0.5
        }
        """
        let data = json.data(using: .utf8)!
        let prefs = try JSONDecoder().decode(MCPModelPreferences.self, from: data)
        #expect(prefs.hints?.count == 2)
        #expect(prefs.hints?[1].name == "claude")
        #expect(prefs.costPriority == 0.2)
    }

    // MARK: - MCPSamplingResult

    @Test("SamplingResult initializes correctly")
    func resultInit() {
        let result = MCPSamplingResult(
            role: .assistant,
            content: .text("The answer is 4"),
            model: "claude-opus-4-6",
            stopReason: "endTurn"
        )
        #expect(result.role == .assistant)
        #expect(result.model == "claude-opus-4-6")
        #expect(result.stopReason == "endTurn")
    }

    @Test("SamplingResult encodes to JSON")
    func resultEncodes() throws {
        let result = MCPSamplingResult(
            role: .assistant,
            content: .text("Hello"),
            model: "test-model"
        )
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(MCPSamplingResult.self, from: data)
        #expect(decoded.model == "test-model")
        #expect(decoded.stopReason == nil)
    }

    @Test("SamplingResult round-trips through JSON")
    func resultRoundTrip() throws {
        let original = MCPSamplingResult(
            role: .assistant,
            content: .text("Test output"),
            model: "claude-3",
            stopReason: "maxTokens"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPSamplingResult.self, from: data)
        #expect(decoded.role == original.role)
        #expect(decoded.model == original.model)
        #expect(decoded.stopReason == original.stopReason)
    }
}
