import Foundation
@testable import MCPClient

/// A deterministic mock transport for testing MCPClientConnection.
///
/// Collects sent messages and returns pre-configured responses in order.
/// Fully Sendable — uses an actor for internal state.
actor MockTransportState {
    var responses: [Data] = []
    var sentMessages: [Data] = []
    var connected: Bool = false
    var connectError: MCPError?
    var responseIndex: Int = 0

    func enqueueResponse(_ data: Data) {
        responses.append(data)
    }

    func enqueueJSONResponse(_ json: String) {
        if let data = json.data(using: .utf8) {
            responses.append(data)
        }
    }

    func recordSent(_ data: Data) {
        sentMessages.append(data)
    }

    func nextResponse() throws -> Data {
        guard responseIndex < responses.count else {
            throw MCPError.invalidResponse
        }
        let response = responses[responseIndex]
        responseIndex += 1
        return response
    }

    func setConnected(_ value: Bool) {
        connected = value
    }

    func isConnected() -> Bool {
        connected
    }

    func setConnectError(_ error: MCPError?) {
        connectError = error
    }

    func getConnectError() -> MCPError? {
        connectError
    }

    func getSentMessages() -> [Data] {
        sentMessages
    }
}

/// Mock transport conforming to MCPTransport for deterministic testing.
public final class MockTransport: MCPTransport, @unchecked Sendable {
    let state: MockTransportState

    public init() {
        self.state = MockTransportState()
    }

    public func connect() async throws {
        if let error = await state.getConnectError() {
            throw error
        }
        await state.setConnected(true)
    }

    public func disconnect() async throws {
        await state.setConnected(false)
    }

    public func send(_ data: Data) async throws {
        guard await state.isConnected() else {
            throw MCPError.connectionFailed(reason: "Not connected")
        }
        await state.recordSent(data)
    }

    public func receive() async throws -> Data {
        guard await state.isConnected() else {
            throw MCPError.connectionFailed(reason: "Not connected")
        }
        return try await state.nextResponse()
    }

    // MARK: - Test Helpers

    func enqueueResponse(_ json: String) async {
        await state.enqueueJSONResponse(json)
    }

    func sentMessages() async -> [Data] {
        await state.getSentMessages()
    }

    func setConnectError(_ error: MCPError?) async {
        await state.setConnectError(error)
    }
}
