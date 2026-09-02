import Foundation
import MCP
import Logging

/// An actor that manages communication with an MCP server.
///
/// `MCPClientConnection` handles the full MCP protocol lifecycle: initialization,
/// tool discovery, and tool invocation. It uses a pluggable ``MCPTransport``
/// for the underlying communication — ``HTTPSSETransport`` for remote servers
/// or ``StdioTransport`` for local development.
///
/// ## Usage
///
/// ```swift
/// let transport = HTTPSSETransport(
///     url: URL(string: "https://my-mcp-server.example.com/sse")!
/// )
/// let client = MCPClientConnection(transport: transport)
///
/// // 1. Initialize the connection
/// let info = try await client.initialize(
///     clientName: "my-app",
///     clientVersion: "1.0.0"
/// )
/// print("Connected to \(info.serverInfo.name)")
///
/// // 2. Discover available tools
/// let tools = try await client.listTools()
/// for tool in tools {
///     print("  - \(tool.name): \(tool.description ?? "")")
/// }
///
/// // 3. Call a tool
/// let result = try await client.callTool(
///     name: "analyze_data",
///     arguments: ["input": .string("Hello, world!")]
/// )
/// // `content` holds MCPContent cases, not values with a `.text` property.
/// if case .text(let str, _) = result.content.first {
///     print(str)
/// } else {
///     print("No output")
/// }
/// ```
///
/// ## Notifications
///
/// After initialization, server-to-client notifications (progress updates,
/// log messages, list changes) are available via the ``notifications`` stream:
///
/// ```swift
/// func observe(client: MCPClientConnection) async {
/// for await notification in await client.notifications {
///     switch notification {
///     case .progress(let p):
///         print("Progress: \(p.progress)/\(p.total ?? 0)")
///     case .logMessage(let msg):
///         print("[\(msg.level)] \(msg.data)")
///     default:
///         break
///     }
/// }
/// }
/// ```
///
/// ## Thread Safety
///
/// `MCPClientConnection` is an `actor`, so all method calls are serialized.
/// Request IDs are auto-incremented and guaranteed unique within a connection.
public actor MCPClientConnection: MCPClientProtocol {
    private let transport: MCPTransport
    private let requestTimeout: Duration
    private var nextRequestID: Int = 1
    private var isConnected: Bool = false
    private var dispatcher: MCPMessageDispatcher?
    private var rootsHandler: (@Sendable () async -> [MCPRoot])?
    private var samplingHandler: SamplingHandler?

    /// Stream of server-to-client notifications.
    ///
    /// This stream becomes active after ``initialize(clientName:clientVersion:capabilities:protocolVersion:)``
    /// is called and the message dispatcher starts. It yields notifications for
    /// progress updates, log messages, and list changes from the server.
    public var notifications: AsyncStream<MCPNotification> {
        if let dispatcher {
            return dispatcher.notificationStream
        }
        // Return an empty stream if not initialized yet
        return AsyncStream { $0.finish() }
    }

    /// Creates a new MCP client connection with the given transport.
    ///
    /// The transport is not connected until ``initialize(clientName:clientVersion:capabilities:protocolVersion:)``
    /// is called.
    ///
    /// - Parameters:
    ///   - transport: The transport to use for communication.
    ///   - requestTimeout: Maximum time to wait for a response. Defaults to 30 seconds.
    public init(transport: MCPTransport, requestTimeout: Duration = .seconds(30)) {
        self.transport = transport
        self.requestTimeout = requestTimeout
    }

    /// Initialize the MCP connection, performing the protocol handshake.
    ///
    /// This method connects the transport (if not already connected), sends the
    /// MCP `initialize` request with the client's identity, waits for the server's
    /// response, then sends the required `notifications/initialized` notification.
    /// After the handshake, it starts the message dispatcher for bidirectional
    /// communication.
    ///
    /// This must be called before ``listTools()`` or ``callTool(name:arguments:)``.
    ///
    /// - Parameters:
    ///   - clientName: The name of this client application.
    ///   - clientVersion: The version of this client application.
    ///   - capabilities: The client capabilities to advertise. Defaults to an empty set.
    ///   - protocolVersion: The MCP protocol version to request. Defaults to `"2024-11-05"`.
    /// - Returns: The server's initialization result including capabilities.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport cannot connect.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server rejects the handshake.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func initialize(
        clientName: String,
        clientVersion: String,
        capabilities: ClientCapabilities = ClientCapabilities(),
        protocolVersion: String = "2024-11-05"
    ) async throws -> InitializeResult {
        if !isConnected {
            try await transport.connect()
            isConnected = true
        }

        do {
            // Encode client capabilities to AnyCodableValue
            let capsData = try JSONEncoder().encode(capabilities)
            let capsValue = try JSONDecoder().decode(AnyCodableValue.self, from: capsData)

            let params = AnyCodableValue.object([
                "protocolVersion": .string(protocolVersion),
                "capabilities": capsValue,
                "clientInfo": .object([
                    "name": .string(clientName),
                    "version": .string(clientVersion)
                ])
            ])

            // Initialize uses direct transport.receive() since the dispatcher
            // isn't running yet and no notifications can arrive before handshake.
            let response = try await sendRequestDirect(method: "initialize", params: params)
            let resultData = try JSONEncoder().encode(response)
            let initResult = try JSONDecoder().decode(InitializeResult.self, from: resultData)

            // The MCP spec says the server responds with the version it supports.
            // We accept any version — the protocol is designed to be forward-compatible
            // at the JSON-RPC level. Log but don't reject newer versions.

            // Told to the transport before anything else is sent. Spec 2025-06-18 requires
            // `MCP-Protocol-Version` on every request *after* initialization, and the
            // `notifications/initialized` below is the first of them. Most transports ignore
            // this; the ones that must echo the header cannot learn it any other way.
            await transport.didNegotiate(protocolVersion: initResult.protocolVersion)

            // Kept for the requests that follow. The stateless revision has no handshake to
            // carry identity, so each request states it — and the version stated is the one the
            // server *accepted*, because the transport puts that same value in the
            // `MCP-Protocol-Version` header and a server rejects the two disagreeing.
            self.negotiatedVersion = initResult.protocolVersion
            self.clientIdentity = ClientIdentity(name: clientName, version: clientVersion)

            // Send notifications/initialized per MCP spec (fire-and-forget, no response)
            let notification = JSONRPCNotification(method: "notifications/initialized")
            let notificationData = try JSONEncoder().encode(notification)
            try await transport.send(notificationData)

            // Start the message dispatcher for all subsequent communication
            let newDispatcher = MCPMessageDispatcher(transport: transport)
            await newDispatcher.start()
            self.dispatcher = newDispatcher

            return initResult
        } catch {
            // A failed handshake leaves the transport half-open. Release it before
            // rethrowing: a transport dropped while holding a live HTTP client trips
            // AsyncHTTPClient's shutdown-before-deinit precondition and crashes the
            // process in debug builds. Best-effort — the handshake error is the one
            // the caller needs to see.
            // silent: cleanup must not mask the original failure
            try? await transport.disconnect()
            isConnected = false
            throw error
        }
    }

    /// Discover available tools on the MCP server.
    ///
    /// Sends a `tools/list` request and decodes the response into an array
    /// of ``MCPTool`` definitions. Automatically paginates if the server
    /// returns a `nextCursor`. Returns an empty array if the server reports no tools.
    ///
    /// - Returns: An array of all tool definitions available on the server.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func listTools() async throws -> [MCPTool] {
        let tools: [MCPTool] = try await paginatedList(method: "tools/list", key: "tools")
        return rejectingMalformedHeaderAnnotations(tools)
    }

    /// Drops tools whose `x-mcp-header` annotations break the specification's rules.
    ///
    /// A conforming client **MUST** exclude such a tool from the result — and only that tool.
    /// Failing the whole listing would let one malformed definition deny a client every other
    /// tool the server offers, which is a poor trade for a rule about header names.
    ///
    /// The rules themselves belong to the shared SDK, which both this client and SwiftMCPServer
    /// read, so a definition one accepts is not one the other rejects.
    ///
    /// - Parameter tools: The tools as the server listed them.
    /// - Returns: The ones a client may use.
    private func rejectingMalformedHeaderAnnotations(_ tools: [MCPTool]) -> [MCPTool] {
        var kept: [MCPTool] = []
        var annotations: [String: [String: String]] = [:]

        for tool in tools {
            guard let schema = tool.inputSchema else {
                kept.append(tool)
                continue
            }
            do {
                let headers = try XMCPHeaderPolicy.headerNames(in: Self.schemaValue(schema))
                if !headers.isEmpty { annotations[tool.name] = headers }
                kept.append(tool)
            } catch {
                let logger = Logger(label: "MCPClient.MCPClientConnection")
                // logging: which tool was dropped and why, since it silently disappears
                logger.warning(
                    "excluding tool \(tool.name): invalid x-mcp-header annotation — \(error)")
            }
        }

        // The transport does the mirroring, next to the other headers it derives from the body;
        // only this layer ever sees the definitions that say which parameters to mirror.
        let installed = annotations
        Task { [transport] in await (transport as? StreamableHTTPTransport)?.useParameterHeaders(installed) }

        return kept
    }

    /// Carries a schema across into the shape the shared policy reads.
    private static func schemaValue(_ schema: AnyCodableValue) -> Value {
        // silent: a schema that will not round-trip carries no annotations to find, and the
        // policy's answer for "nothing here" is the same as for "nothing readable"
        guard let data = try? JSONEncoder().encode(schema),
              let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return .object([:])
        }
        return value
    }

    // MARK: - Tasks extension

    /// Reads a task's current state.
    ///
    /// - Parameter id: The task identifier the server issued.
    /// - Returns: The task as the server now sees it.
    /// - Throws: ``MCPError`` if the request failed, or if the server does not implement the
    ///   `io.modelcontextprotocol/tasks` extension.
    public func getTask(id: String) async throws -> MCPTask {
        let params = try Self.parameters(GetTask.Parameters(taskId: id))
        let response = try await sendRequest(method: GetTask.name, params: params)
        return try Self.task(from: response)
    }

    /// Supplies input to a task, or nudges one along.
    ///
    /// - Parameters:
    ///   - id: The task identifier.
    ///   - inputResponses: Answers to what the task asked for, keyed by request. Omitting them
    ///     is legitimate — an update with nothing to say is how a client nudges a task.
    /// - Returns: The task after the update.
    /// - Throws: ``MCPError``.
    @discardableResult
    public func updateTask(
        id: String,
        inputResponses: [String: InputResponse]? = nil
    ) async throws -> MCPTask {
        let params = try Self.parameters(
            UpdateTask.Parameters(taskId: id, inputResponses: inputResponses))
        let response = try await sendRequest(method: UpdateTask.name, params: params)
        return try Self.task(from: response)
    }

    /// Polls a task until it stops moving on its own.
    ///
    /// Stops on any terminal status **and** on `input_required`, because a task waiting for the
    /// client will not move until the client answers it — continuing to poll one is how a
    /// caller waits forever for something it was itself holding up.
    ///
    /// A failed task is *returned*, not thrown: "the work failed" is an answer, and the caller
    /// needs the status message that came with it. Only a transport or protocol failure throws.
    ///
    /// - Parameters:
    ///   - id: The task identifier.
    ///   - maximumPolls: How many times to ask before giving up. A bound, so a task that never
    ///     finishes ends the wait rather than the process.
    /// - Returns: The task in its last observed state.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the bound is reached, or
    ///   whatever the transport threw.
    public func awaitTask(id: String, maximumPolls: Int = 600) async throws -> MCPTask {
        for _ in 0..<max(maximumPolls, 1) {
            let task = try await getTask(id: id)
            if task.status.isTerminal || task.status == .inputRequired {
                return task
            }
            // The server's own preference, where it stated a usable one. Polling as fast as
            // the loop allows turns a long-running task into a denial of service against the
            // server running it.
            try await Task.sleep(for: Self.pollInterval(for: task))
        }

        throw MCPError.requestFailed(
            code: -32000,
            message: "task \(id) did not finish within \(maximumPolls) polls",
            data: nil)
    }

    /// How long to wait before polling a task again.
    ///
    /// A client-side decision over data the protocol carries: the SDK models what the server
    /// *said*, and how long to actually wait is this client's business. A stated interval of
    /// zero or less is replaced rather than obeyed, because honouring it would spin.
    static func pollInterval(for task: MCPTask) -> Duration {
        guard let stated = task.pollIntervalMs, stated > 0 else { return defaultPollInterval }
        return .milliseconds(stated)
    }

    /// How often to poll when the server states no preference.
    ///
    /// Polling as fast as a loop allows turns a long-running task into a denial of service
    /// against the server running it.
    static let defaultPollInterval: Duration = .milliseconds(1_000)

    /// Sends a request and returns whatever came back, interim results included.
    ///
    /// ``sendRequest(method:params:)`` refuses an interim result, because a caller that has not
    /// asked to answer questions must not receive one as though it were content. Multi
    /// Round-Trip Requests is the caller that *has* asked, so it needs the unrefused result.
    private func sendRequestAllowingInterim(
        method: String,
        params: AnyCodableValue?
    ) async throws -> AnyCodableValue {
        do {
            return try await sendRequest(method: method, params: params)
        } catch let error as MCPError {
            // The refusal carries the result it refused, which is the thing this caller wants.
            guard case .requestFailed(let code, _, let data) = error,
                  code == Self.interimResultCode,
                  let interim = data else {
                throw error
            }
            return interim
        }
    }

    /// Refuses a result that is not the final one.
    ///
    /// MCP 2026-07-28 tags every result: `complete` for content, `input_required` for a server
    /// that cannot finish until the client supplies something. Handing an interim result back
    /// as content is the failure the tag exists to prevent — the caller would read an empty
    /// payload as "the work is done" and act on it.
    ///
    /// **An absent tag is `complete`.** A server on an earlier revision omits the field
    /// entirely, and reading that as "unknown" would break every 2025-era server the moment
    /// this client started looking. `ResultType.resolving(_:)` is where that rule lives.
    ///
    /// Fulfilling an input request is Multi Round-Trip Requests, which this client does not do
    /// yet; until it does, an interim result is an error carrying the server's request, so a
    /// caller can see what was asked rather than an empty success.
    ///
    /// - Parameter result: The result as the server sent it.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the result is interim.
    private func refusingInterimResult(_ result: AnyCodableValue) throws -> AnyCodableValue {
        guard case .object(let fields) = result,
              case .string(let tag)? = fields["resultType"] else {
            // No tag at all: an earlier revision, and the specification says complete.
            return result
        }

        guard ResultType.resolving(ResultType(rawValue: tag)) == .complete else {
            throw MCPError.requestFailed(
                code: Self.interimResultCode,
                message: "the server needs input before it can finish this request",
                data: result)
        }
        return result
    }

    /// The code an interim result is reported under until MRTR can fulfil one.
    ///
    /// From the implementation-defined range, deliberately: this is not a protocol error the
    /// server sent, it is this client declining to pretend an interim result is an answer.
    static let interimResultCode = -32000

    /// Which shape of MCP a server speaks.
    ///
    /// Two eras, not five versions. `2025-03-26` through `2025-11-25` share one transport —
    /// handshake, sessions, a standalone `GET` stream, resumable streams — and `2026-07-28`
    /// shares none of it. Everything about talking to a server follows from which of the two it
    /// belongs to.
    public enum Era: Sendable, Hashable {
        /// `initialize` first, then a session. 2025-03-26 through 2025-11-25.
        case handshake
        /// No handshake; every request states its own version. 2026-07-28 onward.
        case stateless
    }

    /// What a refusal says about which era a server belongs to.
    ///
    /// The specification's procedure is to attempt a modern request and, on `400`, **inspect
    /// the body before falling back**. This is that inspection.
    ///
    /// The trap it exists to avoid: modern servers answer `400` for an unsupported version, a
    /// missing capability, or a header mismatch — all of which mean "you are talking to a
    /// modern server and got something wrong", not "this server is old". A client that read any
    /// `400` as an old server would downgrade and then send `initialize` to a server that
    /// removed the method.
    ///
    /// Implementation-defined codes (`-32000` to `-32019`) are deliberately *not* evidence.
    /// They are grandfathered for SDK use and both eras emit them, so treating one as a signal
    /// reads a coincidence as a fact.
    ///
    /// - Parameter code: The JSON-RPC error code the refusal carried, if it carried one.
    /// - Returns: The era the refusal implies.
    public static func era(forRefusalCode code: Int?) -> Era {
        guard let code, Self.statelessEraErrorCodes.contains(code) else { return .handshake }
        return .stateless
    }

    /// The errors only a server implementing 2026-07-28 produces.
    ///
    /// From the range the specification reserved for itself in that revision — which is why
    /// they are usable as an era signal at all, and why the implementation-defined range below
    /// them is not.
    private static let statelessEraErrorCodes: Set<Int> = [
        -32020, // HeaderMismatch
        -32021, // MissingRequiredClientCapability
        unsupportedProtocolVersionCode  // -32022
    ]

    /// Calls a tool, answering anything the server asks for along the way.
    ///
    /// Multi Round-Trip Requests replaced server-initiated requests in 2026-07-28. Rather than
    /// sending its own JSON-RPC request over a stream, a server returns an interim result
    /// naming what it needs, and the client **retries the original request** with the answers
    /// attached. The retry is the continuation — there is no "continue" method, which is what
    /// keeps the exchange stateless.
    ///
    /// - Parameters:
    ///   - name: The tool to call.
    ///   - arguments: Its arguments.
    ///   - maximumRounds: How many times to answer before giving up. A server that keeps asking
    ///     would otherwise loop a client indefinitely.
    ///   - fulfil: Answers the server's requests, keyed by the identifiers it used. Returning
    ///     nothing means "I cannot answer this", and ends the exchange rather than retrying
    ///     into the same gap.
    /// - Returns: The final result.
    /// - Throws: ``MCPError`` — including when the rounds are exhausted, or when the client
    ///   answered nothing.
    public func callToolFulfillingInput(
        name: String,
        arguments: [String: AnyCodableValue]?,
        maximumRounds: Int = 8,
        fulfil: ([String: InputRequest]) async -> [String: InputResponse]
    ) async throws -> AnyCodableValue {
        var params: [String: AnyCodableValue] = ["name": .string(name)]
        if let arguments { params["arguments"] = .object(arguments) }

        for _ in 0..<max(maximumRounds, 1) {
            let outcome = try await sendRequestAllowingInterim(
                method: "tools/call", params: .object(params))

            guard let interim = Self.interimResult(in: outcome) else {
                return outcome
            }

            let answers = await fulfil(interim.inputRequests ?? [:])
            guard !answers.isEmpty else {
                throw MCPError.requestFailed(
                    code: Self.interimResultCode,
                    message: "the server asked for input this client did not answer",
                    data: outcome)
            }

            // Answers keyed by the server's own identifiers, and its opaque state echoed back
            // untouched — the correspondence is the only thing tying an answer to its question,
            // and the state is how the server avoids redoing work it has already done.
            params["inputResponses"] = try Self.parameters(answers)
            if let requestState = interim.requestState {
                params["requestState"] = .string(requestState)
            }
        }

        throw MCPError.requestFailed(
            code: Self.interimResultCode,
            message: "the server kept asking for input after \(maximumRounds) rounds",
            data: nil)
    }

    /// Whether a result is a server asking for input rather than answering.
    ///
    /// Exposed because "the exchange finished" and "the exchange stopped" are different
    /// outcomes, and only this tells them apart.
    public static func isInterim(_ result: AnyCodableValue) -> Bool {
        interimResult(in: result) != nil
    }

    /// Reads an interim result, if that is what came back.
    private static func interimResult(in result: AnyCodableValue) -> InputRequiredResult? {
        guard case .object(let fields) = result,
              case .string(let tag)? = fields["resultType"],
              ResultType(rawValue: tag) == .inputRequired else {
            return nil
        }
        // silent: a payload tagged interim that will not decode is handled as "not interim",
        // and the caller receives it as an ordinary result to judge for itself
        guard let data = try? JSONEncoder().encode(result),
              let interim = try? JSONDecoder().decode(InputRequiredResult.self, from: data) else {
            return nil
        }
        return interim
    }

    /// Asks the server what it supports, before speaking to it.
    ///
    /// `server/discover` is the stateless revision's alternative to guessing a protocol version
    /// and learning from the rejection. Servers **MUST** implement it; clients **MAY** call it,
    /// and doing so is what turns version selection into a choice rather than a retry loop.
    ///
    /// - Returns: What the server supports, and who it says it is.
    /// - Throws: ``MCPError`` — including from a server too old to know the method, which is
    ///   itself an answer about which era it belongs to.
    public func discoverServer() async throws -> Discover.Result {
        let response = try await sendRequest(method: Discover.name, params: nil)
        let data = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(Discover.Result.self, from: data)
    }

    /// Opens the stream of change notifications this client asked for.
    ///
    /// 2026-07-28 replaced the standalone `GET` stream with `subscriptions/listen`: one
    /// long-lived POST whose response stream carries the notification types opted in to.
    /// Request-scoped messages — progress, logging — are **not** delivered here; they travel on
    /// the response stream of the request they relate to.
    ///
    /// - Parameter filter: What the client wants to hear about.
    /// - Returns: What the server agreed to send, which may be less. A server with no resources
    ///   to watch declines that subscription, and a client that assumed otherwise waits forever
    ///   for a notification nobody is going to send.
    /// - Throws: ``MCPError``.
    @discardableResult
    public func listen(for filter: SubscriptionFilter) async throws -> SubscriptionFilter {
        let params = try Self.parameters(SubscriptionsListen.Parameters(notifications: filter))
        let response = try await sendRequest(method: SubscriptionsListen.name, params: params)

        let data = try JSONEncoder().encode(response)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let granted = fields["notifications"] else {
            throw MCPError.requestFailed(
                code: -32602,
                message: "the server acknowledged no subscriptions",
                data: nil)
        }
        let grantedData = try JSONSerialization.data(withJSONObject: granted)
        return try JSONDecoder().decode(SubscriptionFilter.self, from: grantedData)
    }

    /// The revisions this client can speak, newest last.
    ///
    /// Ordered rather than a set: choosing between what both sides know requires knowing which
    /// is newer, and dated revisions sort lexicographically.
    static let supportedProtocolVersions = [
        "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25", "2026-07-28"
    ]

    /// The newest revision both this client and a server understand.
    ///
    /// Not the newest the *server* named — that may be one this client cannot write. Not this
    /// client's newest either, which would ignore what the server just said. The intersection,
    /// and the newest of it.
    ///
    /// - Parameter serverSupports: The versions the server named.
    /// - Returns: The version to speak, or `nil` when there is no overlap — in which case a
    ///   guess would produce a request the server refuses, and the refusal would read as a bug
    ///   here rather than an incompatibility.
    public static func bestMutualVersion(serverSupports: [String]) -> String? {
        Set(serverSupports).intersection(supportedProtocolVersions).max()
    }

    /// Begins a session with a server that has no handshake.
    ///
    /// MCP 2026-07-28 removed `initialize`: a client declares its protocol version on every
    /// request rather than agreeing one up front. There is nothing to negotiate here, so this
    /// connects the transport and records what every later request will state.
    ///
    /// A server that cannot speak the declared version refuses the *first request* with
    /// `-32022` and lists what it does support — see ``supportedVersions(from:)``. That is the
    /// only discovery a stateless client gets, which is why the error must be readable rather
    /// than merely thrown.
    ///
    /// - Parameters:
    ///   - protocolVersion: The revision to declare.
    ///   - clientName: This client's name, reported on every request.
    ///   - clientVersion: This client's version.
    /// - Throws: Whatever connecting the transport threw.
    public func beginStateless(
        protocolVersion: String,
        clientName: String,
        clientVersion: String
    ) async throws {
        try await transport.connect()
        await transport.didNegotiate(protocolVersion: protocolVersion)

        self.negotiatedVersion = protocolVersion
        self.clientIdentity = ClientIdentity(name: clientName, version: clientVersion)

        // The dispatcher is what routes responses to their requests; without a handshake there
        // is no other moment to start it.
        let newDispatcher = MCPMessageDispatcher(transport: transport)
        await newDispatcher.start()
        self.dispatcher = newDispatcher
    }

    /// The protocol versions a server named when refusing one.
    ///
    /// A stateless client has no handshake in which to discover what a server speaks, so a
    /// refusal is the discovery. The list travels in the error's `data`, and a client that
    /// cannot reach it can only guess again.
    ///
    /// - Parameter error: The error a request failed with.
    /// - Returns: The versions the server named, or empty when it named none — which is a
    ///   different thing from supporting none, and is left to the caller to tell apart.
    public static func supportedVersions(from error: MCPError) -> [String] {
        guard case .requestFailed(let code, _, let data) = error,
              code == unsupportedProtocolVersionCode,
              case .object(let fields)? = data,
              case .array(let supported)? = fields["supported"] else {
            return []
        }
        return supported.compactMap { value in
            if case .string(let version) = value { return version }
            return nil
        }
    }

    /// The code a server uses to refuse a protocol version, as renumbered by 2026-07-28.
    ///
    /// The revision moved the protocol's own errors into `-32020` and beyond, leaving
    /// `-32000`–`-32019` implementation-defined; this one was `-32004` in the draft.
    static let unsupportedProtocolVersionCode = -32022

    /// Who this client says it is, once initialization has established it.
    private struct ClientIdentity: Sendable {
        let name: String
        let version: String
    }

    /// The version the server accepted, if this connection has initialized.
    private var negotiatedVersion: String?

    /// What to report as `clientInfo`.
    private var clientIdentity: ClientIdentity?

    /// Attaches the protocol `_meta` that a stateless revision expects on every request.
    ///
    /// MCP 2026-07-28 removed the handshake: a request carries its own protocol version, the
    /// client's identity, and its capabilities, because there is no longer a session in which
    /// those were established once.
    ///
    /// The version here **must** be the one the transport puts in `MCP-Protocol-Version` — a
    /// server that finds them different answers `HeaderMismatch`. They come from the same
    /// stored value for that reason, rather than being derived twice.
    ///
    /// Earlier revisions get nothing: they performed a handshake, and `_meta` describing it
    /// again is noise a server has no rule for.
    ///
    /// - Parameter params: The request's parameters, if it has any.
    /// - Returns: The parameters with `_meta` attached, or unchanged.
    private func protocolMeta(attachedTo params: AnyCodableValue?) -> AnyCodableValue? {
        guard let version = negotiatedVersion,
              version >= StreamableHTTPSession.requestMetadataRevision else {
            return params
        }

        var meta: [String: AnyCodableValue] = [
            Metadata.Keys.protocolVersion: .string(version),
            // Empty rather than absent: the field is how a server learns what this client can
            // do, and omitting it says nothing rather than saying "nothing".
            Metadata.Keys.clientCapabilities: .object([:])
        ]
        if let clientIdentity {
            meta[Metadata.Keys.clientInfo] = .object([
                "name": .string(clientIdentity.name),
                "version": .string(clientIdentity.version)
            ])
        }

        // Merged into whatever the request already carries, never over it: `_meta` is
        // additional context, and a request whose parameters it replaced would be a different
        // request.
        guard case .object(var fields)? = params else {
            return .object(["_meta": .object(meta)])
        }
        fields["_meta"] = .object(meta)
        return .object(fields)
    }

    /// Carries a typed parameter value into the request encoding this connection speaks.
    private static func parameters(_ value: some Encodable) throws -> AnyCodableValue {
        try JSONDecoder().decode(AnyCodableValue.self, from: JSONEncoder().encode(value))
    }

    /// Reads the task out of a `tasks/get` or `tasks/update` result.
    private static func task(from response: AnyCodableValue) throws -> MCPTask {
        let data = try JSONEncoder().encode(response)
        guard let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let taskFields = fields["task"] else {
            throw MCPError.requestFailed(
                code: -32602,
                message: "the result carried no task",
                data: nil)
        }
        let taskData = try JSONSerialization.data(withJSONObject: taskFields)
        return try JSONDecoder().decode(MCPTask.self, from: taskData)
    }

    /// Send a ping to the MCP server and await the response.
    ///
    /// Sends a `ping` request per the MCP specification. The server must
    /// respond with an empty result object `{}`.
    ///
    /// - Returns: `true` if the server responded successfully.
    /// - Throws: ``MCPError/timeout`` if no response within the transport timeout.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport is disconnected.
    public func ping() async throws -> Bool {
        _ = try await sendRequest(method: "ping", params: nil)
        return true
    }

    /// Call a tool on the MCP server.
    ///
    /// Sends a `tools/call` request with the given tool name and arguments,
    /// then decodes the response into an ``MCPToolResult``. Check the result's
    /// ``MCPToolResult/isError`` property to determine if the tool execution
    /// itself reported a failure.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call (must match a name from ``listTools()``).
    ///   - arguments: The arguments to pass to the tool. Defaults to empty.
    /// - Returns: The tool's result containing one or more content blocks.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func callTool(name: String, arguments: [String: AnyCodableValue] = [:]) async throws -> MCPToolResult {
        try await callTool(name: name, arguments: arguments, progressToken: nil)
    }

    /// Call a tool on the MCP server with an optional progress token.
    ///
    /// When `progressToken` is provided, it is included as `_meta.progressToken`
    /// in the request, enabling the server to send progress notifications for
    /// this specific request.
    ///
    /// - Parameters:
    ///   - name: The name of the tool to call (must match a name from ``listTools()``).
    ///   - arguments: The arguments to pass to the tool. Defaults to empty.
    ///   - progressToken: Optional token for receiving progress notifications.
    /// - Returns: The tool's result containing one or more content blocks.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func callTool(
        name: String,
        arguments: [String: AnyCodableValue] = [:],
        progressToken: AnyCodableValue?
    ) async throws -> MCPToolResult {
        var paramsDict: [String: AnyCodableValue] = [
            "name": .string(name),
            "arguments": .object(arguments)
        ]
        if let progressToken {
            paramsDict["_meta"] = .object(["progressToken": progressToken])
        }
        let params = AnyCodableValue.object(paramsDict)

        let response = try await sendRequest(method: "tools/call", params: params)
        let resultData = try JSONEncoder().encode(response)
        let toolResult = try JSONDecoder().decode(MCPToolResult.self, from: resultData)
        return toolResult
    }

    // MARK: - Typed Notification Streams

    /// Stream of progress notifications only.
    ///
    /// Filters the underlying ``notifications`` stream, yielding only
    /// ``MCPProgressNotification`` values. The stream ends when the
    /// connection is disconnected.
    public var progressUpdates: AsyncStream<MCPProgressNotification> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .progress(let p) = notification {
                        continuation.yield(p)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Stream of log messages only.
    ///
    /// Filters the underlying ``notifications`` stream, yielding only
    /// ``MCPLogMessage`` values.
    public var logMessages: AsyncStream<MCPLogMessage> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .logMessage(let msg) = notification {
                        continuation.yield(msg)
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Stream of tool list change events.
    ///
    /// Yields `Void` each time the server notifies that its tool list has changed.
    public var toolListChanges: AsyncStream<Void> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .toolsListChanged = notification {
                        continuation.yield(())
                    }
                }
                continuation.finish()
            }
        }
    }

    /// Stream of resource update events.
    ///
    /// Yields the URI string of each resource that the server notifies has been updated.
    public var resourceUpdates: AsyncStream<String> {
        let source = notifications
        return AsyncStream { continuation in
            Task {
                for await notification in source {
                    if case .resourceUpdated(let uri) = notification {
                        continuation.yield(uri)
                    }
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Lifecycle

    /// Gracefully shut down the connection.
    ///
    /// Stops the message dispatcher (cancels the background read loop, fails
    /// any pending requests with ``MCPError/transportClosed``, finishes the
    /// notification stream), then disconnects the transport.
    ///
    /// After calling `disconnect()`, all subsequent method calls will throw.
    /// To reconnect, create a new ``MCPClientConnection`` instance.
    public func disconnect() async throws {
        if let dispatcher {
            await dispatcher.stop()
            self.dispatcher = nil
        }
        if isConnected {
            try await transport.disconnect()
            isConnected = false
        }
    }

    // MARK: - Resources

    /// Discover available resources on the MCP server.
    ///
    /// Sends a `resources/list` request and auto-paginates if the server
    /// returns a `nextCursor`. Returns an empty array if no resources are available.
    ///
    /// - Returns: An array of all resource definitions.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    /// - Throws: ``MCPError/invalidResponse`` if the response cannot be decoded.
    public func listResources() async throws -> [MCPResource] {
        try await paginatedList(method: "resources/list", key: "resources")
    }

    /// Discover available resource templates on the MCP server.
    ///
    /// Sends a `resources/templates/list` request and auto-paginates.
    ///
    /// - Returns: An array of all resource template definitions.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    public func listResourceTemplates() async throws -> [MCPResourceTemplate] {
        try await paginatedList(method: "resources/templates/list", key: "resourceTemplates")
    }

    /// Read the contents of a resource by URI.
    ///
    /// Sends a `resources/read` request. A single URI may return multiple
    /// sub-resources (e.g., a directory listing).
    ///
    /// - Parameter uri: The resource URI to read.
    /// - Returns: An array of resource contents (text or blob).
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the resource is not found.
    public func readResource(uri: String) async throws -> [MCPResourceContents] {
        let params = AnyCodableValue.object(["uri": .string(uri)])
        let response = try await sendRequest(method: "resources/read", params: params)

        guard case .object(let resultObj) = response,
              case .array(let contentValues) = resultObj["contents"] else {
            return []
        }

        let contentsData = try JSONEncoder().encode(AnyCodableValue.array(contentValues))
        return try JSONDecoder().decode([MCPResourceContents].self, from: contentsData)
    }

    /// Subscribe to updates for a specific resource.
    ///
    /// Sends a `resources/subscribe` request. After subscribing, the server
    /// may send `notifications/resources/updated` when the resource changes.
    ///
    /// - Parameter uri: The resource URI to subscribe to.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    public func subscribeResource(uri: String) async throws {
        let params = AnyCodableValue.object(["uri": .string(uri)])
        _ = try await sendRequest(method: "resources/subscribe", params: params)
    }

    /// Unsubscribe from updates for a specific resource.
    ///
    /// - Parameter uri: The resource URI to unsubscribe from.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    public func unsubscribeResource(uri: String) async throws {
        let params = AnyCodableValue.object(["uri": .string(uri)])
        _ = try await sendRequest(method: "resources/unsubscribe", params: params)
    }

    // MARK: - Prompts

    /// Discover available prompts on the MCP server.
    ///
    /// Sends a `prompts/list` request and auto-paginates if the server
    /// returns a `nextCursor`.
    ///
    /// - Returns: An array of all prompt definitions.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    public func listPrompts() async throws -> [MCPPrompt] {
        try await paginatedList(method: "prompts/list", key: "prompts")
    }

    /// Get an expanded prompt by name with optional arguments.
    ///
    /// Sends a `prompts/get` request with the given name and string-valued
    /// arguments. Returns the prompt expanded into a sequence of messages.
    ///
    /// - Parameters:
    ///   - name: The prompt name (must match a name from ``listPrompts()``).
    ///   - arguments: String-valued arguments to fill prompt template placeholders.
    /// - Returns: The prompt result containing messages.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    public func getPrompt(name: String, arguments: [String: String] = [:]) async throws -> MCPPromptResult {
        var paramsDict: [String: AnyCodableValue] = ["name": .string(name)]
        if !arguments.isEmpty {
            let argsObject = AnyCodableValue.object(
                arguments.mapValues { AnyCodableValue.string($0) }
            )
            paramsDict["arguments"] = argsObject
        }

        let response = try await sendRequest(method: "prompts/get", params: .object(paramsDict))
        let resultData = try JSONEncoder().encode(response)
        return try JSONDecoder().decode(MCPPromptResult.self, from: resultData)
    }

    // MARK: - Logging

    /// Set the minimum log level for server log messages.
    ///
    /// Sends a `logging/setLevel` request. After this call, the server should
    /// only send `notifications/message` at or above the specified severity.
    ///
    /// - Parameter level: The minimum log level to receive.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    public func setLogLevel(_ level: MCPLogLevel) async throws {
        let params = AnyCodableValue.object(["level": .string(level.rawValue)])
        _ = try await sendRequest(method: "logging/setLevel", params: params)
    }

    // MARK: - Cancellation

    /// Cancel an in-flight request by ID.
    ///
    /// Sends a `notifications/cancelled` notification to the server. The server
    /// SHOULD stop processing the request and NOT send a response.
    ///
    /// - Parameters:
    ///   - id: The request ID to cancel.
    ///   - reason: Optional human-readable reason for cancellation.
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport is not connected.
    public func cancelRequest(id: Int, reason: String? = nil) async throws {
        var paramsDict: [String: AnyCodableValue] = ["requestId": .integer(id)]
        if let reason {
            paramsDict["reason"] = .string(reason)
        }
        let notification = JSONRPCNotification(
            method: "notifications/cancelled",
            params: .object(paramsDict)
        )
        let data = try JSONEncoder().encode(notification)
        try await transport.send(data)
    }

    // MARK: - Completion

    /// Request autocompletion suggestions for a prompt or resource argument.
    ///
    /// Sends a `completion/complete` request to the server with a reference
    /// to what is being completed and the current argument value.
    ///
    /// - Parameters:
    ///   - ref: The prompt or resource being completed against.
    ///   - argumentName: The name of the argument being completed.
    ///   - argumentValue: The current partial value to match against.
    /// - Returns: The completion result with suggested values.
    /// - Throws: ``MCPError/requestFailed(code:message:data:)`` if the server returns an error.
    public func complete(
        ref: MCPCompletionRef,
        argumentName: String,
        argumentValue: String
    ) async throws -> MCPCompletionResult {
        let refValue: AnyCodableValue
        switch ref {
        case .prompt(let name):
            refValue = .object(["type": .string("ref/prompt"), "name": .string(name)])
        case .resource(let uri):
            refValue = .object(["type": .string("ref/resource"), "uri": .string(uri)])
        }

        let params = AnyCodableValue.object([
            "ref": refValue,
            "argument": .object([
                "name": .string(argumentName),
                "value": .string(argumentValue)
            ])
        ])

        let response = try await sendRequest(method: "completion/complete", params: params)

        guard case .object(let resultObj) = response,
              let completionValue = resultObj["completion"] else {
            throw MCPError.invalidResponse
        }

        let completionData = try JSONEncoder().encode(completionValue)
        return try JSONDecoder().decode(MCPCompletionResult.self, from: completionData)
    }

    // MARK: - Roots

    /// Register a handler that responds to `roots/list` requests from the server.
    ///
    /// When the server sends a `roots/list` request, the handler is called and
    /// its return value is sent back as the response.
    ///
    /// - Parameter handler: A closure that returns the current list of roots.
    public func setRootsHandler(_ handler: @Sendable @escaping () async -> [MCPRoot]) async {
        self.rootsHandler = handler
        await updateIncomingRequestHandler()
    }

    // MARK: - Sampling

    /// Register a handler that responds to `sampling/createMessage` requests from the server.
    ///
    /// When the server sends a `sampling/createMessage` request, the handler is called
    /// with the decoded ``MCPSamplingRequest``. The handler should invoke an LLM and return
    /// the result. For human-in-the-loop workflows, the handler can present the request
    /// to the user for review before proceeding.
    ///
    /// - Parameter handler: A closure that fulfills sampling requests.
    public func setSamplingHandler(_ handler: @escaping SamplingHandler) async {
        self.samplingHandler = handler
        await updateIncomingRequestHandler()
    }

    /// Notify the server that the client's roots have changed.
    ///
    /// Sends a `notifications/roots/list_changed` notification. The server
    /// should then re-request `roots/list`.
    ///
    /// - Throws: ``MCPError/connectionFailed(reason:)`` if the transport is not connected.
    public func notifyRootsChanged() async throws {
        let notification = JSONRPCNotification(method: "notifications/roots/list_changed")
        let data = try JSONEncoder().encode(notification)
        try await transport.send(data)
    }

    // MARK: - Private

    /// Updates the dispatcher's incoming request handler to route to both roots and sampling handlers.
    private func updateIncomingRequestHandler() async {
        guard let dispatcher else { return }
        let rootsHandler = self.rootsHandler
        let samplingHandler = self.samplingHandler

        await dispatcher.setIncomingRequestHandler { _, method, params in
            switch method {
            case "roots/list":
                guard let rootsHandler else { return nil }
                let roots = await rootsHandler()
                let rootValues = roots.map { root -> AnyCodableValue in
                    var obj: [String: AnyCodableValue] = ["uri": .string(root.uri)]
                    if let name = root.name {
                        obj["name"] = .string(name)
                    }
                    return .object(obj)
                }
                return .object(["roots": .array(rootValues)])

            case "sampling/createMessage":
                guard let samplingHandler, let params else { return nil }
                do {
                    let paramsData = try JSONEncoder().encode(params)
                    let request = try JSONDecoder().decode(MCPSamplingRequest.self, from: paramsData)
                    let result = try await samplingHandler(request)
                    let resultData = try JSONEncoder().encode(result)
                    return try JSONDecoder().decode(AnyCodableValue.self, from: resultData)
                } catch {
                    let logger = Logger(label: "MCPClient.MCPClientConnection")
                    // logging: error details needed for diagnostics
                    logger.warning("sampling/createMessage handler failed: \(error.localizedDescription)")
                    return nil
                }

            default:
                return nil
            }
        }
    }

    /// Generic paginated list request.
    private func paginatedList<T: Decodable>(method: String, key: String) async throws -> [T] {
        var allItems: [T] = []
        var cursor: String? = nil

        repeat {
            let params: AnyCodableValue? = cursor.map { .object(["cursor": .string($0)]) }
            let response = try await sendRequest(method: method, params: params)

            guard case .object(let resultObj) = response,
                  case .array(let itemValues) = resultObj[key] else {
                break
            }

            let itemsData = try JSONEncoder().encode(AnyCodableValue.array(itemValues))
            let items = try JSONDecoder().decode([T].self, from: itemsData)
            allItems.append(contentsOf: items)

            if case .string(let nextCursor) = resultObj["nextCursor"] {
                cursor = nextCursor
            } else {
                cursor = nil
            }
        } while cursor != nil

        return allItems
    }

    /// Sends a JSON-RPC request using the dispatcher (post-initialization).
    private func sendRequest(method: String, params: AnyCodableValue?) async throws -> AnyCodableValue {
        let requestID = nextRequestID
        nextRequestID += 1

        let request = JSONRPCRequest(
            id: requestID, method: method, params: protocolMeta(attachedTo: params))
        // The result is checked for an interim tag before it reaches a caller — see
        // `refusingInterimResult(_:)`.
        let requestData = try JSONEncoder().encode(request)

        try await transport.send(requestData)

        let response: JSONRPCResponse
        if let dispatcher {
            response = try await withThrowingTimeout(duration: requestTimeout) {
                try await dispatcher.waitForResponse(id: requestID)
            }
        } else {
            // Fallback for pre-initialization calls (shouldn't happen in normal use)
            let responseData = try await transport.receive()
            do {
                response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
            } catch {
                throw MCPError.invalidResponse
            }
        }

        if let rpcError = response.error {
            throw MCPError.requestFailed(code: rpcError.code, message: rpcError.message, data: rpcError.data)
        }

        guard let result = response.result else {
            throw MCPError.invalidResponse
        }

        return try refusingInterimResult(result)
    }

    /// Races an async operation against a timeout.
    private func withThrowingTimeout<T: Sendable>(
        duration: Duration,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: duration)
                throw MCPError.timeout
            }
            guard let result = try await group.next() else {
                throw MCPError.timeout
            }
            group.cancelAll()
            return result
        }
    }

    /// Sends a JSON-RPC request using direct transport.receive() (for initialization).
    private func sendRequestDirect(method: String, params: AnyCodableValue?) async throws -> AnyCodableValue {
        let requestID = nextRequestID
        nextRequestID += 1

        let request = JSONRPCRequest(id: requestID, method: method, params: params)
        let requestData = try JSONEncoder().encode(request)

        try await transport.send(requestData)
        let responseData = try await transport.receive()

        let response: JSONRPCResponse
        do {
            response = try JSONDecoder().decode(JSONRPCResponse.self, from: responseData)
        } catch {
            throw MCPError.invalidResponse
        }

        if let rpcError = response.error {
            throw MCPError.requestFailed(code: rpcError.code, message: rpcError.message, data: rpcError.data)
        }

        guard let result = response.result else {
            throw MCPError.invalidResponse
        }

        return result
    }
}
