import Foundation
import Logging

/// Asks an ``AuthorizationProvider`` for a header, and stops waiting after a set time.
///
/// A provider is the caller's code, and behind it is usually a token refresh: a network
/// request to an authorization server that may be slow, or down. For a request someone is
/// awaiting that is theirs to wait for. For one made while *disconnecting* it is not —
/// `disconnect()` has to return — so the ask is given a limit, and the limit holds whether or
/// not the provider notices it has been cancelled.
enum BoundedAuthorization {

    /// What an ask came to.
    enum Outcome: Sendable, Equatable {
        /// The provider answered. `nil` is its way of saying there is no session.
        case header(String?)
        /// The provider threw. Carries the error's type name — never its description, which
        /// is the provider's to write and may quote a token endpoint or a response.
        case failed(String)
        /// The provider had not answered when the time ran out.
        case timedOut
    }

    /// Asks once, without forcing a refresh, and waits no longer than `limit`.
    ///
    /// - Parameters:
    ///   - provider: The provider to ask. It is asked exactly once, with `forcingRefresh`
    ///     `false`: nothing has been refused, so there is no reason to spend a rotation.
    ///   - limit: How long to wait for it.
    /// - Returns: The answer, the failure, or ``Outcome/timedOut``. A provider that is still
    ///   running when the time runs out is cancelled and left to finish on its own; its
    ///   answer is discarded.
    static func ask(_ provider: @escaping AuthorizationProvider, within limit: Duration) async -> Outcome {
        // Whichever of the two tasks finishes first writes the one value this reads. A
        // stream rather than a task group, because a group waits for *every* child before it
        // returns — and the child being bounded here is the one that may never finish.
        let (outcomes, outcome) = AsyncStream<Outcome>.makeStream(bufferingPolicy: .bufferingOldest(1))

        let asking = Task {
            do {
                outcome.yield(.header(try await provider(false)))
            } catch {
                let kind = String(reflecting: type(of: error))
                let logger = Logger(label: "MCPClient.BoundedAuthorization")
                // logging: the provider's error by type name only — its description is the provider's to write
                logger.debug("the authorization provider failed: \(kind)")
                outcome.yield(.failed(kind))
            }
        }
        let timing = Task {
            // silent: a cancelled sleep means the provider answered first, and there is nothing to report
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            outcome.yield(.timedOut)
        }

        var first = Outcome.timedOut
        for await result in outcomes {
            first = result
            break
        }
        asking.cancel()
        timing.cancel()
        outcome.finish()
        return first
    }
}
