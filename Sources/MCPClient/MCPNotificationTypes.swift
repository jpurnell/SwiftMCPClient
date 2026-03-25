import Foundation

/// Log severity levels per RFC 5424 (syslog), ordered from least to most severe.
///
/// Used with ``MCPClientConnection/setLogLevel(_:)`` to control the minimum
/// severity of log messages received from the server.
public enum MCPLogLevel: String, Codable, Sendable, Equatable {
    case debug
    case info
    case notice
    case warning
    case error
    case critical
    case alert
    case emergency
}

extension MCPLogLevel: Comparable {
    private var severity: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .notice: return 2
        case .warning: return 3
        case .error: return 4
        case .critical: return 5
        case .alert: return 6
        case .emergency: return 7
        }
    }

    public static func < (lhs: MCPLogLevel, rhs: MCPLogLevel) -> Bool {
        lhs.severity < rhs.severity
    }
}

/// A log message received from an MCP server via `notifications/message`.
///
/// Log messages carry a severity level, an optional logger name, and
/// arbitrary data (string, object, or any JSON value).
public struct MCPLogMessage: Sendable, Equatable {
    /// The severity level of this message.
    public let level: MCPLogLevel

    /// The name of the logger that produced this message.
    public let logger: String?

    /// The log data — can be a string, object, or any JSON-serializable value.
    public let data: AnyCodableValue

    /// Creates a new log message.
    ///
    /// - Parameters:
    ///   - level: The severity level.
    ///   - logger: Optional logger name.
    ///   - data: The log data.
    public init(level: MCPLogLevel, logger: String?, data: AnyCodableValue) {
        self.level = level
        self.logger = logger
        self.data = data
    }
}

/// A progress update received from an MCP server via `notifications/progress`.
///
/// Progress notifications reference the token that was included in the
/// original request's `_meta.progressToken` field.
public struct MCPProgressNotification: Sendable, Equatable {
    /// The token matching the original request.
    public let progressToken: AnyCodableValue

    /// Current progress value (must increase monotonically).
    public let progress: Double

    /// Total progress value, if known.
    public let total: Double?

    /// Creates a new progress notification.
    ///
    /// - Parameters:
    ///   - progressToken: The token from the original request.
    ///   - progress: Current progress value.
    ///   - total: Optional total progress value.
    public init(progressToken: AnyCodableValue, progress: Double, total: Double?) {
        self.progressToken = progressToken
        self.progress = progress
        self.total = total
    }
}

/// A server-to-client notification received from an MCP server.
///
/// Access the notification stream via ``MCPClientConnection/notifications``.
///
/// ## Notification Types
///
/// - ``progress(_:)`` — Progress update for a request with a progress token
/// - ``logMessage(_:)`` — Server log message
/// - ``resourcesListChanged`` — The server's resource catalog changed
/// - ``resourceUpdated(uri:)`` — A subscribed resource was updated
/// - ``promptsListChanged`` — The server's prompt catalog changed
/// - ``toolsListChanged`` — The server's tool catalog changed
public enum MCPNotification: Sendable {
    /// Progress update for an in-flight request.
    case progress(MCPProgressNotification)

    /// A log message from the server.
    case logMessage(MCPLogMessage)

    /// The server's available resource list changed.
    case resourcesListChanged

    /// A subscribed resource was updated.
    case resourceUpdated(uri: String)

    /// The server's available prompt list changed.
    case promptsListChanged

    /// The server's available tool list changed.
    case toolsListChanged

    /// Parse a notification from a JSON-RPC method and params.
    ///
    /// Returns `nil` if the method is not a recognized notification.
    ///
    /// - Parameters:
    ///   - method: The JSON-RPC notification method name.
    ///   - params: The notification params, if any.
    /// - Returns: The parsed notification, or `nil`.
    static func parse(method: String, params: AnyCodableValue?) -> MCPNotification? {
        switch method {
        case "notifications/progress":
            guard case .object(let obj) = params,
                  let token = obj["progressToken"],
                  let progressValue = obj["progress"]?.doubleValue else {
                return nil
            }
            let total = obj["total"]?.doubleValue
            return .progress(MCPProgressNotification(progressToken: token, progress: progressValue, total: total))

        case "notifications/message":
            guard case .object(let obj) = params,
                  case .string(let levelStr) = obj["level"],
                  let level = MCPLogLevel(rawValue: levelStr),
                  let data = obj["data"] else {
                return nil
            }
            let logger: String?
            if case .string(let l) = obj["logger"] {
                logger = l
            } else {
                logger = nil
            }
            return .logMessage(MCPLogMessage(level: level, logger: logger, data: data))

        case "notifications/resources/list_changed":
            return .resourcesListChanged

        case "notifications/resources/updated":
            guard case .object(let obj) = params,
                  case .string(let uri) = obj["uri"] else {
                return nil
            }
            return .resourceUpdated(uri: uri)

        case "notifications/prompts/list_changed":
            return .promptsListChanged

        case "notifications/tools/list_changed":
            return .toolsListChanged

        default:
            return nil
        }
    }
}

// MARK: - AnyCodableValue helpers

extension AnyCodableValue {
    /// Extract a Double from number or integer values.
    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .integer(let i): return Double(i)
        default: return nil
        }
    }
}
