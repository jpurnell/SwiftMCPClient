import Testing
import Foundation
@testable import MCPClient

@Suite("MCPPromptTypes")
struct MCPPromptTypesTests {

    // MARK: - MCPPrompt

    @Test("Prompt initializes with name only")
    func promptNameOnly() {
        let prompt = MCPPrompt(name: "summarize")
        #expect(prompt.name == "summarize")
        #expect(prompt.description == nil)
        #expect(prompt.arguments == nil)
    }

    @Test("Prompt initializes with all fields")
    func promptAllFields() {
        let args = [
            MCPPromptArgument(name: "text", description: "Text to summarize", required: true),
            MCPPromptArgument(name: "style", description: "Summary style", required: false)
        ]
        let prompt = MCPPrompt(name: "summarize", description: "Summarize text", arguments: args)
        #expect(prompt.name == "summarize")
        #expect(prompt.description == "Summarize text")
        #expect(prompt.arguments?.count == 2)
        #expect(prompt.arguments?[0].required == true)
        #expect(prompt.arguments?[1].required == false)
    }

    @Test("Prompt decodes from JSON")
    func promptDecodes() throws {
        let json = """
        {
            "name": "code_review",
            "description": "Review code for issues",
            "arguments": [
                {"name": "code", "description": "Code to review", "required": true},
                {"name": "language", "description": "Programming language"}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let prompt = try JSONDecoder().decode(MCPPrompt.self, from: data)
        #expect(prompt.name == "code_review")
        #expect(prompt.arguments?.count == 2)
        #expect(prompt.arguments?[0].required == true)
        #expect(prompt.arguments?[1].required == nil)
    }

    @Test("Prompt is equatable")
    func promptEquatable() {
        let a = MCPPrompt(name: "test")
        let b = MCPPrompt(name: "test")
        let c = MCPPrompt(name: "other")
        #expect(a == b)
        #expect(a != c)
    }

    @Test("Prompt round-trips through JSON")
    func promptRoundTrip() throws {
        let original = MCPPrompt(
            name: "analyze",
            description: "Analyze data",
            arguments: [MCPPromptArgument(name: "input", description: "Data", required: true)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPPrompt.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - MCPPromptArgument

    @Test("PromptArgument with name only")
    func argumentNameOnly() {
        let arg = MCPPromptArgument(name: "query")
        #expect(arg.name == "query")
        #expect(arg.description == nil)
        #expect(arg.required == nil)
    }

    @Test("PromptArgument is equatable")
    func argumentEquatable() {
        let a = MCPPromptArgument(name: "x", description: "X", required: true)
        let b = MCPPromptArgument(name: "x", description: "X", required: true)
        #expect(a == b)
    }

    // MARK: - MCPPromptContent

    @Test("PromptContent text variant")
    func contentText() {
        let content = MCPPromptContent.text("Hello world")
        if case .text(let text, let annotations) = content {
            #expect(text == "Hello world")
            #expect(annotations == nil)
        } else {
            Issue.record("Expected text variant")
        }
    }

    @Test("PromptContent text with annotations")
    func contentTextAnnotations() {
        let ann = MCPAnnotations(audience: [.user], priority: 0.9)
        let content = MCPPromptContent.text("Important", annotations: ann)
        if case .text(_, let annotations) = content {
            #expect(annotations?.priority == 0.9)
        } else {
            Issue.record("Expected text variant")
        }
    }

    @Test("PromptContent image variant")
    func contentImage() {
        let content = MCPPromptContent.image(data: "aGVsbG8=", mimeType: "image/png")
        if case .image(let data, let mimeType, let annotations) = content {
            #expect(data == "aGVsbG8=")
            #expect(mimeType == "image/png")
            #expect(annotations == nil)
        } else {
            Issue.record("Expected image variant")
        }
    }

    @Test("PromptContent resource variant")
    func contentResource() {
        let resource = MCPResourceContents.text(uri: "file:///a.txt", mimeType: nil, text: "data")
        let content = MCPPromptContent.resource(resource)
        if case .resource(let r, let annotations) = content {
            #expect(annotations == nil)
            if case .text(_, _, let text) = r {
                #expect(text == "data")
            } else {
                Issue.record("Expected text resource")
            }
        } else {
            Issue.record("Expected resource variant")
        }
    }

    @Test("PromptContent text decodes from JSON")
    func contentTextDecodes() throws {
        let json = """
        {"type": "text", "text": "Hello"}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPPromptContent.self, from: data)
        if case .text(let text, _) = content {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text variant")
        }
    }

    @Test("PromptContent image decodes from JSON")
    func contentImageDecodes() throws {
        let json = """
        {"type": "image", "data": "iVBOR...", "mimeType": "image/png"}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPPromptContent.self, from: data)
        if case .image(let imgData, let mime, _) = content {
            #expect(imgData == "iVBOR...")
            #expect(mime == "image/png")
        } else {
            Issue.record("Expected image variant")
        }
    }

    @Test("PromptContent resource decodes from JSON")
    func contentResourceDecodes() throws {
        let json = """
        {"type": "resource", "resource": {"uri": "file:///a.txt", "text": "content"}}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPPromptContent.self, from: data)
        if case .resource(let r, _) = content {
            if case .text(let uri, _, let text) = r {
                #expect(uri == "file:///a.txt")
                #expect(text == "content")
            } else {
                Issue.record("Expected text resource")
            }
        } else {
            Issue.record("Expected resource variant")
        }
    }

    @Test("PromptContent text with annotations decodes from JSON")
    func contentTextAnnotationsDecodes() throws {
        let json = """
        {"type": "text", "text": "Hi", "annotations": {"audience": ["assistant"], "priority": 0.5}}
        """
        let data = json.data(using: .utf8)!
        let content = try JSONDecoder().decode(MCPPromptContent.self, from: data)
        if case .text(_, let annotations) = content {
            #expect(annotations?.audience == [.assistant])
            #expect(annotations?.priority == 0.5)
        } else {
            Issue.record("Expected text variant")
        }
    }

    @Test("PromptContent text round-trips through JSON")
    func contentTextRoundTrip() throws {
        let original = MCPPromptContent.text("test data", annotations: MCPAnnotations(priority: 0.3))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPPromptContent.self, from: data)
        #expect(decoded == original)
    }

    @Test("PromptContent image round-trips through JSON")
    func contentImageRoundTrip() throws {
        let original = MCPPromptContent.image(data: "AQID", mimeType: "image/jpeg")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPPromptContent.self, from: data)
        #expect(decoded == original)
    }

    @Test("PromptContent is equatable")
    func contentEquatable() {
        let a = MCPPromptContent.text("x")
        let b = MCPPromptContent.text("x")
        let c = MCPPromptContent.image(data: "y", mimeType: "image/png")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MCPPromptMessage

    @Test("PromptMessage with user role and text content")
    func messageUserText() {
        let message = MCPPromptMessage(role: .user, content: .text("Hello"))
        #expect(message.role == .user)
        if case .text(let text, _) = message.content {
            #expect(text == "Hello")
        } else {
            Issue.record("Expected text content")
        }
    }

    @Test("PromptMessage with assistant role")
    func messageAssistant() {
        let message = MCPPromptMessage(role: .assistant, content: .text("Response"))
        #expect(message.role == .assistant)
    }

    @Test("PromptMessage decodes from JSON")
    func messageDecodes() throws {
        let json = """
        {"role": "user", "content": {"type": "text", "text": "Analyze this"}}
        """
        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(MCPPromptMessage.self, from: data)
        #expect(message.role == .user)
    }

    @Test("PromptMessage round-trips through JSON")
    func messageRoundTrip() throws {
        let original = MCPPromptMessage(role: .assistant, content: .text("Done"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MCPPromptMessage.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - MCPPromptResult

    @Test("PromptResult with messages")
    func resultWithMessages() {
        let result = MCPPromptResult(
            description: "A prompt",
            messages: [MCPPromptMessage(role: .user, content: .text("Hi"))]
        )
        #expect(result.description == "A prompt")
        #expect(result.messages.count == 1)
    }

    @Test("PromptResult decodes from JSON")
    func resultDecodes() throws {
        let json = """
        {
            "description": "Code review prompt",
            "messages": [
                {"role": "user", "content": {"type": "text", "text": "Review this code"}},
                {"role": "assistant", "content": {"type": "text", "text": "I'll review it"}}
            ]
        }
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPPromptResult.self, from: data)
        #expect(result.description == "Code review prompt")
        #expect(result.messages.count == 2)
        #expect(result.messages[0].role == .user)
        #expect(result.messages[1].role == .assistant)
    }

    @Test("PromptResult without description")
    func resultNoDescription() throws {
        let json = """
        {"messages": [{"role": "user", "content": {"type": "text", "text": "Hi"}}]}
        """
        let data = json.data(using: .utf8)!
        let result = try JSONDecoder().decode(MCPPromptResult.self, from: data)
        #expect(result.description == nil)
        #expect(result.messages.count == 1)
    }

    // MARK: - MCPRole (shared)

    @Test("Role encodes and decodes")
    func roleRoundTrip() throws {
        let data = try JSONEncoder().encode(MCPRole.user)
        let decoded = try JSONDecoder().decode(MCPRole.self, from: data)
        #expect(decoded == .user)
    }
}
