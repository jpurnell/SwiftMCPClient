import Testing
import Foundation
@testable import MCPClient

@Suite("MCPError")
struct MCPErrorTests {

    @Test("connectionFailed stores reason")
    func connectionFailedReason() {
        let error = MCPError.connectionFailed(reason: "refused")
        if case .connectionFailed(let reason) = error {
            #expect(reason == "refused")
        } else {
            Issue.record("Expected connectionFailed")
        }
    }

    @Test("requestFailed stores code, message, and data")
    func requestFailedCodeMessageData() {
        let data = AnyCodableValue.object(["detail": .string("extra info")])
        let error = MCPError.requestFailed(code: -32601, message: "Method not found", data: data)
        if case .requestFailed(let code, let message, let errorData) = error {
            #expect(code == -32601)
            #expect(message == "Method not found")
            #expect(errorData == data)
        } else {
            Issue.record("Expected requestFailed")
        }
    }

    @Test("requestFailed with nil data")
    func requestFailedNilData() {
        let error = MCPError.requestFailed(code: -32600, message: "Invalid request", data: nil)
        if case .requestFailed(let code, let message, let data) = error {
            #expect(code == -32600)
            #expect(message == "Invalid request")
            #expect(data == nil)
        } else {
            Issue.record("Expected requestFailed")
        }
    }

    @Test("timeout case exists")
    func timeoutCase() {
        let error = MCPError.timeout
        #expect(error == MCPError.timeout)
    }

    @Test("invalidResponse case exists")
    func invalidResponseCase() {
        let error = MCPError.invalidResponse
        #expect(error == MCPError.invalidResponse)
    }

    @Test("Different errors are not equal")
    func errorsNotEqual() {
        #expect(MCPError.timeout != MCPError.invalidResponse)
        #expect(MCPError.connectionFailed(reason: "a") != MCPError.connectionFailed(reason: "b"))
        #expect(MCPError.requestFailed(code: 1, message: "a", data: nil) != MCPError.requestFailed(code: 2, message: "a", data: nil))
    }

    @Test("Same errors are equal")
    func errorsEqual() {
        #expect(MCPError.timeout == MCPError.timeout)
        #expect(MCPError.invalidResponse == MCPError.invalidResponse)
        #expect(MCPError.connectionFailed(reason: "x") == MCPError.connectionFailed(reason: "x"))
        #expect(MCPError.requestFailed(code: -1, message: "y", data: nil) == MCPError.requestFailed(code: -1, message: "y", data: nil))
    }

    @Test("MCPError conforms to Error protocol")
    func conformsToError() {
        let error: any Error = MCPError.timeout
        #expect(error is MCPError)
    }

    @Test("processSpawnFailed stores reason")
    func processSpawnFailedReason() {
        let error = MCPError.processSpawnFailed(reason: "command not found")
        if case .processSpawnFailed(let reason) = error {
            #expect(reason == "command not found")
        } else {
            Issue.record("Expected processSpawnFailed")
        }
    }

    @Test("transportClosed case exists")
    func transportClosedCase() {
        let error = MCPError.transportClosed
        #expect(error == MCPError.transportClosed)
    }

    @Test("New error cases are not equal to existing cases")
    func newCasesNotEqualToExisting() {
        #expect(MCPError.transportClosed != MCPError.timeout)
        #expect(MCPError.transportClosed != MCPError.invalidResponse)
        #expect(MCPError.processSpawnFailed(reason: "x") != MCPError.connectionFailed(reason: "x"))
    }
}
