import Foundation
import Testing
import MCP
@testable import MCPClient

/// Driving the `io.modelcontextprotocol/tasks` extension from the client.
///
/// The wire shapes are not tested here. They belong to the shared SDK, which owns them for this
/// client and for SwiftMCPServer both, and which decodes all 129 specification examples in its
/// own suite. Re-asserting them here would be a second opinion about a format neither package
/// defines.
///
/// What is this client's own is the polling: when to stop, how long to wait, and what a failed
/// task should look like to a caller.
/// Driving a task from the client.
///
/// A task nobody can poll is a handle and nothing else, so the polling loop is the feature —
/// and it is where the mistakes live: stopping on the wrong states, ignoring the server's
/// requested interval, or running forever against a task that never finishes.
@Suite("Tasks extension — polling")
struct TaskPollingTests {

    /// The loop runs until the status is terminal and then stops, returning what it saw last.
    @Test("Polling stops at a terminal status", .timeLimit(.minutes(1)))
    func pollsUntilTerminal() async throws {
        let transport = ScriptedTaskTransport(statuses: [.working, .working, .completed])
        let connection = MCPClientConnection(transport: transport)

        let final = try await connection.awaitTask(id: "task-1")

        #expect(final.status == .completed)
        #expect(await transport.pollCount == 3)
    }

    /// It stops on a task waiting for input, rather than polling a task that will not move
    /// until the client answers it.
    @Test("Polling stops when the task needs input", .timeLimit(.minutes(1)))
    func stopsOnInputRequired() async throws {
        let transport = ScriptedTaskTransport(statuses: [.working, .inputRequired, .completed])
        let connection = MCPClientConnection(transport: transport)

        let final = try await connection.awaitTask(id: "task-1")

        #expect(final.status == .inputRequired)
        #expect(await transport.pollCount == 2, "polled past a task that was waiting on us")
    }

    /// A bound, so a task that never finishes ends the wait rather than the process.
    @Test("Polling gives up after a bounded number of attempts", .timeLimit(.minutes(1)))
    func boundedAttempts() async throws {
        let transport = ScriptedTaskTransport(statuses: [.working])
        let connection = MCPClientConnection(transport: transport)

        await #expect(throws: (any Error).self) {
            _ = try await connection.awaitTask(id: "task-1", maximumPolls: 3)
        }
        #expect(await transport.pollCount == 3)
    }

    /// A failed task is terminal and comes back as a result, not as a thrown error: "the work
    /// failed" is an answer, and the caller needs the status message that came with it.
    @Test("A failed task is returned, not thrown", .timeLimit(.minutes(1)))
    func failedTaskIsReturned() async throws {
        let transport = ScriptedTaskTransport(statuses: [.failed])
        let connection = MCPClientConnection(transport: transport)

        let final = try await connection.awaitTask(id: "task-1")

        #expect(final.status == .failed)
    }
}

/// A transport that answers `tasks/get` from a script.
private actor ScriptedTaskTransport: MCPTransport {

    private var statuses: [TaskStatus]
    private(set) var pollCount = 0
    private var pending: [Data] = []

    init(statuses: [TaskStatus]) {
        self.statuses = statuses
    }

    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] else { return }
        pollCount += 1
        // The last scripted status repeats, so a test can script a task that never finishes.
        let status = statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? .working)
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "result": [
                "task": [
                    "taskId": "task-1",
                    "status": status.rawValue,
                    "createdAt": "2026-09-01T00:00:00Z",
                    "lastUpdatedAt": "2026-09-01T00:00:00Z",
                    // Small enough that a bounded test does not wait on real time.
                    "pollIntervalMs": 1
                ]
            ]
        ]
        pending.append(try JSONSerialization.data(withJSONObject: response))
    }

    func receive() async throws -> Data {
        guard !pending.isEmpty else {
            throw MCPError.connectionFailed(reason: "nothing queued")
        }
        return pending.removeFirst()
    }
}

/// The `_meta` a 2026-07-28 client attaches to every request.
///
/// The revision is stateless: there is no handshake, so each request carries the protocol
/// version and the client's identity and capabilities itself. The version in `_meta` **MUST**
/// match the `MCP-Protocol-Version` header — a server that finds them different rejects the
/// request with `HeaderMismatch`, so the two cannot be produced independently.
@Suite("Request metadata — _meta")
struct RequestMetaTests {

