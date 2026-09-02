import Foundation
import Testing
@testable import MCPClient

/// The `io.modelcontextprotocol/tasks` extension, from the client's side.
///
/// A task is how a server answers a request it cannot finish now: it returns a handle, the
/// client polls, and the work outlives the request that started it. MCP 2026-07-28 moved this
/// out of the core protocol into an official extension, redesigned around polling — `tasks/get`
/// and `tasks/update`, with no `tasks/list` and no blocking `tasks/result`.
///
/// The wire shapes here match SwiftMCPServer's SDK implementation deliberately, down to the
/// `MCPTask` name, which exists because `Task` is Swift concurrency's. Two implementations of
/// the same extension that disagree about field names interoperate with nobody.
@Suite("Tasks extension")
struct TasksExtensionTests {

    /// The identifier a client and server negotiate on. Getting this wrong means the extension
    /// silently never activates, which looks exactly like a server that does not offer it.
    @Test("The extension is identified as the specification names it")
    func extensionIdentifier() {
        #expect(TasksExtension.identifier == "io.modelcontextprotocol/tasks")
        #expect(TasksExtension.statusNotification == "notifications/tasks")
    }

    /// Terminal states are the ones a poller stops on. Treating `input_required` as terminal
    /// abandons a task that is waiting for the client; treating `failed` as non-terminal polls
    /// a dead task forever.
    @Test("Only finished states are terminal", arguments: [
        (TaskStatus.working, false),
        (TaskStatus.inputRequired, false),
        (TaskStatus.completed, true),
        (TaskStatus.failed, true),
        (TaskStatus.cancelled, true)
    ])
    func terminalStates(status: TaskStatus, isTerminal: Bool) {
        #expect(status.isTerminal == isTerminal)
    }

    /// `input_required` is spelled with an underscore on the wire. A Swift-cased value would
    /// decode as unknown and strand every task that needs input.
    @Test("Status values use their wire spelling")
    func wireSpelling() {
        #expect(TaskStatus.inputRequired.rawValue == "input_required")
        #expect(TaskStatus(rawValue: "input_required") == .inputRequired)
    }

    /// A task decodes from what a server actually sends, including the optional fields a
    /// server may omit.
    @Test("A task decodes from the server's representation")
    func decodesTask() throws {
        let json = Data("""
        {
          "taskId": "task-1",
          "status": "working",
          "createdAt": "2026-09-01T00:00:00Z",
          "lastUpdatedAt": "2026-09-01T00:00:05Z",
          "pollIntervalMs": 500
        }
        """.utf8)

        let task = try JSONDecoder().decode(MCPTask.self, from: json)

        #expect(task.taskId == "task-1")
        #expect(task.status == .working)
        #expect(task.pollIntervalMs == 500)
        #expect(task.statusMessage == nil)
        #expect(task.ttlMs == nil)
    }

    /// The interval a client should wait between polls, and what it does when the server
    /// offers no opinion. Polling as fast as the loop allows is how a client turns a
    /// long-running task into a denial of service against the server running it.
    @Test("A poll interval falls back to a sane default")
    func pollIntervalFallback() throws {
        let stated = MCPTask(
            taskId: "a", status: .working,
            createdAt: "t", lastUpdatedAt: "t", pollIntervalMs: 250)
        let silent = MCPTask(
            taskId: "b", status: .working, createdAt: "t", lastUpdatedAt: "t")

        #expect(stated.pollInterval == .milliseconds(250))
        #expect(silent.pollInterval == MCPTask.defaultPollInterval)
        #expect(silent.pollInterval > .zero)
    }

    /// A server that states a nonsensical interval does not get to set it. Zero or negative
    /// would spin.
    @Test("A nonsensical poll interval is replaced, not obeyed")
    func nonsensicalPollInterval() {
        let zero = MCPTask(
            taskId: "a", status: .working,
            createdAt: "t", lastUpdatedAt: "t", pollIntervalMs: 0)
        let negative = MCPTask(
            taskId: "b", status: .working,
            createdAt: "t", lastUpdatedAt: "t", pollIntervalMs: -1)

        #expect(zero.pollInterval == MCPTask.defaultPollInterval)
        #expect(negative.pollInterval == MCPTask.defaultPollInterval)
    }

    /// The request a client sends to poll. Its shape is the contract with the server.
    @Test("A tasks/get request names the task")
    func getRequestShape() throws {
        let params = TasksExtension.getParameters(taskId: "task-9")
        let encoded = try JSONEncoder().encode(params)
        let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(fields?["taskId"] as? String == "task-9")
    }

    /// `tasks/update` is how a client answers a task that asked for input — the extension's
    /// half of MRTR. Sending it without responses is legitimate: it is also how a client
    /// nudges a task it has nothing to add to.
    @Test("A tasks/update request carries the task and any responses")
    func updateRequestShape() throws {
        let params = TasksExtension.updateParameters(
            taskId: "task-9", inputResponses: ["prompt-1": .string("yes")])
        let encoded = try JSONEncoder().encode(params)
        let fields = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]

        #expect(fields?["taskId"] as? String == "task-9")
        #expect((fields?["inputResponses"] as? [String: Any])?["prompt-1"] as? String == "yes")
    }

    /// Method names, which are the other half of the contract.
    @Test("The method names match the extension")
    func methodNames() {
        #expect(TasksExtension.get == "tasks/get")
        #expect(TasksExtension.update == "tasks/update")
    }
}

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
