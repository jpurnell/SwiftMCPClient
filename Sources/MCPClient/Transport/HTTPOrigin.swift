import Foundation

/// The origin of an HTTP URL: how two are compared, and how one is named.
///
/// A transport is configured with one URL, and that URL's origin — scheme, host and port — is
/// the only place it has been told it may send anything. Twice a server gets to suggest
/// somewhere else: the legacy `endpoint` event, and the `Location` of a redirect. Both are
/// resolved as URL references, so both can name another host outright, and both are held to
/// the configured origin by the one function here rather than by a comparison written twice.
///
/// The other half is what may be *said* about a URL. An error message and a log line outlive
/// the request and are read by people the request was never meant for, so a URL reaches them
/// only through ``description(of:)`` or ``redacted(_:)``.
enum HTTPOrigin {

    /// What a server-supplied reference came to, measured against the configured URL.
    enum Resolution: Sendable, Equatable {
        /// On the configured origin. The URL is absolute and has no fragment.
        case sameOrigin(URL)
        /// It brings userinfo of its own. Refused even on the right host: nothing needs it,
        /// and `good.example@evil.test` is how a URL is made to read as one host and reach
        /// another.
        case carriesUserinfo(origin: String)
        /// On another origin — another scheme, host or port, or no HTTP origin at all.
        case otherOrigin(origin: String)
        /// Not something a URL could be made from.
        case notAURL
    }

    /// Resolves a reference a server supplied, and says whether it stays on the configured
    /// origin.
    ///
    /// The reference is resolved as RFC 3986 says, so it is not necessarily a path: an
    /// absolute URL replaces the whole origin, and so does `//host/path`. What it resolves to
    /// is then compared with `configured`:
    ///
    /// - **Same scheme, host and effective port.** Compared as parsed components, never as
    ///   string prefixes; scheme and host case-insensitively; a port left out is the scheme's
    ///   default. `http` where `https` was configured is a different origin — and so is the
    ///   reverse, because an origin is not "at least as secure as".
    /// - **No userinfo of its own.** Userinfo the configured URL already carried is kept by a
    ///   relative reference and is the caller's own; anything else is refused.
    /// - **No fragment.** Dropped, not refused: it is never sent in a request.
    ///
    /// A relative reference cannot fail the first of these — `..` stops at the root of the
    /// origin — so a server that sends a path, as almost all do, sees no difference.
    ///
    /// - Parameters:
    ///   - reference: The value as the server sent it: an `endpoint` event's data, or a
    ///     `Location` header.
    ///   - base: The URL it is relative to — the one whose response carried it.
    ///   - configured: The URL the transport was created with, whose origin is the limit.
    /// - Returns: The resolved URL if it may be used, or why it may not.
    static func resolve(_ reference: String, relativeTo base: URL, heldTo configured: URL) -> Resolution {
        guard let resolved = URL(string: reference, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false) else {
            return .notAURL
        }
        components.fragment = nil

        // Re-read from the string, because the string is what the HTTP client is handed. A
        // check made on one parse and a request made from another is the gap this closes.
        guard let text = components.string, let destination = URL(string: text) else {
            return .notAURL
        }
        let named = description(of: destination)

        let bringsUserinfo = destination.user != nil || destination.password != nil
        let isTheCallersOwn = destination.user == configured.user && destination.password == configured.password
        guard !bringsUserinfo || isTheCallersOwn else {
            return .carriesUserinfo(origin: named)
        }

        // The origin, component by component. Each side is parsed; nothing here is a prefix
        // or a substring test, so `good.example.evil.test` is simply a different host.
        guard let expectedScheme = configured.scheme?.lowercased(),
              let expectedHost = configured.host?.lowercased(), !expectedHost.isEmpty,
              let expectedPort = effectivePort(of: configured),
              destination.scheme?.lowercased() == expectedScheme,
              destination.host?.lowercased() == expectedHost,
              effectivePort(of: destination) == expectedPort else {
            return .otherOrigin(origin: named)
        }
        return .sameOrigin(destination)
    }

    /// The port a URL's requests go to: the one it names, else its scheme's default.
    ///
    /// - Parameter url: An absolute URL.
    /// - Returns: `nil` unless the scheme is `http` or `https` — nothing else is a place an
    ///   HTTP transport can send to, so nothing else has a port worth comparing.
    static func effectivePort(of url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return url.port ?? 443
        case "http": return url.port ?? 80
        default: return nil
        }
    }

    /// What is said of a URL that has no origin to name.
    static let noOrigin = "(no origin)"

    /// `scheme://host[:port]` — the most an error or a log line says about a URL a *server*
    /// chose.
    ///
    /// Userinfo, path and query are left out on purpose: the first is a credential, and the
    /// rest is whatever the server wanted written into the caller's logs.
    ///
    /// - Parameter url: The URL to name.
    /// - Returns: Its origin, or ``noOrigin`` if it has no host.
    static func description(of url: URL) -> String {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased(), !host.isEmpty else {
            return noOrigin
        }
        let authority = host.contains(":") ? "[\(host)]" : host
        guard let port = url.port else { return "\(scheme)://\(authority)" }
        return "\(scheme)://\(authority):\(port)"
    }

    /// A URL with everything that can carry a secret taken off: no userinfo, no query, no
    /// fragment. Origin and path remain.
    ///
    /// What an error or a log line says about a URL the *caller* is using. The path is kept
    /// because "which endpoint failed" is the useful part; the query goes because on a legacy
    /// HTTP+SSE endpoint it is usually the session id, and on a configured URL it is where an
    /// API key ends up when a server documents `?key=…`.
    ///
    /// - Parameter url: The URL to describe.
    /// - Returns: The redacted URL, or `nil` if it cannot be taken apart at all.
    static func redactedURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url.absoluteURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// ``redactedURL(_:)`` as text, for a message.
    ///
    /// - Parameter url: The URL to describe.
    /// - Returns: Origin and path, or ``noOrigin`` if the URL cannot be taken apart. Never the
    ///   original string: a fallback that printed what it could not redact would be the leak.
    static func redacted(_ url: URL) -> String {
        redactedURL(url)?.absoluteString ?? noOrigin
    }
}
