import Foundation
import Testing
import SwiftOAuthClient
@testable import MCPClient
#if canImport(AppKit)
import AppKit
#endif

/// The OAuth behaviour that cannot be faked, against the server it was built for.
///
/// Everything else in this suite runs against stubs, deliberately — a test that needs a live
/// provider is a test that does not run. But three things here have no stub worth trusting:
/// whether a real token endpoint honours a refresh-token grant, whether a real server rejects
/// a token the way the retry path assumes, and how long any of it lasts. Those are
/// measurements, and the design records assumptions about all three.
///
/// **Opt in explicitly:**
///
/// ```
/// MCP_LIVE_APOLLO=1 swift test --filter LiveApolloTests
/// ```
///
/// The filter is the **type** name, not the `@Suite` display name — SwiftPM matches test
/// identifiers, so `--filter "Live — Apollo"` selects nothing and reports it as "No matching
/// test cases were run", which reads exactly like a suite that is skipping correctly.
///
/// Skipped otherwise, including by the quality gate. It needs a browser the first time, so it
/// cannot run unattended, and it signs in against a real account.
///
/// ## What it costs
///
/// **No credits.** Apollo meters its enrichment tools; `initialize` and `tools/list` are
/// metadata, and nothing here calls a tool. (Recorded in the 2026-08-26 survey, which measured
/// the credit delta directly.)
///
/// **One dynamic client registration**, the first time only — the accumulation this work
/// exists to stop. Every browser sign-in leaves another behind at the server, so run it once
/// and let the stored registration do the rest.
///
/// **One refresh-token rotation** per forced-refresh run, if Apollo rotates. Worst case if
/// something goes wrong mid-rotation is signing in again.
@Suite("Live — Apollo", .serialized, .enabled(if: LiveApollo.isEnabled))
struct LiveApolloTests {

    /// Restores a stored session, or signs in once if there is nothing to restore.
    ///
    /// The first run of this on a machine that has `credentials.enc` but no
    /// `registrations.enc` is the migration path for accounts that predate the registration
    /// store: half stored, so `resume` must decline rather than throw, and the sign-in that
    /// follows must leave both halves behind. Every later run must restore in silence.
    @Test("A session restores, or signs in once and then restores")
    func restoresOrSignsIn() async throws {
        let session = try MCPOAuthSession.persistent()
        let server = try LiveApollo.serverURL()

        let restored = try await session.resume(server: server)
        if restored {
            LiveApollo.report("resumed a stored session — no browser")
        } else {
            LiveApollo.report("nothing to resume; signing in (a browser will open)")
            try await session.signIn(server: server, clientName: "SwiftMCPClient live check") { url in
                #if canImport(AppKit)
                NSWorkspace.shared.open(url)
                #endif
            }
        }

        #expect(await session.isSignedIn)

        // The measurement the whole design is sized against, and currently a guess.
        let credential = try #require(await LiveApollo.credential(of: session, server: server))
        LiveApollo.report("access token has \(Int(credential.accessExpiry.timeIntervalSinceNow / 60)) minutes left")
        LiveApollo.report("refresh expiry: \(credential.refreshExpiry.map { "\($0)" } ?? "not stated")")

        // Two stored timestamps, not a wall clock. "Expires after it was issued" is the
        // property worth asserting, and comparing the expiry to *now* would make the check
        // depend on how long the sign-in above took.
        #expect(credential.accessExpiry > credential.rotatedAt,
                "the server issued a token that expires before it was issued")
    }

    /// A forced refresh reaches a real token endpoint and comes back with something new.
    ///
    /// This is what `refreshedAccessToken()` was upstreamed for, and it is also the only way
    /// to exercise a refresh without waiting out an access token. It answers a second question
    /// on the way: whether Apollo rotates refresh tokens at all, which decides whether the
    /// rotation hazards the client code guards against apply here.
    @Test("A forced refresh issues a new token")
    func forcedRefreshIssuesNewToken() async throws {
        let session = try MCPOAuthSession.persistent()
        let server = try LiveApollo.serverURL()
        guard try await session.resume(server: server) else {
            Issue.record("no stored session; run the restore test first")
            return
        }

        let before = try #require(await LiveApollo.credential(of: session, server: server))
        let refreshed = try #require(try await session.authorizationHeader(forcingRefresh: true))
        let after = try #require(await LiveApollo.credential(of: session, server: server))

        #expect(refreshed == "Bearer \(after.accessToken)")
        #expect(after.accessToken != before.accessToken, "the provider returned the same token")

        let rotated = after.refreshToken != before.refreshToken
        LiveApollo.report("refresh token \(rotated ? "ROTATED" : "did not rotate")")
        LiveApollo.report("new access token has \(Int(after.accessExpiry.timeIntervalSinceNow / 60)) minutes left")

        // The refreshed token has to work, or "refreshed" means nothing observable.
        try await LiveApollo.withConnection(session: session, server: server) { connection in
            let tools = try await connection.listTools()
            LiveApollo.report("listed \(tools.count) tools with the refreshed token")
            #expect(!tools.isEmpty)
        }
    }

    /// The retry path, end to end, against a server that really does refuse.
    ///
    /// The provider hands out a deliberately invalid token until it is asked with
    /// `forcingRefresh`, at which point it returns the good one. Apollo rejects the first, and
    /// the transport must recover without the caller seeing anything.
    ///
    /// Deliberately does **not** force a real refresh on the retry: the mechanism under test
    /// is the retry, the refresh has its own test above, and spending a rotation to prove the
    /// same point twice is a rotation wasted.
    @Test("A refused request is retried and succeeds")
    func refusedRequestRecovers() async throws {
        let session = try MCPOAuthSession.persistent()
        let server = try LiveApollo.serverURL()
        guard try await session.resume(server: server) else {
            Issue.record("no stored session; run the restore test first")
            return
        }

        let attempts = AttemptLog()
        let transport = StreamableHTTPTransport(
            url: server,
            authorization: { forcing in
                await attempts.record(forcing)
                guard forcing else { return "Bearer deliberately-invalid-token" }
                return try await session.authorizationHeader()
            })

        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(60))
        do {
            _ = try await connection.initialize(clientName: "SwiftMCPClient live check", clientVersion: "1.0.0")
            let tools = try await connection.listTools()
            LiveApollo.report("recovered from a refusal and listed \(tools.count) tools")
            #expect(!tools.isEmpty)
        } catch {
            // Not swallowed: a failure here is the finding. If Apollo answers a bad token with
            // something other than 401, the retry never triggers and this is how we learn.
            Issue.record("did not recover from a refusal: \(error)")
        }
        // Disconnected on both paths — `HTTPClient` traps in `deinit` if it is not shut down,
        // which would take the suite down rather than fail this test.
        try? await connection.disconnect()

        let flags = await attempts.flags
        LiveApollo.report("provider called \(flags.count) times, forcing: \(flags)")
        #expect(flags.count >= 2, "the refused request was never retried — did the server answer 401?")
        #expect(flags.first == false)
        #expect(flags.dropFirst().first == true)
    }
}

