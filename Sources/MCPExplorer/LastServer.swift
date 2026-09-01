import Foundation

/// The server the Explorer was last pointed at.
///
/// Remembered for one reason: a stored OAuth session can only be restored *against a server*,
/// and until this existed the URL field was empty at every launch. The credential and the
/// client registration both survived the restart; the one thing that did not was the address
/// they belonged to, so the user was sent back through a browser consent screen for a session
/// that was sitting on disk intact.
///
/// One value, not a history. A list of every server a user has ever typed is a record nobody
/// asked this application to keep.
struct LastServer {

    /// Where the value is filed.
    private static let key = "lastServerURL"

    private let defaults: UserDefaults

    /// Creates an accessor.
    ///
    /// - Parameter defaults: Where to keep the value. Injected so a test neither reads nor
    ///   writes the domain the running application uses.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The remembered server, if there is one.
    ///
    /// Whitespace reads as nothing. A field holding only spaces is an empty field to the
    /// person looking at it, and recalling it would put an unusable value in front of them
    /// before they had done anything.
    var recalled: String? {
        guard let stored = defaults.string(forKey: Self.key) else { return nil }
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Remembers a server, replacing whatever was remembered before.
    ///
    /// An empty value forgets rather than storing emptiness — a user who cleared the field
    /// meant to clear it, and resurrecting the old URL at the next launch reads as the
    /// application ignoring them.
    ///
    /// - Parameter url: What is in the field now.
    func remember(_ url: String) {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(trimmed, forKey: Self.key)
    }
}
