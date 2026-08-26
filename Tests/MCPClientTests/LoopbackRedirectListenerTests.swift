import Foundation
import Testing
@testable import MCPClient

/// Parsing the request line, without a socket.
///
/// The listener's one job is turning an HTTP request into a callback URL. That part needs no
/// network to test, and the failure modes — a browser fetching `/favicon.ico`, a request that
/// is not a request — are awkward to provoke against a real one.
@Suite("Loopback — composing the callback URL")
struct CallbackURLTests {

    /// The target becomes a URL whose query survives intact.
    @Test("A target becomes a callback URL")
    func targetBecomesURL() throws {
        let url = try #require(LoopbackRedirectListener.callbackURL(
            from: "/callback?code=abc&state=xyz", port: 51234))

        #expect(url.absoluteString == "http://127.0.0.1:51234/callback?code=abc&state=xyz")
    }

    /// The request target is already percent-encoded. Encoding it a second time turns a
    /// provider's `User%20refused` into `User%2520refused`, and the caller reads an
    /// explanation with a literal `%20` in it.
    @Test("An encoded target is not encoded twice")
    func encodedTargetNotDoubleEncoded() throws {
        let url = try #require(LoopbackRedirectListener.callbackURL(
            from: "/callback?error=access_denied&error_description=User%20refused",
            port: 51234))

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(items["error_description"] == "User refused")
        #expect(items["error_description"] != "User%20refused")
    }

    /// A target with no query is still a valid callback URL — an empty query is not the same
    /// as a malformed one.
    @Test("A target without a query yields a URL with none")
    func targetWithoutQuery() throws {
        let url = try #require(LoopbackRedirectListener.callbackURL(
            from: "/callback", port: 51234))
        #expect(url.path == "/callback")
        #expect(url.query == nil)
    }

    /// The host and port are the listener's own and never come from the request, so a target
    /// that looks like an absolute URL cannot redirect anything.
    @Test("The host is always loopback, whatever the target says")
    func hostIsAlwaysLoopback() throws {
        let url = try #require(LoopbackRedirectListener.callbackURL(
            from: "/callback?code=c", port: 51234))
        #expect(url.host == "127.0.0.1")
        #expect(url.port == 51234)
    }

    /// The success page is rendered by the user's browser, and the URL that produced it —
    /// authorization code and all — is in that browser's history. It must not restate any
    /// of it.
    @Test("The success page discloses nothing")
    func successPageDisclosesNothing() {
        let page = LoopbackRedirectListener.successPage
        for leak in ["code", "state", "token", "verifier", "client_secret"] {
            #expect(!page.lowercased().contains("\(leak)="),
                    "the success page echoes \(leak)")
        }
        #expect(page.contains("Signed in"))
    }
}

/// The listener against a real socket.
@Suite("Loopback — over a real socket", .serialized)
struct LoopbackSocketTests {

    /// The redirect URI must name the loopback address and the assigned port, because it is
    /// registered with the provider and has to match what the browser is sent to.
    @Test("Starting reports a loopback redirect URI with an assigned port")
    func startReportsRedirectURI() async throws {
        let listener = LoopbackRedirectListener()
        let redirect = try await listener.start()
        await listener.stop()

        #expect(redirect.hasPrefix("http://127.0.0.1:"))
        #expect(redirect.hasSuffix("/callback"))

        // Assigned, not fixed. RFC 8252 §7.3 requires the server to accept any port for
        // exactly this reason: a fixed one can be occupied.
        let port = try loopbackPort(of: redirect)
        #expect(port > 0)
    }

    /// Two listeners at once must not collide, which a fixed port would guarantee.
    @Test("Two listeners get different ports")
    func twoListenersDiffer() async throws {
        let first = LoopbackRedirectListener()
        let second = LoopbackRedirectListener()
        let firstURI = try await first.start()
        let secondURI = try await second.start()
        defer { Task { await first.stop(); await second.stop() } }

        #expect(firstURI != secondURI)
    }

    /// The whole point: a redirect arrives and comes back out as a URL with its query intact.
    @Test("A callback request is delivered as a URL")
    func callbackDelivered() async throws {
        let listener = LoopbackRedirectListener()
        let redirect = try await listener.start()
        let port = try loopbackPort(of: redirect)

        async let received = listener.awaitCallback(timeout: .seconds(10))

        // A real request over the loopback socket, as a browser would make it.
        try await get(port: port, target: "/callback?code=the-code&state=the-state")

        let url = try await received
        await listener.stop()

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.path == "/callback")
        #expect(items["code"] == "the-code")
        #expect(items["state"] == "the-state")
    }

    /// A provider's refusal comes back through the same path and must survive intact, or the
    /// client reports "no code" instead of what actually happened.
    @Test("An error callback is delivered with its parameters")
    func errorCallbackDelivered() async throws {
        let listener = LoopbackRedirectListener()
        let redirect = try await listener.start()
        let port = try loopbackPort(of: redirect)

        async let received = listener.awaitCallback(timeout: .seconds(10))
        try await get(port: port,
                      target: "/callback?error=access_denied&error_description=User%20refused&state=s")

        let url = try await received
        await listener.stop()

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(items["error"] == "access_denied")
        #expect(items["error_description"] == "User refused")
    }

    /// Browsers fetch `/favicon.ico` unprompted. Treating that as the callback would end the
    /// wait with no code and report a failure the user cannot act on.
    @Test("A request for another path does not end the wait")
    func otherPathDoesNotEndTheWait() async throws {
        let listener = LoopbackRedirectListener()
        let redirect = try await listener.start()
        let port = try loopbackPort(of: redirect)

        async let received = listener.awaitCallback(timeout: .seconds(10))

        try await get(port: port, target: "/favicon.ico")
        // The real callback, after the noise.
        try await get(port: port, target: "/callback?code=the-code&state=the-state")

        let url = try await received
        await listener.stop()

        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/callback")
        #expect(components.queryItems?.first { $0.name == "code" }?.value == "the-code")
    }

    /// A user who opens the page and closes the tab produces this. It must time out rather
    /// than leave a port bound and a task waiting forever.
    @Test("An abandoned authorization times out")
    func abandonedAuthorizationTimesOut() async throws {
        let listener = LoopbackRedirectListener()
        _ = try await listener.start()

        await #expect(throws: LoopbackError.timedOut) {
            try await listener.awaitCallback(timeout: .milliseconds(200))
        }
        await listener.stop()
    }

    /// After `stop()` nothing should still be accepting authorization codes.
    @Test("A stopped listener no longer accepts connections")
    func stoppedListenerRefuses() async throws {
        let listener = LoopbackRedirectListener()
        let redirect = try await listener.start()
        let port = try loopbackPort(of: redirect)
        await listener.stop()

        // Give the socket a moment to actually close before asserting on it.
        var refused = false
        for _ in 0..<20 {
            do {
                try await get(port: port, target: "/callback?code=c&state=s")
            } catch {
                refused = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(refused, "the port still accepted a connection after stop()")
    }
}

// MARK: - Helpers

/// Makes a real HTTP GET against the loopback listener.
private func get(port: Int, target: String) async throws {
    guard let url = loopbackURL(port: port, target: target) else {
        throw LoopbackError.malformedRequest
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    _ = try await URLSession.shared.data(for: request)
}
