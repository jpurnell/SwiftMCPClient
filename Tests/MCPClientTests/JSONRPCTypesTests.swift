import Testing
import Foundation
@testable import MCPClient

@Suite("JSONRPCTypes")
struct JSONRPCTypesTests {

    // MARK: - JSONRPCRequest

    @Test("Request serializes with jsonrpc 2.0")
    func requestHasVersion() throws {
        let request = JSONRPCRequest(id: 1, method: "tools/list")
        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
        #expect(json["jsonrpc"] == .string("2.0"))
    }

    @Test("Request serializes method and id")
    func requestMethodAndID() throws {
        let request = JSONRPCRequest(id: 7, method: "tools/call")
        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
        #expect(json["id"] == .integer(7))
        #expect(json["method"] == .string("tools/call"))
    }

    @Test("Request serializes params when present")
    func requestWithParams() throws {
        let params = AnyCodableValue.object(["name": .string("test_tool")])
        let request = JSONRPCRequest(id: 1, method: "tools/call", params: params)
        let data = try JSONEncoder().encode(request)
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
        #expect(json["params"] == params)
    }

    @Test("Request omits params when nil")
    func requestWithoutParams() throws {
        let request = JSONRPCRequest(id: 1, method: "tools/list", params: nil)
        let data = try JSONEncoder().encode(request)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        // params key should not appear in JSON when nil
        #expect(!jsonString.contains("params") || jsonString.contains("null"))
    }

    // MARK: - JSONRPCResponse

    @Test("Response deserializes successful result")
    func responseWithResult() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 1,
            "result": {"score": 75}
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.jsonrpc == "2.0")
        #expect(response.id == 1)
        #expect(response.result == .object(["score": .integer(75)]))
        #expect(response.error == nil)
    }

    @Test("Response deserializes error")
    func responseWithError() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 1,
            "error": {
                "code": -32601,
                "message": "Method not found"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.result == nil)
        #expect(response.error?.code == -32601)
        #expect(response.error?.message == "Method not found")
    }

    @Test("Response deserializes null id for notifications")
    func responseWithNullID() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": null,
            "result": "ok"
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.id == nil)
    }

    // MARK: - JSONRPCError

    @Test("Error has code and message")
    func errorProperties() {
        let error = JSONRPCError(code: -32600, message: "Invalid Request")
        #expect(error.code == -32600)
        #expect(error.message == "Invalid Request")
        #expect(error.data == nil)
    }

    @Test("Error with data")
    func errorWithData() {
        let error = JSONRPCError(code: -32602, message: "Invalid params", data: .string("details"))
        #expect(error.data == .string("details"))
    }

    @Test("Error is equatable")
    func errorEquatable() {
        let a = JSONRPCError(code: -32600, message: "Invalid Request")
        let b = JSONRPCError(code: -32600, message: "Invalid Request")
        let c = JSONRPCError(code: -32601, message: "Method not found")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - JSONRPCNotification

    @Test("Notification serializes with jsonrpc 2.0 and method")
    func notificationBasic() throws {
        let notification = JSONRPCNotification(method: "notifications/initialized")
        let data = try JSONEncoder().encode(notification)
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
        #expect(json["jsonrpc"] == .string("2.0"))
        #expect(json["method"] == .string("notifications/initialized"))
    }

    @Test("Notification has no id field")
    func notificationNoId() throws {
        let notification = JSONRPCNotification(method: "notifications/initialized")
        let data = try JSONEncoder().encode(notification)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        // The key "id" should not appear at all
        #expect(!jsonString.contains("\"id\""))
    }

    @Test("Notification omits params when nil")
    func notificationNoParams() throws {
        let notification = JSONRPCNotification(method: "notifications/initialized")
        let data = try JSONEncoder().encode(notification)
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        #expect(!jsonString.contains("\"params\""))
    }

    @Test("Notification includes params when provided")
    func notificationWithParams() throws {
        let params = AnyCodableValue.object(["key": .string("value")])
        let notification = JSONRPCNotification(method: "notifications/progress", params: params)
        let data = try JSONEncoder().encode(notification)
        let json = try JSONDecoder().decode([String: AnyCodableValue].self, from: data)
        #expect(json["params"] == params)
    }

    // MARK: - Edge Cases

    @Test("Response with error containing data object")
    func responseErrorWithDataObject() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 5,
            "error": {
                "code": -32602,
                "message": "Invalid params",
                "data": {"param": "iterations", "reason": "must be positive"}
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: data)
        #expect(response.error?.code == -32602)
        #expect(response.error?.data == .object([
            "param": .string("iterations"),
            "reason": .string("must be positive")
        ]))
    }
}
