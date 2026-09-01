import Foundation
import Logging
import NIOCore

/// Decodes a byte stream into Server-Sent Events as they arrive.
///
/// The distinction from ``StreamableHTTPBodyDecoder`` is timing, not format. That type decodes
/// a body already in hand; this one yields each event at the moment the server flushes it.
/// A progress notification delivered after the work finishes is not a progress notification.
///
/// Framing is not reimplemented here — every rule about `data:` continuation lines, comments,
/// blank-line boundaries and CRLF belongs to ``SSEParser``, which both paths share. What this
/// adds is the part a parser cannot do on its own: holding parser state across buffer
/// boundaries that fall wherever the network put them, including inside a `\r\n`.
///
/// Generic over the byte source rather than tied to `HTTPClientResponse.Body`, because the
/// behaviour worth testing is exactly what happens at chunk boundaries, and a test that has to
/// construct a real HTTP response body to check one is a test nobody writes.
struct SSEEventStream: Sendable {

    /// Yields each complete event as the bytes for it arrive.
    ///
    /// A partial event at the end of the stream is discarded: the alternative is handing a
    /// caller half a JSON-RPC message to decode. A producer failure is rethrown into the
    /// stream rather than ending it quietly, because a dropped connection presented as a clean
    /// finish reads as a server with nothing more to say.
    ///
    /// - Parameter bytes: The response body, as chunks arrive.
    /// - Returns: The events, in order.
    static func events<Bytes: AsyncSequence & Sendable>(
        from bytes: Bytes
    ) -> AsyncThrowingStream<SSEEvent, any Error> where Bytes.Element == ByteBuffer {
        AsyncThrowingStream { continuation in
            let task = Task {
                // Parser state lives here, across every chunk. A parser per chunk is the bug
                // this type exists to prevent: it would lose any event split across two.
                var parser = SSEParser()
                do {
                    for try await buffer in bytes {
                        guard let text = buffer.getString(at: buffer.readerIndex,
                                                          length: buffer.readableBytes) else {
                            // A chunk that is not valid UTF-8 on its own boundary is normal —
                            // a multi-byte character can be split — so this is skipped rather
                            // than treated as a failure. `SSEParser` sees the rest.
                            continue
                        }
                        for event in parser.append(text) {
                            continuation.yield(event)
                        }
                    }
                    // Whatever is still buffered was never terminated by a blank line, so it
                    // is not an event. Dropped deliberately.
                    continuation.finish()
                } catch {
                    // Logged as well as propagated. Handing an error to a stream is not the
                    // same as throwing it up a call stack: a consumer that has stopped
                    // iterating never sees this one, and a body that died mid-response is
                    // worth a line either way.
                    let logger = Logger(label: "MCPClient.SSEEventStream")
                    // logging: why a response body stopped, which the consumer may never see
                    logger.warning("event stream ended in failure: \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }

            // lifecycle: cancelled when the consumer stops iterating, which is what stops the
            // producer reading a body nobody is waiting for.
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
