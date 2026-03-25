import Testing
import Foundation
@testable import MCPClient

@Suite("MCPNotificationTypes")
struct MCPNotificationTypesTests {

    // MARK: - MCPLogLevel

    @Test("Log levels have correct raw values")
    func logLevelRawValues() {
        #expect(MCPLogLevel.debug.rawValue == "debug")
        #expect(MCPLogLevel.info.rawValue == "info")
        #expect(MCPLogLevel.notice.rawValue == "notice")
        #expect(MCPLogLevel.warning.rawValue == "warning")
        #expect(MCPLogLevel.error.rawValue == "error")
        #expect(MCPLogLevel.critical.rawValue == "critical")
        #expect(MCPLogLevel.alert.rawValue == "alert")
        #expect(MCPLogLevel.emergency.rawValue == "emergency")
    }

    @Test("Log levels are comparable in severity order")
    func logLevelComparable() {
        #expect(MCPLogLevel.debug < MCPLogLevel.info)
        #expect(MCPLogLevel.info < MCPLogLevel.notice)
        #expect(MCPLogLevel.notice < MCPLogLevel.warning)
        #expect(MCPLogLevel.warning < MCPLogLevel.error)
        #expect(MCPLogLevel.error < MCPLogLevel.critical)
        #expect(MCPLogLevel.critical < MCPLogLevel.alert)
        #expect(MCPLogLevel.alert < MCPLogLevel.emergency)
    }

    @Test("Log levels round-trip through JSON")
    func logLevelRoundTrip() throws {
        let data = try JSONEncoder().encode(MCPLogLevel.warning)
        let decoded = try JSONDecoder().decode(MCPLogLevel.self, from: data)
        #expect(decoded == .warning)
    }

    // MARK: - MCPLogMessage

    @Test("LogMessage initializes with all fields")
    func logMessageAllFields() {
        let msg = MCPLogMessage(level: .error, logger: "database", data: .string("Connection failed"))
        #expect(msg.level == .error)
        #expect(msg.logger == "database")
        #expect(msg.data == .string("Connection failed"))
    }

    @Test("LogMessage without logger")
    func logMessageNoLogger() {
        let msg = MCPLogMessage(level: .info, logger: nil, data: .string("Started"))
        #expect(msg.logger == nil)
    }

    @Test("LogMessage with object data")
    func logMessageObjectData() {
        let data = AnyCodableValue.object(["error": .string("timeout"), "code": .integer(504)])
        let msg = MCPLogMessage(level: .warning, logger: "http", data: data)
        if case .object(let obj) = msg.data {
            #expect(obj["error"] == .string("timeout"))
        } else {
            Issue.record("Expected object data")
        }
    }