// MARK: - Live support

/// Shared pieces for the live checks.
enum LiveApollo {

    /// Whether the live suite should run at all.
    ///
    /// Opt-in by environment rather than by a commented-out test, so the normal suite and the
    /// quality gate never reach a browser or an account.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["MCP_LIVE_APOLLO"] != nil
    }

    /// The server under test, overridable for someone pointing this at their own.
    static func serverURL() throws -> URL {
        let string = ProcessInfo.processInfo.environment["MCP_LIVE_SERVER"] ?? "https://mcp.apollo.io/mcp"
        // SECURITY: an operator-supplied URL from the environment of a test they opted into.
        return try #require(URL(string: string), "MCP_LIVE_SERVER is not a URL: \(string)")
    }

    /// Prints a measurement.
    ///
    /// These are findings, not assertions — how long a token lasts and whether a provider
    /// rotates are facts to record, and a passing test that quietly knew them would be worth
    /// less than the run that printed them.
    static func report(_ message: String) {
        FileHandle.standardError.write(Data("    live: \(message)\n".utf8))
    }

    /// The credential currently on file for a server.
    static func credential(of session: MCPOAuthSession, server: URL) async -> StoredCredential? {
        let identifier = server.host() ?? "mcp"
        let storage = try? EncryptedFileClientStorage(
            url: try applicationSupport().appending(path: "credentials.enc"),
            key: try CredentialStoreKey().loadOrCreate())
        return try? await storage?.credential(for: ConnectionID(
            tenant: "local", provider: identifier, account: server.absoluteString))
    }

    /// Where the running application keeps its state.
    static func applicationSupport() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true).appending(path: "MCPExplorer")
    }

    /// Runs a body against a connected client, and disconnects on every path.
    static func withConnection(
        session: MCPOAuthSession,
        server: URL,
        _ body: (MCPClientConnection) async throws -> Void
    ) async throws {
        let transport = StreamableHTTPTransport(
            url: server,
            authorization: { [session] forcing in
                try await session.authorizationHeader(forcingRefresh: forcing)
            })
        let connection = MCPClientConnection(transport: transport, requestTimeout: .seconds(60))
        _ = try await connection.initialize(clientName: "SwiftMCPClient live check", clientVersion: "1.0.0")
        do {
            try await body(connection)
            try? await connection.disconnect()
        } catch {
            try? await connection.disconnect()
            throw error
        }
    }
}

/// Records whether each provider call was asked to force a refresh.
private actor AttemptLog {
    private(set) var flags: [Bool] = []
    func record(_ forcing: Bool) { flags.append(forcing) }
}
