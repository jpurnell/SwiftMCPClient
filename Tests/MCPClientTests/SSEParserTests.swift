import Testing
@testable import MCPClient

@Suite("SSEParser")
struct SSEParserTests {

    // MARK: - Golden Path

    @Test("Parses single event with data field")
    func parseSingleEvent() {
        var parser = SSEParser()
        let events = parser.append("data: hello world\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "hello world")
        #expect(events.first?.event == nil)
        #expect(events.first?.id == nil)
    }

    @Test("Parses event with type and data")
    func parseEventWithType() {
        var parser = SSEParser()
        let events = parser.append("event: endpoint\ndata: /messages?sessionId=abc\n\n")
        #expect(events.count == 1)
        #expect(events.first?.event == "endpoint")
        #expect(events.first?.data == "/messages?sessionId=abc")
    }

    @Test("Parses event with id field")
    func parseEventWithID() {
        var parser = SSEParser()
        let events = parser.append("id: 42\ndata: test\n\n")
        #expect(events.count == 1)
        #expect(events.first?.id == "42")
        #expect(events.first?.data == "test")
    }

    @Test("Parses event with all fields")
    func parseEventWithAllFields() {
        var parser = SSEParser()
        let events = parser.append("event: message\nid: 7\ndata: {\"result\":true}\n\n")
        #expect(events.count == 1)
        let event = events[0]
        #expect(event.event == "message")
        #expect(event.id == "7")
        #expect(event.data == "{\"result\":true}")
    }

    @Test("Parses multi-line data joined by newlines")
    func parseMultiLineData() {
        var parser = SSEParser()
        let events = parser.append("data: line one\ndata: line two\ndata: line three\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "line one\nline two\nline three")
    }

    @Test("Parses multiple events in one chunk")
    func parseMultipleEvents() {
        var parser = SSEParser()
        let events = parser.append("data: first\n\ndata: second\n\n")
        #expect(events.count == 2)
        #expect(events[0].data == "first")
        #expect(events[1].data == "second")
    }

    // MARK: - Chunked Delivery

    @Test("Parses event split across two chunks")
    func parseSplitAcrossChunks() {
        var parser = SSEParser()
        let events1 = parser.append("event: message\nda")
        #expect(events1.isEmpty)
        let events2 = parser.append("ta: hello\n\n")
        #expect(events2.count == 1)
        #expect(events2.first?.event == "message")
        #expect(events2.first?.data == "hello")
    }

    @Test("Parses event with blank line split across chunks")
    func parseBlankLineSplitAcrossChunks() {
        var parser = SSEParser()
        let events1 = parser.append("data: hello\n")
        #expect(events1.isEmpty)
        let events2 = parser.append("\n")
        #expect(events2.count == 1)
        #expect(events2.first?.data == "hello")
    }

    // MARK: - Edge Cases

    @Test("Empty input returns no events")
    func parseEmptyInput() {
        var parser = SSEParser()
        let events = parser.append("")
        #expect(events.isEmpty)
    }

    @Test("Comment lines are ignored")
    func parseCommentLines() {
        var parser = SSEParser()
        let events = parser.append(": this is a comment\ndata: actual data\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "actual data")
    }

    @Test("Data field with no value is empty string")
    func parseDataWithNoValue() {
        var parser = SSEParser()
        let events = parser.append("data:\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "")
    }

    @Test("Data field with leading space stripped")
    func parseDataWithLeadingSpace() {
        var parser = SSEParser()
        // Per SSE spec: if the value starts with a space, remove it
        let events = parser.append("data: hello\n\n")
        #expect(events.first?.data == "hello")
    }

    @Test("Event with no data field is skipped")
    func parseEventWithNoDataField() {
        var parser = SSEParser()
        let events = parser.append("event: ping\n\n")
        #expect(events.isEmpty)
    }

    @Test("Handles carriage return line endings")
    func parseCRLFLineEndings() {
        var parser = SSEParser()
        let events = parser.append("data: hello\r\n\r\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "hello")
    }

    @Test("Unknown fields are ignored")
    func parseUnknownFields() {
        var parser = SSEParser()
        let events = parser.append("retry: 3000\ndata: hello\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "hello")
    }

    @Test("Reset clears buffered state")
    func resetClearsBuffer() {
        var parser = SSEParser()
        _ = parser.append("data: partial")
        parser.reset()
        let events = parser.append("data: fresh\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == "fresh")
    }

    @Test("Multiple blank lines between events don't create empty events")
    func parseMultipleBlankLines() {
        var parser = SSEParser()
        let events = parser.append("data: first\n\n\n\ndata: second\n\n")
        #expect(events.count == 2)
        #expect(events[0].data == "first")
        #expect(events[1].data == "second")
    }

    @Test("Parses JSON data payload correctly")
    func parseJSONPayload() {
        var parser = SSEParser()
        let json = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"content\":[{\"type\":\"text\",\"text\":\"Score: 74.8\"}]}}"
        let events = parser.append("event: message\ndata: \(json)\n\n")
        #expect(events.count == 1)
        #expect(events.first?.data == json)
        #expect(events.first?.event == "message")
    }
}