    /// Attached once a 2026-era version is negotiated, and carrying what the revision names.
    @Test("A 2026-era request carries protocol version, client info and capabilities")
    func attachesMeta() async throws {
        let transport = RecordingBodyTransport(negotiated: "2026-07-28")
        let connection = MCPClientConnection(transport: transport)
        _ = try await connection.initialize(clientName: "probe", clientVersion: "2.1")
        _ = try? await connection.listTools()

        let meta = try #require(requestMeta(of: await transport.lastRequest))
        #expect(meta["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28")
        #expect((meta["io.modelcontextprotocol/clientInfo"] as? [String: Any])?["name"] as? String == "probe")
        #expect((meta["io.modelcontextprotocol/clientInfo"] as? [String: Any])?["version"] as? String == "2.1")
        // Declared, and declared as an object — "no capabilities" is a statement the server
        // can act on, whereas an absent field is silence it has to guess about.
        let capabilities = try #require(
            meta["io.modelcontextprotocol/clientCapabilities"] as? [String: Any])
        #expect(capabilities.isEmpty)
    }

    /// The version in the body is the one the server accepted, because that is what the header
    /// will carry. Two independently-derived values would eventually disagree, and the failure
    /// would be a `400` on every request with nothing obviously wrong.
    @Test("The version in _meta is the negotiated one, not the requested one")
    func metaCarriesNegotiatedVersion() async throws {
        let transport = RecordingBodyTransport(negotiated: "2026-07-28")
        let connection = MCPClientConnection(transport: transport)
        _ = try await connection.initialize(
            clientName: "probe", clientVersion: "1.0", protocolVersion: "2025-06-18")
        _ = try? await connection.listTools()

        let meta = try #require(requestMeta(of: await transport.lastRequest))
        #expect(meta["io.modelcontextprotocol/protocolVersion"] as? String == "2026-07-28")
    }

    /// A 2025-era server gets none of it. `_meta` on a request is how the stateless revision
    /// replaces the handshake; a server that performed a handshake has no use for it.
    @Test("A 2025-era request carries no protocol _meta")
    func earlierEraCarriesNoMeta() async throws {
        let transport = RecordingBodyTransport(negotiated: "2025-06-18")
        let connection = MCPClientConnection(transport: transport)
        _ = try await connection.initialize(clientName: "probe", clientVersion: "1.0")
        _ = try? await connection.listTools()

        let meta = requestMeta(of: await transport.lastRequest)
        #expect(meta?["io.modelcontextprotocol/protocolVersion"] == nil)
    }
}

/// Answers an initialize handshake and keeps the body of the last request it was sent.
private actor RecordingBodyTransport: MCPTransport {

    private let negotiated: String
    private var pending: [Data] = []
    private(set) var lastRequest: Data?

    init(negotiated: String) {
        self.negotiated = negotiated
    }


    func connect() async throws {}
    func disconnect() async throws {}

    func send(_ data: Data) async throws {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        // The handshake's own request is not what these tests are about.
        if object["method"] as? String != "initialize" {
            lastRequest = data
        }
        guard let id = object["id"] else { return }
        // Built in steps: a ternary between two heterogeneous dictionary literals defeats the
        // type checker, which reports it as an internal error rather than as the ambiguity it
        // is.
        let result: [String: Any]
        if object["method"] as? String == "initialize" {
            result = [
                "protocolVersion": negotiated,
                "capabilities": [String: Any](),
                "serverInfo": ["name": "stub", "version": "1.0.0"]
            ]
        } else {
            result = ["tools": [Any]()]
        }
        let response: [String: Any] = ["jsonrpc": "2.0", "id": id, "result": result]
        pending.append(try JSONSerialization.data(withJSONObject: response))
    }

    func receive() async throws -> Data {
        guard !pending.isEmpty else {
            throw MCPError.connectionFailed(reason: "nothing queued")
        }
        return pending.removeFirst()
    }
}

/// The `_meta` of a recorded request, parsed outside the actor that captured it.
///
/// A dictionary of `Any` is not `Sendable` and cannot leave an isolation boundary, so the
/// bytes cross and the parsing happens here.
private func requestMeta(of data: Data?) -> [String: Any]? {
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let params = object["params"] as? [String: Any] else {
        return nil
    }
    return params["_meta"] as? [String: Any]
}
