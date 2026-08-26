import Foundation
import Testing

// MARK: - Non-failing conversions

extension String {
    /// The UTF-8 bytes of this string.
    ///
    /// `String.data(using: .utf8)` returns an `Optional` even though the conversion
    /// cannot fail — every `String` is representable in UTF-8 — which pushes callers
    /// toward a force unwrap. `Data(String.UTF8View)` is the non-failing spelling.
    var utf8Data: Data { Data(utf8) }
}

// MARK: - Test fixtures that must parse

/// Parses a URL literal used as a test fixture.
///
/// Reports a test failure instead of trapping when the literal is malformed, so a typo
/// in a fixture surfaces as a named failure rather than a crash that takes down the
/// whole suite.
///
/// - Parameters:
///   - string: The URL string to parse.
///   - sourceLocation: The call site, so a failure points at the test, not this helper.
/// - Returns: The parsed URL.
/// - Throws: If `string` is not a valid URL.
func requireURL(
    _ string: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> URL {
    // SECURITY: parses a literal written in the test source; nothing reaches this from a server.
    try #require(URL(string: string), "Malformed test URL: \(string)", sourceLocation: sourceLocation)
}

// MARK: - Loopback

/// Reads the port out of a redirect URI the loopback listener produced, checking that it is
/// on the loopback address before anything connects to it.
///
/// RFC 8252 §7.3 has the listener pick its own port, so the tests cannot hard-code one; the
/// host, on the other hand, is fixed, and a redirect URI naming any other host is a failure
/// rather than something to dial.
///
/// - Parameters:
///   - redirect: The redirect URI returned by `LoopbackRedirectListener.start()`.
///   - sourceLocation: The call site, so a failure points at the test, not this helper.
/// - Returns: The port the listener bound.
/// - Throws: If `redirect` does not parse or carries no port.
func loopbackPort(
    of redirect: String,
    sourceLocation: SourceLocation = #_sourceLocation
) throws -> Int {
    // SECURITY: the host is checked against the loopback literal on the next line.
    let url = try #require(URL(string: redirect), "Malformed redirect URI: \(redirect)", sourceLocation: sourceLocation)
    #expect(url.host() == "127.0.0.1", "redirect URI is not on loopback: \(redirect)", sourceLocation: sourceLocation)
    return try #require(url.port, "Redirect URI names no port: \(redirect)", sourceLocation: sourceLocation)
}

/// Builds a URL against the loopback listener.
///
/// The host is a literal rather than a parameter, so a test cannot accidentally send a
/// request off this machine.
///
/// - Parameters:
///   - port: The port the listener bound.
///   - target: Request target — a path, optionally followed by `?` and an already
///     percent-encoded query.
/// - Returns: The URL, or `nil` if `target` does not form one.
func loopbackURL(port: Int, target: String) -> URL? {
    var components = URLComponents()
    components.scheme = "http"
    components.host = "127.0.0.1"
    components.port = port

    let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
    guard let path = parts.first else { return nil }
    components.path = String(path)
    if parts.count > 1 {
        // Already encoded by the caller — `query` would encode the escapes a second time.
        components.percentEncodedQuery = String(parts[1])
    }
    return components.url
}
