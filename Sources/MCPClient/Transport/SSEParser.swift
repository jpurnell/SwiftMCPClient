import Foundation

/// A single Server-Sent Event parsed from an SSE byte stream.
///
/// Each event may have an optional event type, one or more lines of data,
/// and an optional event ID. Comment-only lines (starting with `:`) are
/// silently discarded by ``SSEParser``.
///
/// ## SSE Wire Format
///
/// ```
/// event: endpoint
/// data: /messages?sessionId=abc123
///
/// event: message
/// data: {"jsonrpc":"2.0","id":1,"result":{}}
///
/// ```
struct SSEEvent: Sendable, Equatable {
    /// The event type (from `event:` field). Defaults to `nil` (treated as `"message"` by SSE spec).
    let event: String?

    /// The event data (concatenation of all `data:` lines, joined by newlines).
    let data: String

    /// The optional event ID (from `id:` field).
    let id: String?
}

/// A stateful parser that buffers incoming text and yields complete SSE events.
///
/// Feed incoming chunks of text via ``append(_:)`` and collect the resulting
/// ``SSEEvent`` values. The parser handles multi-line `data:` fields,
/// comment lines, and events split across multiple chunks.
///
/// Per the [SSE spec](https://html.spec.whatwg.org/multipage/server-sent-events.html):
/// - Lines starting with `:` are comments (ignored)
/// - Fields are `event`, `data`, `id`, `retry` (retry is ignored here)
/// - Events are delimited by blank lines
/// - If value starts with a space after the colon, that space is stripped
/// - Multiple `data:` lines are concatenated with `\n`
/// - Events with no `data:` field are discarded
struct SSEParser: Sendable {
    private var buffer: String = ""
    private var currentEvent: String?
    private var currentData: [String] = []
    private var currentID: String?

    /// Append a chunk of text and return any complete events found.
    ///
    /// - Parameter text: Raw text received from the SSE stream.
    /// - Returns: An array of complete ``SSEEvent`` values (may be empty).
    mutating func append(_ text: String) -> [SSEEvent] {
        buffer += text
        var events: [SSEEvent] = []

        while let lineEnd = findLineEnd() {
            let line = String(buffer[buffer.startIndex..<lineEnd.start])
            buffer = String(buffer[lineEnd.end...])

            if line.isEmpty {
                // Blank line = event boundary
                if let event = buildEvent() {
                    events.append(event)
                }
                resetCurrentFields()
            } else {
                processLine(line)
            }
        }

        return events
    }

    /// Clear all buffered state.
    mutating func reset() {
        buffer = ""
        resetCurrentFields()
    }

    // MARK: - Private

    /// Find the next line ending (\n, \r\n, or \r) in the buffer.
    /// Returns the range of the line ending characters, or nil if no complete line exists.
    ///
    /// Uses unicode scalar view because Swift's `Character` type treats `\r\n` as a
    /// single grapheme cluster, which prevents splitting on `\r` vs `\n` individually.
    private func findLineEnd() -> (start: String.Index, end: String.Index)? {
        let scalars = buffer.unicodeScalars
        var index = scalars.startIndex
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if scalar == "\r" {
                let next = scalars.index(after: index)
                if next < scalars.endIndex, scalars[next] == "\n" {
                    // \r\n
                    return (start: index, end: scalars.index(after: next))
                }
                // bare \r
                return (start: index, end: next)
            } else if scalar == "\n" {
                return (start: index, end: scalars.index(after: index))
            }
            index = scalars.index(after: index)
        }
        return nil
    }

    /// Process a single non-empty line according to the SSE spec.
    private mutating func processLine(_ line: String) {
        // Comment line
        if line.hasPrefix(":") {
            return
        }

        // Split on first colon
        if let colonIndex = line.firstIndex(of: ":") {
            let field = String(line[line.startIndex..<colonIndex])
            var value = String(line[line.index(after: colonIndex)...])

            // Strip leading space from value (SSE spec)
            if value.hasPrefix(" ") {
                value = String(value.dropFirst())
            }

            switch field {
            case "event":
                currentEvent = value
            case "data":
                currentData.append(value)
            case "id":
                currentID = value
            default:
                // Unknown fields (e.g., "retry") are ignored
                break
            }
        }
        // Lines with no colon are ignored per SSE spec
    }

    /// Build an SSEEvent from current fields, or nil if no data was collected.
    private func buildEvent() -> SSEEvent? {
        guard !currentData.isEmpty else {
            return nil
        }
        return SSEEvent(
            event: currentEvent,
            data: currentData.joined(separator: "\n"),
            id: currentID
        )
    }

    /// Reset per-event field accumulators.
    private mutating func resetCurrentFields() {
        currentEvent = nil
        currentData = []
        currentID = nil
    }
}
