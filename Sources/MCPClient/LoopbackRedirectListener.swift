#if canImport(Darwin)
import Foundation
import Darwin
import CLoopbackSocket

/// Why the loopback listener could not deliver a callback.
public enum LoopbackError: Error, Equatable, Sendable {

    /// The listener could not be started.
    case couldNotListen

    /// No callback arrived before the deadline.
    ///
    /// Expected rather than exceptional: a user who opens the authorization page and then
    /// closes the tab produces exactly this, and it must not leave a listener bound forever.
    case timedOut

    /// The request that arrived was not a readable HTTP request line.
    case malformedRequest
}

/// Receives an OAuth redirect on the loopback interface.
///
/// RFC 8252 §7.3 is why this exists. A native application has no web server to redirect to,
/// and the alternatives are worse: a custom URI scheme can be claimed by any other
/// application on the machine, and an out-of-band code asks the user to copy and paste a
/// credential. A loopback redirect can only be delivered by a process on this machine.
///
/// ## What it deliberately does
///
/// It binds **127.0.0.1**, never `0.0.0.0`. Binding every interface would let anything that
/// can route here deliver a callback — which is to say, hand this client an authorization
/// code of an attacker's choosing. The `state` check would catch that, but there is no
/// reason to accept the connection at all.
///
/// It takes a **kernel-assigned port**. RFC 8252 §7.3 requires an authorization server to
/// accept any port on the loopback address for exactly this reason: a fixed port can be
/// occupied, by a second copy of this application or by something that wants the callback.
///
/// It serves **one** callback and stops. The listener exists for the width of a single
/// authorization; leaving it bound afterwards leaves something accepting authorization codes
/// long after anyone is expecting one.
///
/// ## Why a socket rather than `Network.framework`
///
/// `NWListener` cannot express "this address, any free port". A required local endpoint needs
/// a concrete port; an ephemeral port means not stating the endpoint at all. Both were tried
/// and neither binds. Giving up either would mean surrendering the address restriction or the
/// assigned port, and both are load-bearing above. `bind` with port 0 does exactly this in one
/// call, and lives in `CLoopbackSocket` — composing a `sockaddr_in` is what C is for.
public actor LoopbackRedirectListener {

    private let path: String
    private var socketDescriptor: Int32?

    /// Creates a listener.
    ///
    /// - Parameter path: The redirect path to expect.
    public init(path: String = "/callback") {
        self.path = path
    }

    /// Binds a loopback port and reports the redirect URI to register with the provider.
    ///
    /// - Returns: The redirect URI, including the assigned port.
    /// - Throws: ``LoopbackError/couldNotListen``.
    public func start() throws -> String {
        let descriptor = clb_listen_on_loopback()
        guard descriptor >= 0 else { throw LoopbackError.couldNotListen }

        let port = clb_bound_port(descriptor)
        guard port != 0 else {
            close(descriptor)
            throw LoopbackError.couldNotListen
        }

        socketDescriptor = descriptor
        return "http://127.0.0.1:\(port)\(path)"
    }

    /// Waits for the redirect and returns it.
    ///
    /// - Parameter timeout: How long to wait. A user who abandons the page in their browser
    ///   produces a timeout rather than a hang.
    /// - Returns: The full callback URL, query intact.
    /// - Throws: ``LoopbackError``.
    public func awaitCallback(timeout: Duration = .seconds(300)) async throws -> URL {
        guard let descriptor = socketDescriptor else { throw LoopbackError.couldNotListen }
        let port = clb_bound_port(descriptor)
        guard port != 0 else { throw LoopbackError.couldNotListen }
        let expectedPath = path
        let deadline = ContinuousClock.now + timeout

        // Accepting blocks, so it runs off the actor and off the cooperative pool. The socket
        // is polled rather than blocked on outright, so the deadline stays checkable and a
        // cancelled task does not leave a thread parked in `accept` forever.
        return try await Task.detached(priority: .userInitiated) {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()

                guard let ready = Self.waitForConnection(descriptor, milliseconds: 100) else {
                    throw LoopbackError.couldNotListen
                }
                guard ready else { continue }

                let connection = accept(descriptor, nil, nil)
                guard connection >= 0 else { continue }
                defer { close(connection) }

                guard let request = Self.readRequest(connection),
                      let target = Self.requestTarget(request) else {
                    Self.respond(on: connection, body: Self.failurePage)
                    continue
                }

                // Composed rather than parsed: the scheme, host and port are this listener's
                // own, and only the path and query come from the request.
                var components = URLComponents()
                components.scheme = "http"
                components.host = "127.0.0.1"
                components.port = Int(port)
                // The target is already percent-encoded, so it goes into the `percentEncoded*`
                // properties. Assigning it to `path`/`query` would encode it a second time —
                // `User%20refused` becomes `User%2520refused`, and the caller reads a literal
                // `%20` in the provider's explanation.
                let split = target.split(separator: "?", maxSplits: 1)
                components.percentEncodedPath = String(split.first ?? "")
                components.percentEncodedQuery = split.count > 1 ? String(split[1]) : nil

                guard components.percentEncodedPath == expectedPath,
                      let url = components.url else {
                    // Browsers request `/favicon.ico` unprompted. Answering it must not end
                    // the wait, or the real callback arrives to a closed socket.
                    Self.respond(on: connection, body: Self.failurePage)
                    continue
                }

                Self.respond(on: connection, body: Self.successPage)
                return url
            }
            throw LoopbackError.timedOut
        }.value
    }

    /// Closes the listening socket.
    ///
    /// Idempotent, and worth calling on every exit path: an abandoned authorization must not
    /// leave something bound and accepting codes.
    public func stop() {
        if let descriptor = socketDescriptor {
            close(descriptor)
        }
        socketDescriptor = nil
    }

    // MARK: - Socket details

    /// Whether a connection is waiting, polled so the deadline stays checkable.
    ///
    /// - Returns: `true` if one is waiting, `false` if this poll expired, `nil` if the socket
    ///   is gone — which is what `stop()` looks like from in here.
    private static func waitForConnection(_ descriptor: Int32, milliseconds: Int32) -> Bool? {
        var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptorSet, 1, milliseconds)
        if result < 0 { return errno == EINTR ? false : nil }
        if result == 0 { return false }
        // A closed or errored socket also reports readable. Distinguishing it here is what
        // turns `stop()` into a clean exit rather than a spin on a dead descriptor.
        if descriptorSet.revents & Int16(POLLNVAL | POLLERR | POLLHUP) != 0 { return nil }
        return true
    }

    /// Reads the request, which for a redirect is small and arrives at once.
    private static func readRequest(_ connection: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: 8192)
        let count = read(connection, &buffer, buffer.count)
        guard count > 0 else { return nil }
        return String(decoding: buffer[0..<count], as: UTF8.self)
    }

    /// The request target from an HTTP request line, e.g. `/callback?code=…`.
    static func requestTarget(_ request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    /// Writes a minimal HTML response.
    private static func respond(on connection: Int32, body: String) {
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.utf8.count)\r
        Connection: close\r
        \r
        \(body)
        """
        var written = 0
        Array(response.utf8).withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            written = write(connection, base, pointer.count)
        }
        _ = written
    }

    /// Shown in the browser once the code has been received.
    ///
    /// Deliberately restates nothing about the callback. This page is rendered by whatever
    /// browser the user has, and the URL that produced it — authorization code and all — is
    /// already in that browser's history without any help from here.
    static let successPage = """
    <!doctype html><meta charset="utf-8"><title>Signed in</title>
    <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center">
    <h1>Signed in</h1><p>You can close this tab and return to MCP Explorer.</p>
    """

    /// Shown when the request was not the callback.
    static let failurePage = """
    <!doctype html><meta charset="utf-8"><title>Waiting</title>
    <body style="font-family:-apple-system,system-ui,sans-serif;padding:3rem;text-align:center">
    <h1>Nothing to see here</h1><p>This page is waiting for a sign-in redirect.</p>
    """
}
#endif
