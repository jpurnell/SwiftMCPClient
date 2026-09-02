import Foundation

/// The `io.modelcontextprotocol/tasks` extension.
///
/// A task is how a server answers a request it cannot finish now: it returns a handle, and the
/// work outlives the request that started it. The client polls `tasks/get` until the status is
/// terminal, and answers a task that needs input with `tasks/update`.
///
/// MCP 2026-07-28 moved this out of the core protocol into an official extension and redesigned
/// it around polling — there is no `tasks/list`, and no blocking `tasks/result`. Being an
/// extension, it is negotiated: a server that does not advertise it is perfectly conformant,
/// and a client that assumes it is not.
///
/// ## Why these names
///
/// They match SwiftMCPServer's implementation of the same extension, down to ``MCPTask`` —
/// which is spelled that way because `Task` is Swift concurrency's. Two implementations of one
/// extension that disagree about field names interoperate with nobody.
public enum TasksExtension {

    /// What a client and server negotiate on.
    ///
    /// Getting this wrong means the extension silently never activates, which is
    /// indistinguishable from a server that does not offer it.
    public static let identifier = "io.modelcontextprotocol/tasks"

    /// The notification a server sends when a task's status changes.
    public static let statusNotification = "notifications/tasks"

    /// The method that reads a task's current state.
    public static let get = "tasks/get"

    /// The method that supplies input to a task, or nudges one.
    public static let update = "tasks/update"

    /// The parameters of a `tasks/get` request.
    public struct GetParameters: Codable, Hashable, Sendable {

        /// Which task.
        public var taskId: String

        /// Creates the parameters.
        public init(taskId: String) {
            self.taskId = taskId
        }
    }

    /// The parameters of a `tasks/update` request.
    ///
    /// `Equatable` rather than `Hashable`, following ``AnyCodableValue`` — an arbitrary JSON
    /// value has no stable hash, and claiming one here would be claiming it for the payload.
    public struct UpdateParameters: Codable, Equatable, Sendable {

        /// Which task.
        public var taskId: String

        /// Answers to the inputs the task asked for, keyed by request.
        ///
        /// Omitted when there is nothing to answer — an update with no responses is how a
        /// client nudges a task it has nothing to add to.
        public var inputResponses: [String: AnyCodableValue]?

        /// Creates the parameters.
        public init(taskId: String, inputResponses: [String: AnyCodableValue]? = nil) {
            self.taskId = taskId
            self.inputResponses = inputResponses
        }
    }

    /// The parameters for reading a task.
    public static func getParameters(taskId: String) -> GetParameters {
        GetParameters(taskId: taskId)
    }

    /// The parameters for updating a task.
    public static func updateParameters(
        taskId: String,
        inputResponses: [String: AnyCodableValue]? = nil
    ) -> UpdateParameters {
        UpdateParameters(taskId: taskId, inputResponses: inputResponses)
    }
}

/// Where a task has got to.
public enum TaskStatus: String, Hashable, Codable, Sendable {

    /// Running.
    case working

    /// Waiting for the client to supply something, via `tasks/update`.
    ///
    /// Spelled with an underscore on the wire. A Swift-cased value would decode as unknown and
    /// strand every task that needs input.
    case inputRequired = "input_required"

    /// Finished successfully.
    case completed

    /// Finished unsuccessfully.
    case failed

    /// Stopped before finishing.
    case cancelled

    /// Whether this state is one a poller stops on.
    ///
    /// The two mistakes this exists to prevent: treating `inputRequired` as terminal abandons a
    /// task that is waiting for the client, and treating `failed` as non-terminal polls a dead
    /// task forever.
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .working, .inputRequired: return false
        }
    }
}

/// A long-running piece of server work, and where it has got to.
///
/// Named `MCPTask` rather than `Task` because Swift concurrency has that name, and a type that
/// shadows it in every file that imports this module would be a poor trade for four characters.
public struct MCPTask: Hashable, Codable, Sendable {

    /// How often to poll when the server states no preference.
    ///
    /// Polling as fast as a loop allows is how a client turns a long-running task into a denial
    /// of service against the server running it.
    public static let defaultPollInterval: Duration = .milliseconds(1_000)

    /// The task's identifier, used with `tasks/get` and `tasks/update`.
    public let taskId: String

    /// Where it has got to.
    public var status: TaskStatus

    /// A human-readable note on the status, if the server offered one.
    public var statusMessage: String?

    /// When the task was created, as the server stated it.
    public let createdAt: String

    /// When its status last changed.
    public var lastUpdatedAt: String

    /// How long the server will keep the task after it finishes, in milliseconds.
    public var ttlMs: Int?

    /// How often the server would like to be polled, in milliseconds.
    public var pollIntervalMs: Int?

    /// How long to wait before polling again.
    ///
    /// The server's preference where it stated a usable one, and ``defaultPollInterval``
    /// otherwise. A stated interval of zero or less is replaced rather than obeyed: honouring
    /// it would spin.
    public var pollInterval: Duration {
        guard let pollIntervalMs, pollIntervalMs > 0 else { return Self.defaultPollInterval }
        return .milliseconds(pollIntervalMs)
    }

    /// Creates a task.
    public init(
        taskId: String,
        status: TaskStatus,
        statusMessage: String? = nil,
        createdAt: String,
        lastUpdatedAt: String,
        ttlMs: Int? = nil,
        pollIntervalMs: Int? = nil
    ) {
        self.taskId = taskId
        self.status = status
        self.statusMessage = statusMessage
        self.createdAt = createdAt
        self.lastUpdatedAt = lastUpdatedAt
        self.ttlMs = ttlMs
        self.pollIntervalMs = pollIntervalMs
    }
}
