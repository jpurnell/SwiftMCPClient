import Foundation
import Testing
@testable import MCPExplorer

/// What the Explorer remembers between launches.
///
/// The server URL is the reason this exists. A stored OAuth session can only be restored
/// against a server, and until now the field was empty at every launch — so a session that
/// had survived the restart perfectly well had nothing to be restored *for*, and the user was
/// sent back to the browser anyway.
@Suite("Last server")
struct LastServerTests {

    /// The one that matters: what was typed on one launch is there on the next.
    @Test("A remembered server comes back on the next launch")
    func remembersAcrossLaunches() throws {
        let defaults = try freshDefaults()
        LastServer(defaults: defaults).remember("https://mcp.example.com")

        // A separate instance, as though the process had restarted.
        #expect(LastServer(defaults: defaults).recalled == "https://mcp.example.com")
    }

    /// First launch. Nothing remembered is `nil`, and the field stays empty rather than being
    /// filled with something the user never typed.
    @Test("Nothing remembered is nothing recalled")
    func firstLaunchRecallsNothing() throws {
        #expect(LastServer(defaults: try freshDefaults()).recalled == nil)
    }

    /// A cleared field must clear the memory too. Remembering a URL the user deliberately
    /// deleted would resurrect it at the next launch, which reads as the app ignoring them.
    @Test("Clearing the field forgets the server")
    func clearingForgets() throws {
        let defaults = try freshDefaults()
        let store = LastServer(defaults: defaults)

        store.remember("https://mcp.example.com")
        store.remember("")

        #expect(store.recalled == nil)
    }

    /// Whitespace is not a server. A field holding only spaces is an empty field to the user,
    /// and recalling it would put an unusable value in front of them at launch.
    @Test("A field of whitespace is not remembered")
    func whitespaceIsNotRemembered() throws {
        let defaults = try freshDefaults()
        let store = LastServer(defaults: defaults)

        store.remember("   ")

        #expect(store.recalled == nil)
    }

    /// Only the newest. This is one field, not a history, and a store that accumulated would
    /// be a record of every server a user had ever typed.
    @Test("The newest server replaces the last")
    func newestReplacesLast() throws {
        let defaults = try freshDefaults()
        let store = LastServer(defaults: defaults)

        store.remember("https://first.example.com")
        store.remember("https://second.example.com")

        #expect(store.recalled == "https://second.example.com")
    }
}

// MARK: - Helpers

/// A defaults domain of this test's own, so tests neither see each other's writes nor leave
/// anything in the domain the running application uses.
private func freshDefaults(
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> UserDefaults {
    let suite = "LastServerTests.\(UUID().uuidString)"
    return try #require(
        UserDefaults(suiteName: suite),
        "could not open a test defaults domain",
        sourceLocation: sourceLocation)
}
