import Foundation
#if canImport(FoundationNetworking)
// `URLSession` and friends live here on Linux. Invisible on a Mac, so only CI catches it.
import FoundationNetworking
#endif
import Testing
import AsyncHTTPClient
@testable import MCPClient

/// The client against an independent server that speaks `2026-07-28`.
///
/// ``ConformanceServerTests`` runs against the reference implementation, which stops at
/// `2025-11-25` — so everything this client does in the stateless era has so far been checked
/// only against stubs written from the same reading of the same document. That catches
/// mistakes in the code and not in the reading, and the stateless revision is exactly where a
/// misreading is cheap to make: there is no handshake to fail loudly, so a client that gets
/// `_meta` wrong looks like a client whose requests are simply rejected.
///
/// SwiftMCPServer implements the revision independently. It is a sibling project rather than a
/// third party, but it was written against the specification and not against this client, and
/// it is the only thing available that will disagree.
///
/// **Opt in explicitly**, after starting the server:
///
/// ```
/// git clone --branch 2.0.0 https://github.com/jpurnell/swift-mcp-server.git
/// cd swift-mcp-server && PORT=3002 swift run conformance-server
/// MCP_STATELESS_SERVER=http://127.0.0.1:3002/mcp swift test --filter StatelessEraServerTests
/// ```
///
/// The product is `conformance-server`; `ConformanceServer` is the target it builds from, and
/// naming that instead fails with "no executable product named". Pointing at the published
/// repository rather than a local SwiftMCPServer checkout keeps this suite reproducible —
/// a working tree moves, and it moved out from under this suite the day it was written.
///
/// Skipped otherwise. It needs a process this suite does not start, so it cannot run
/// unattended — but it costs nothing and needs no account.
@Suite("Conformance — stateless era", .serialized, .enabled(if: StatelessServer.isEnabled))
struct StatelessEraServerTests {

    /// The factory settles on the stateless era, and says so.
    ///
    /// This is the whole point of ``MCPConnectionFactory``: a caller names no version and gets
    /// the newest one both sides speak. Asserting the era as well as the version is what
    /// separates "negotiated 2026-07-28" from "negotiated 2026-07-28 and then behaved as
    /// though it had shaken hands" — the second would pass a version check and still be wrong
    /// about every request that followed.
    @Test("The factory negotiates 2026-07-28 by discovery", .timeLimit(.minutes(1)))
    func negotiatesStatelessEra() async throws {
        let transport = StreamableHTTPTransport(url: try StatelessServer.url())
        let connected = try await MCPConnectionFactory.connect(
            transport: transport,
            clientName: "SwiftMCPClient conformance",
            clientVersion: "1.0.0")

        #expect(connected.protocolVersion == "2026-07-28")
        #expect(connected.era == .stateless)
        StatelessServer.report("negotiated: \(connected.protocolVersion) (\(connected.era))")

        // Discovery carried the server's identity, so nothing had to shake hands to learn it.
        let info = try #require(connected.serverInfo)
        StatelessServer.report("server: \(info.name) \(info.version)")

        try await connected.connection.disconnect()
    }

    /// Work happens with no handshake and no session.
    ///
    /// A session id appearing here would mean the transport had fallen back to handshake
    /// behaviour behind the factory's back — the connection would still work, which is what
    /// makes it worth asserting: the failure is silent.
    @Test("Tools list without a handshake or a session", .timeLimit(.minutes(1)))
    func listsToolsStatelessly() async throws {
        let transport = StreamableHTTPTransport(url: try StatelessServer.url())
        let connected = try await MCPConnectionFactory.connect(
            transport: transport,
            clientName: "SwiftMCPClient conformance",
            clientVersion: "1.0.0")

        let tools = try await connected.connection.listTools()
        StatelessServer.report("tools: \(tools.count)")
        #expect(!tools.isEmpty)

        #expect(await transport.sessionId == nil, "a stateless connection took a session id")

        try await connected.connection.disconnect()
    }

    /// Every request states its own version, and the server checks it.
    ///
    /// The revision requires the version in `_meta` to match the `MCP-Protocol-Version`
    /// header, and a server that finds them different rejects the request. So a run of
    /// requests that all succeed is the assertion: it is the only external evidence that the
    /// two are produced from one value rather than derived twice.
    @Test("Repeated requests carry consistent metadata", .timeLimit(.minutes(1)))
    func metadataStaysConsistent() async throws {
        let transport = StreamableHTTPTransport(url: try StatelessServer.url())
        let connected = try await MCPConnectionFactory.connect(
            transport: transport,
            clientName: "SwiftMCPClient conformance",
            clientVersion: "1.0.0")

        // More than one, because a mismatch that only appears after the first request is the
        // interesting bug — the first is the one every by-hand probe checks.
        var counts: [Int] = []
        for _ in 0..<3 {
            counts.append(try await connected.connection.listTools().count)
        }
        #expect(Set(counts).count == 1, "the same question got different answers: \(counts)")
        #expect(counts.first ?? 0 > 0)

        // Methods the server routes differently, in case the metadata only survives the path
        // that `tools/list` happens to take.
        _ = try await connected.connection.listResources()
        _ = try await connected.connection.listPrompts()

        // Still stateless afterwards. A server that had quietly moved us to a session would
        // have answered all of the above just as happily.
        #expect(await transport.sessionId == nil)

        try await connected.connection.disconnect()
    }
}

/// Where the stateless-era server is, and whether to run against it at all.
enum StatelessServer {

    /// Whether the suite runs. Absent variable, absent server, skipped suite.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MCP_STATELESS_SERVER"] != nil
    }

    /// The endpoint under test.
    static func url() throws -> URL {
        let string = ProcessInfo.processInfo.environment["MCP_STATELESS_SERVER"]
            ?? "http://127.0.0.1:3002/mcp"
        // SECURITY: a loopback address supplied by whoever opted into this run.
        return try #require(URL(string: string), "MCP_STATELESS_SERVER is not a URL")
    }

    /// Prints what the server said, so a run leaves a record of what it was talking to.
    static func report(_ message: String) {
        print("[stateless] \(message)")
    }
}
