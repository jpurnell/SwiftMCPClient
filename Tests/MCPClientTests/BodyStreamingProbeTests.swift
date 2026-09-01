import Foundation
import Testing
import AsyncHTTPClient
import NIOCore
@testable import MCPClient

/// Does `AsyncHTTPClient` deliver a response body as the server flushes it?
///
/// The Streamable HTTP compliance plan rests its first gap on the answer. Streaming POST
/// bodies exists so a progress notification reaches the caller *while the work is happening*;
/// if the client library accumulates the body and hands it over at the end, incremental
/// decoding produces exactly the batched delivery it was built to replace, with more
/// machinery — and that gap should be dropped from the plan rather than built.
///
/// The plan makes resolving this the gate on everything else, before any other test is
/// written. This is that resolution, kept as a permanent check: if the answer ever changes,
/// the design premise has changed with it, and a silent regression here would look like a
/// server being slow rather than a library holding bytes.
@Suite("Response body streaming")
struct BodyStreamingProbeTests {

    /// The probe: the server will not send its second event until the client confirms the
    /// first arrived, so the ordering *is* the answer. No elapsed time is measured.
    @Test("Body chunks reach the consumer while the response is still open")
    func chunksArriveBeforeTheResponseEnds() async throws {
        let server = try await FlushProbeServer.start()
        let client = HTTPClient(eventLoopGroupProvider: .singleton)

        do {
            var request = HTTPClientRequest(url: try await server.probeURL.absoluteString)
            request.method = .POST
            let response = try await client.execute(request, timeout: .seconds(15))

            var events: [String] = []
            for try await buffer in response.body {
                let text = String(buffer: buffer)
                events.append(text)
                // Told over a separate request, because this one's body is still open. If the
                // library buffers, this line is not reached until the server has given up.
                if text.contains("first"), events.count == 1 {
                    try await tell(client, server.signalURL)
                }
            }

            let combined = events.joined()
            #expect(combined.contains("first") && combined.contains("second"),
                    "the probe did not complete: \(combined)")

            let incremental = await server.signalPrecededSecondFlush
            #expect(incremental, """
                AsyncHTTPClient did not deliver the first chunk until the response closed. \
                Streaming POST bodies cannot make progress notifications timely, and gap #1 of \
                the Streamable HTTP compliance plan should be dropped rather than built.
                """)

            // Recorded either way — a passing assertion above is a finding worth stating out
            // loud, since a whole phase of work is scoped on it.
            let verdict = incremental ? "INCREMENTALLY" : "ONLY AT END"
            let finding = "    probe: chunks delivered \(verdict) — \(events.count) chunk(s)\n"
            FileHandle.standardError.write(Data(finding.utf8))

            try await client.shutdown()
            await server.stop()
        } catch {
            // `HTTPClient` traps in `deinit` if it is not shut down, which would take the
            // suite down rather than fail this test.
            try? await client.shutdown()
            await server.stop()
            throw error
        }
    }

    /// Sends the signal that releases the second event.
    private func tell(_ client: HTTPClient, _ url: URL) async throws {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .GET
        _ = try await client.execute(request, timeout: .seconds(5))
    }
}