    @Test("LogMessage is equatable")
    func logMessageEquatable() {
        let a = MCPLogMessage(level: .info, logger: "app", data: .string("hi"))
        let b = MCPLogMessage(level: .info, logger: "app", data: .string("hi"))
        let c = MCPLogMessage(level: .error, logger: "app", data: .string("hi"))
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MCPProgressNotification

    @Test("ProgressNotification with string token")
    func progressStringToken() {
        let p = MCPProgressNotification(progressToken: .string("tok-1"), progress: 50, total: 100)
        #expect(p.progressToken == .string("tok-1"))
        #expect(p.progress == 50)
        #expect(p.total == 100)
    }

    @Test("ProgressNotification with integer token")
    func progressIntToken() {
        let p = MCPProgressNotification(progressToken: .integer(42), progress: 75, total: nil)
        #expect(p.progressToken == .integer(42))
        #expect(p.total == nil)
    }

    @Test("ProgressNotification is equatable")
    func progressEquatable() {
        let a = MCPProgressNotification(progressToken: .string("a"), progress: 1, total: 10)
        let b = MCPProgressNotification(progressToken: .string("a"), progress: 1, total: 10)
        let c = MCPProgressNotification(progressToken: .string("a"), progress: 2, total: 10)
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - MCPNotification enum

    @Test("MCPNotification progress case")
    func notificationProgress() {
        let p = MCPProgressNotification(progressToken: .string("t"), progress: 1, total: nil)
        let n = MCPNotification.progress(p)
        if case .progress(let inner) = n {
            #expect(inner.progress == 1)
        } else {
            Issue.record("Expected progress case")
        }
    }

    @Test("MCPNotification logMessage case")
    func notificationLog() {
        let msg = MCPLogMessage(level: .debug, logger: nil, data: .string("test"))
        let n = MCPNotification.logMessage(msg)
        if case .logMessage(let inner) = n {
            #expect(inner.level == .debug)
        } else {
            Issue.record("Expected logMessage case")
        }
    }

    @Test("MCPNotification resourcesListChanged case")
    func notificationResourcesChanged() {
        let n = MCPNotification.resourcesListChanged
        if case .resourcesListChanged = n {
            // pass
        } else {
            Issue.record("Expected resourcesListChanged")
        }
    }

    @Test("MCPNotification resourceUpdated case")
    func notificationResourceUpdated() {
        let n = MCPNotification.resourceUpdated(uri: "file:///a.txt")
        if case .resourceUpdated(let uri) = n {
            #expect(uri == "file:///a.txt")
        } else {
            Issue.record("Expected resourceUpdated")
        }
    }

    @Test("MCPNotification promptsListChanged case")
    func notificationPromptsChanged() {
        let n = MCPNotification.promptsListChanged
        if case .promptsListChanged = n {
            // pass
        } else {
            Issue.record("Expected promptsListChanged")
        }
    }

    @Test("MCPNotification toolsListChanged case")
    func notificationToolsChanged() {
        let n = MCPNotification.toolsListChanged
        if case .toolsListChanged = n {
            // pass
        } else {
            Issue.record("Expected toolsListChanged")
        }
    }

    // MARK: - MCPNotification.parse

    @Test("Parses progress notification from JSON-RPC")
    func parseProgress() throws {
        let json: [String: AnyCodableValue] = [
            "method": .string("notifications/progress"),
            "params": .object([
                "progressToken": .string("tok-1"),
                "progress": .number(50),
                "total": .number(100)
            ])
        ]
        let notification = MCPNotification.parse(method: "notifications/progress", params: json["params"])
        #expect(notification != nil)
        if case .progress(let p) = notification {
            #expect(p.progressToken == .string("tok-1"))
            #expect(p.progress == 50)
            #expect(p.total == 100)
        }
    }

    @Test("Parses progress notification with integer token and no total")
    func parseProgressIntToken() throws {
        let notification = MCPNotification.parse(
            method: "notifications/progress",
            params: .object([
                "progressToken": .integer(7),
                "progress": .number(3)
            ])
        )
        if case .progress(let p) = notification {
            #expect(p.progressToken == .integer(7))
            #expect(p.total == nil)
        } else {
            Issue.record("Expected progress")
        }
    }

    @Test("Parses log message notification")
    func parseLogMessage() throws {
        let notification = MCPNotification.parse(
            method: "notifications/message",
            params: .object([
                "level": .string("error"),
                "logger": .string("db"),
                "data": .string("Connection lost")
            ])
        )
        if case .logMessage(let msg) = notification {
            #expect(msg.level == .error)
            #expect(msg.logger == "db")
            #expect(msg.data == .string("Connection lost"))
        } else {
            Issue.record("Expected logMessage")
        }
    }

    @Test("Parses log message without logger")
    func parseLogNoLogger() throws {
        let notification = MCPNotification.parse(
            method: "notifications/message",
            params: .object([
                "level": .string("info"),
                "data": .object(["key": .string("val")])
            ])
        )
        if case .logMessage(let msg) = notification {
            #expect(msg.logger == nil)
        } else {
            Issue.record("Expected logMessage")
        }
    }

    @Test("Parses resources list changed")
    func parseResourcesListChanged() {
        let n = MCPNotification.parse(method: "notifications/resources/list_changed", params: nil)
        if case .resourcesListChanged = n {
            // pass
        } else {
            Issue.record("Expected resourcesListChanged")
        }
    }

    @Test("Parses resource updated")
    func parseResourceUpdated() {
        let n = MCPNotification.parse(
            method: "notifications/resources/updated",
            params: .object(["uri": .string("file:///x")])
        )
        if case .resourceUpdated(let uri) = n {
            #expect(uri == "file:///x")
        } else {
            Issue.record("Expected resourceUpdated")
        }
    }

    @Test("Parses prompts list changed")
    func parsePromptsListChanged() {
        let n = MCPNotification.parse(method: "notifications/prompts/list_changed", params: nil)
        if case .promptsListChanged = n {
            // pass
        } else {
            Issue.record("Expected promptsListChanged")
        }
    }

    @Test("Parses tools list changed")
    func parseToolsListChanged() {
        let n = MCPNotification.parse(method: "notifications/tools/list_changed", params: nil)
        if case .toolsListChanged = n {
            // pass
        } else {
            Issue.record("Expected toolsListChanged")
        }
    }

    @Test("Returns nil for unknown notification method")
    func parseUnknown() {
        let n = MCPNotification.parse(method: "notifications/unknown", params: nil)
        #expect(n == nil)
    }
}
