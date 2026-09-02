import Foundation
import Testing
import MCP
@testable import MCPClient

/// Asking a server what it speaks, before speaking it.
///
/// `server/discover` is the stateless revision's answer to a client that would otherwise have
/// to guess a protocol version and learn from a rejection. Servers **MUST** implement it;
/// clients **MAY** call it. Calling it is how version selection stops being trial and error.
@Suite("Server discovery")
struct ServerDiscoveryTests {

    /// What the server supports, in its own words.
    @Test("Discovery reports the server's versions and identity")
    func reportsVersionsAndIdentity() async throws {
        let transport = DiscoveryStubTransport(
            supportedVersions: ["2025-11-25", "2026-07-28"], serverName: "stub")
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        let discovered = try await connection.discoverServer()

        #expect(discovered.supportedVersions == ["2025-11-25", "2026-07-28"])
        // Identity travels in the result's `_meta`, not as a field: 2026-07-28 has servers
        // identify themselves on every result rather than once in a handshake that no longer
        // exists.
        #expect(discovered._meta?.serverInfo?.name == "stub")
    }

    /// Choosing between what we speak and what it does. The newest revision both sides know is
    /// the right answer; picking the newest the *server* knows would choose one this client
    /// cannot write, and picking our own newest ignores what it just said.
    @Test("The best mutual version is the newest both sides know", arguments: [
        (["2024-11-05", "2025-06-18"], "2025-06-18"),
        (["2025-11-25", "2026-07-28"], "2026-07-28"),
        (["2024-11-05"], "2024-11-05"),
        (["2030-01-01", "2026-07-28"], "2026-07-28")
    ])
    func choosesBestMutualVersion(server: [String], expected: String) {
        #expect(MCPClientConnection.bestMutualVersion(serverSupports: server) == expected)
    }

    /// A server that shares no version with this client gets no guess. Picking one anyway
    /// produces a request the server will refuse, and the refusal would look like a bug here
    /// rather than an incompatibility.
    @Test("No shared version yields no choice")
    func noSharedVersion() {
        #expect(MCPClientConnection.bestMutualVersion(serverSupports: ["2019-01-01"]) == nil)
        #expect(MCPClientConnection.bestMutualVersion(serverSupports: []) == nil)
    }
}

/// Opting in to the notifications a server originates.
///
/// 2026-07-28 replaced the standalone `GET` stream with `subscriptions/listen`: one long-lived
/// POST whose *response stream* carries the change notifications a client asked for. Requests
/// keep their own streams — progress and log messages travel with the request they belong to,
/// not here.
@Suite("Subscriptions")
struct SubscriptionTests {

    /// The filter states what the client wants, and the server acknowledges what it will
    /// actually send. Those differ: a server with no resources to watch says so.
    @Test("Listening states what is wanted and reports what was granted")
    func statesAndReportsFilter() async throws {
        let transport = SubscriptionStubTransport(
            granted: SubscriptionFilter(toolsListChanged: true, resourcesListChanged: false))
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        let granted = try await connection.listen(
            for: SubscriptionFilter(toolsListChanged: true, resourcesListChanged: true))

        #expect(granted.toolsListChanged == true)
        #expect(granted.resourcesListChanged == false,
                "the client believed a subscription the server declined")
    }

    /// The request that goes out names the subscriptions asked for.
    @Test("The listen request carries the filter")
    func requestCarriesFilter() async throws {
        let transport = SubscriptionStubTransport(
            granted: SubscriptionFilter(toolsListChanged: true))
        let connection = MCPClientConnection(transport: transport)
        try await connection.beginStateless(
            protocolVersion: "2026-07-28", clientName: "probe", clientVersion: "1.0")

        _ = try await connection.listen(for: SubscriptionFilter(toolsListChanged: true))

        let sent = try #require(subscriptionFilter(of: await transport.lastRequest))
        #expect(sent["toolsListChanged"] as? Bool == true)
    }
}

// MARK: - Helpers

/// Answers `server/discover`.
private actor DiscoveryStubTransport: MCPTransport {

    private let supportedVersions: [String]
    private let serverName: String
    private var pending: [Data] = []

    init(supportedVersions: [String], serverName: String) {
        self.supportedVersions = supportedVersions
        self.serverName = serverName
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        let result: [String: Any] = [
            "supportedVersions": supportedVersions,
            "capabilities": [String: Any](),
            "_meta": [
                "io.modelcontextprotocol/serverInfo": ["name": serverName, "version": "1.0.0"]
            ],
            "resultType": "complete"
        ]
        pending.append(try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
    }

    func receive() async throws -> Data {
        // Suspends rather than throwing on an empty queue: a stub that throws kills the
        // message dispatcher the moment it starts, and every later response goes undelivered.
        for _ in 0..<200 {
            if !pending.isEmpty { return pending.removeFirst() }
            // silent: a cancelled sleep ends the wait, and the throw below reports it
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw MCPClient.MCPError.connectionFailed(reason: "nothing queued")
    }
}

/// Answers `subscriptions/listen` with the subset it will honour.
private actor SubscriptionStubTransport: MCPTransport {

    private let granted: SubscriptionFilter
    private var pending: [Data] = []
    private(set) var lastRequest: Data?

    init(granted: SubscriptionFilter) {
        self.granted = granted
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        lastRequest = data
        let encoded = try JSONEncoder().encode(granted)
        let filter = try JSONSerialization.jsonObject(with: encoded)
        let result: [String: Any] = ["notifications": filter, "resultType": "complete"]
        pending.append(try JSONSerialization.data(
            withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
    }

    func receive() async throws -> Data {
        // Suspends rather than throwing on an empty queue: a stub that throws kills the
        // message dispatcher the moment it starts, and every later response goes undelivered.
        for _ in 0..<200 {
            if !pending.isEmpty { return pending.removeFirst() }
            // silent: a cancelled sleep ends the wait, and the throw below reports it
            try? await Task.sleep(for: .milliseconds(10))
        }
        throw MCPClient.MCPError.connectionFailed(reason: "nothing queued")
    }
}

/// The subscription filter of a recorded request, parsed outside the actor that captured it.
private func subscriptionFilter(of data: Data?) -> [String: Any]? {
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let params = object["params"] as? [String: Any] else {
        return nil
    }
    return params["notifications"] as? [String: Any]
}
