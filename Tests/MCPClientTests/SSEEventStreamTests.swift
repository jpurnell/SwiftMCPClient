import Foundation
import Testing
import NIOCore
@testable import MCPClient

/// Turning a stream of bytes into events *as they arrive*.
///
/// The distinction from `StreamableHTTPBodyDecoder` is timing, not format: that decodes a body
/// already in hand, this yields each event at the moment the server flushes it. A progress
/// notification delivered after the work finishes is not a progress notification.
///
/// Framing rules are not retested here — `SSEParser` owns them and has its own suite. What is
/// tested is everything the boundary between chunks and events can get wrong: an event split
/// across two buffers, a terminator split down the middle, a partial event at the end, and an
/// error that must not read as a clean finish.
@Suite("SSE event stream")
struct SSEEventStreamTests {

    /// The property the whole design rests on. An event completes in the first chunk, and it
    /// must be delivered before the producer has finished — a stream that only yields at the
    /// end is `collect()` with more machinery.
    ///
    /// Time-limited rather than left to hang: an implementation that buffers to the end would
    /// wait forever on the first `next()`, and a suite that hangs reports nothing.
    @Test("An event is yielded before the producer finishes", .timeLimit(.minutes(1)))
    func yieldsBeforeProducerFinishes() async throws {
        let (bytes, producer) = AsyncThrowingStream.makeStream(of: ByteBuffer.self)
        var events = SSEEventStream.events(from: bytes).makeAsyncIterator()

        producer.yield(buffer("data: one\n\n"))
        let first = try await events.next()

        #expect(first?.data == "one", "nothing was yielded while the producer was still open")

        producer.finish()
    }

    /// An event split mid-field across two buffers is one event, not two fragments and not
    /// none. This is the exact vector from the body-decoder suite, split by hand.
    @Test("An event split across buffers is reassembled")
    func reassemblesSplitEvent() async throws {
        let events = try await collect(chunks: [#"data: {"a":"#, "1}\n\n"])

        #expect(events.map(\.data) == [#"{"a":1}"#])
    }

    /// A split *inside* the `\r\n` terminator must not read as a boundary. Swift treats
    /// `\r\n` as one grapheme cluster, so a naive split on newlines gets this wrong in a way
    /// that only shows up when a chunk lands between the two bytes — which a real server does
    /// eventually, and no test with whole-event chunks ever will.
    @Test("A split inside a CRLF terminator does not end the event early")
    func splitInsideCRLFTerminator() async throws {
        let events = try await collect(chunks: ["data: one\r\n\r", "\ndata: two\r\n\r\n"])

        #expect(events.map(\.data) == ["one", "two"])
    }

    /// Several events arriving in one buffer are all yielded, in order.
    @Test("Multiple events in one buffer are yielded in order")
    func multipleEventsInOneBuffer() async throws {
        let events = try await collect(chunks: ["data: one\n\ndata: two\n\ndata: three\n\n"])

        #expect(events.map(\.data) == ["one", "two", "three"])
    }

    /// A stream cut mid-event keeps what completed and drops the fragment. Yielding the
    /// fragment would hand a caller half a JSON-RPC message to decode.
    @Test("A partial event at the end of the stream is discarded")
    func discardsTrailingPartialEvent() async throws {
        let events = try await collect(chunks: ["data: complete\n\n", "data: cut-off"])

        #expect(events.map(\.data) == ["complete"])
    }

    /// An id is carried through, because resumption depends on it: `Last-Event-ID` cannot be
    /// sent by a transport whose event stream discarded the ids.
    @Test("Event ids survive the stream")
    func carriesEventIDs() async throws {
        let events = try await collect(chunks: ["id: 42\ndata: one\n\n"])

        #expect(events.first?.id == "42")
    }

    /// A producer failure must arrive as a thrown element. Ending the stream quietly would
    /// present a dropped connection as a server that had nothing more to say.
    @Test("A producer error is thrown, not swallowed")
    func propagatesProducerError() async throws {
        let (bytes, producer) = AsyncThrowingStream.makeStream(of: ByteBuffer.self)
        producer.yield(buffer("data: one\n\n"))
        producer.finish(throwing: StreamTrouble.dropped)

        var iterator = SSEEventStream.events(from: bytes).makeAsyncIterator()
        #expect(try await iterator.next()?.data == "one")

        await #expect(throws: StreamTrouble.dropped) {
            _ = try await iterator.next()
        }
    }

    /// An empty stream is an empty sequence, not a hang and not an error.
    @Test("A stream that yields nothing ends cleanly")
    func emptyStreamEndsCleanly() async throws {
        #expect(try await collect(chunks: []).isEmpty)
    }
}

// MARK: - Helpers

/// Feeds fixed chunks through the stream and collects every event.
private func collect(chunks: [String]) async throws -> [SSEEvent] {
    let (bytes, producer) = AsyncThrowingStream.makeStream(of: ByteBuffer.self)
    for chunk in chunks {
        producer.yield(buffer(chunk))
    }
    producer.finish()

    var events: [SSEEvent] = []
    for try await event in SSEEventStream.events(from: bytes) {
        events.append(event)
    }
    return events
}

/// A `ByteBuffer` holding a string, as a server would have written it.
private func buffer(_ text: String) -> ByteBuffer {
    var buffer = ByteBufferAllocator().buffer(capacity: text.utf8.count)
    buffer.writeString(text)
    return buffer
}

/// A producer failure distinct from anything the stream could invent itself.
private enum StreamTrouble: Error {
    case dropped
}
