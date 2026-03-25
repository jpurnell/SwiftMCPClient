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

    @Test("requestFailed stores code and message")
    func requestFailedCodeMessage() {
        let error = MCPError.requestFailed(code: -32601, message: "Method not found")
        if case .requestFailed(let code, let message) = error {
            #expect(code == -32601)
            #expect(message == "Method not found")
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
        #expect(MCPError.requestFailed(code: 1, message: "a") != MCPError.requestFailed(code: 2, message: "a"))
    }

    @Test("Same errors are equal")
    func errorsEqual() {
        #expect(MCPError.timeout == MCPError.timeout)
        #expect(MCPError.invalidResponse == MCPError.invalidResponse)
        #expect(MCPError.connectionFailed(reason: "x") == MCPError.connectionFailed(reason: "x"))
        #expect(MCPError.requestFailed(code: -1, message: "y") == MCPError.requestFailed(code: -1, message: "y"))
    }

    @Test("MCPError conforms to Error protocol")
    func conformsToError() {
        let error: any Error = MCPError.timeout
        #expect(error is MCPError)
    }
}
