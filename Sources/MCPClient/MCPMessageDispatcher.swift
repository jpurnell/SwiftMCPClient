import Foundation

/// Classifies an incoming JSON-RPC message by inspecting its fields.
///
/// - Response: has `id` and either `result` or `error` (no `method`)
/// - Notification: has `method` but no `id`
/// - Request: has both `id` and `method` (server-to-client request like `roots/list`)
enum IncomingMessage: Sendable {
    case response(JSONRPCResponse)
    case notification(method: String, params: AnyCodableValue?)
    case request(id: Int, method: String, params: AnyCodableValue?)

    /// Parse raw data into a classified incoming message.
    static func parse(_ data: Data) -> IncomingMessage? {
        guard let json = try? JSONDecoder().decode([String: AnyCodableValue].self, from: data) else {
            return nil
        }

        let hasID: Bool
        let idValue: Int?
        if case .integer(let i) = json["id"] {
            hasID = true
            idValue = i
        } else if case .number(let d) = json["id"] {
            hasID = true
            idValue = Int(d)
        } else {
            hasID = false
            idValue = nil
        }

        let method: String?
        if case .string(let m) = json["method"] {
            method = m
        } else {
            method = nil
        }

        // Response: has id, no method (has result or error)
        if hasID && method == nil {
            if let response = try? JSONDecoder().decode(JSONRPCResponse.self, from: data) {
                return .response(response)
            }
            return nil
        }

        // Request from server: has both id and method
        if let id = idValue, let m = method {
            return .request(id: id, method: m, params: json["params"])
        }

        // Notification: has method but no id
        if let m = method, !hasID {
            return .notification(method: m, params: json["params"])
        }

        return nil
    }
}

/// Routes incoming transport messages to the appropriate handler.
///
/// The dispatcher runs a background read loop that consumes all messages from
/// the transport and routes them:
/// - **Responses** (have `id`, no `method`) → matched to pending request continuations
/// - **Notifications** (have `method`, no `id`) → pushed to the notification AsyncStream
/// - **Incoming requests** (have both `id` and `method`) → passed to the incoming request handler
///
/// Responses that arrive before a continuation is registered are buffered and
/// delivered immediately when ``waitForResponse(id:)`` is called.
actor MCPMessageDispatcher {
    private let transport: MCPTransport
    private var pendingRequests: [Int: CheckedContinuation<JSONRPCResponse, Error>] = [:]
    private var bufferedResponses: [Int: JSONRPCResponse] = [:]
    private var transportError: Error?
    private var notificationContinuation: AsyncStream<MCPNotification>.Continuation?
    private var incomingRequestHandler: (@Sendable (Int, String, AnyCodableValue?) async -> AnyCodableValue?)?
    private var readTask: Task<Void, Never>?

    /// The notification stream. Created once and shared.
    let notificationStream: AsyncStream<MCPNotification>

    init(transport: MCPTransport) {
        self.transport = transport
        var continuation: AsyncStream<MCPNotification>.Continuation!
        self.notificationStream = AsyncStream { continuation = $0 }
        self.notificationContinuation = continuation
    }

    /// Start the background read loop.
    func start() {
        guard readTask == nil else { return }
        readTask = Task { [weak self] in
            await self?.readLoop()
        }
    }

    /// Stop the read loop and fail all pending requests.
    func stop() {
        readTask?.cancel()
        readTask = nil
        notificationContinuation?.finish()
        notificationContinuation = nil

        let pending = pendingRequests
        pendingRequests.removeAll()
        bufferedResponses.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.transportClosed)
        }
    }

    /// Register a handler for incoming server-to-client requests (e.g., `roots/list`).
    func setIncomingRequestHandler(_ handler: @Sendable @escaping (Int, String, AnyCodableValue?) async -> AnyCodableValue?) {
        self.incomingRequestHandler = handler
    }

    /// Wait for a response matching the given request ID.
    ///
    /// If the response already arrived (buffered), returns immediately.
    /// Otherwise, registers a continuation for the read loop to resume.
    func waitForResponse(id: Int) async throws -> JSONRPCResponse {
        // Check buffer first — response may have arrived before we asked
        if let buffered = bufferedResponses.removeValue(forKey: id) {
            return buffered
        }

        // If transport already failed, throw immediately
        if let error = transportError {
            throw error
        }

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation
        }
    }

    // MARK: - Private

    private func readLoop() async {
        while !Task.isCancelled {
            let data: Data
            do {
                data = try await transport.receive()
            } catch {
                transportError = error
                let pending = pendingRequests
                pendingRequests.removeAll()
                for (_, continuation) in pending {
                    continuation.resume(throwing: error)
                }
                notificationContinuation?.finish()
                notificationContinuation = nil
                return
            }

            guard let message = IncomingMessage.parse(data) else {
                continue
            }

            switch message {
            case .response(let response):
                guard let id = response.id else { continue }
                if let continuation = pendingRequests.removeValue(forKey: id) {
                    continuation.resume(returning: response)
                } else {
                    // Buffer for later retrieval
                    bufferedResponses[id] = response
                }

            case .notification(let method, let params):
                if let notification = MCPNotification.parse(method: method, params: params) {
                    notificationContinuation?.yield(notification)
                }

            case .request(let id, let method, let params):
                if let handler = incomingRequestHandler {
                    let transport = self.transport
                    Task {
                        let result = await handler(id, method, params)
                        let response: [String: AnyCodableValue] = [
                            "jsonrpc": .string("2.0"),
                            "id": .integer(id),
                            "result": result ?? .object([:])
                        ]
                        if let responseData = try? JSONEncoder().encode(response) {
                            try? await transport.send(responseData)
                        }
                    }
                }
            }
        }
    }
}
