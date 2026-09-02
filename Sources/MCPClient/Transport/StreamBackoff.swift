import Foundation

/// How long to wait before reconnecting a dropped stream.
///
/// Policy only. The waiting happens at the call site, and keeping the arithmetic out of it is
/// what makes the arithmetic testable: a delay computed inline in a `Task.sleep` can only be
/// checked by sleeping, which makes a suite slow and timing-dependent. As a value type every
/// case is a table.
///
/// Two policies, because the two streams fail differently. Losing the channel a transport
/// depends on is an outage; losing the server-initiated stream costs only server-initiated
/// messages, and retrying it as hard would spend requests on something nothing is waiting for.
struct StreamBackoff: Sendable, Equatable {

    /// The delay before the second attempt, doubling from there.
    let base: Duration

    /// The longest this will ever wait.
    ///
    /// Unbounded doubling reaches hours, and a client that waits hours to reconnect is
    /// indistinguishable from one that gave up, except that it still holds resources.
    let ceiling: Duration

    /// Creates a policy.
    init(base: Duration, ceiling: Duration) {
        self.base = base
        self.ceiling = ceiling
    }

    /// The policy for a stream whose loss ends the connection.
    static let standard = StreamBackoff(base: .seconds(1), ceiling: .seconds(30))

    /// The policy for the server-initiated `GET` stream.
    ///
    /// Gentler on purpose. Request and response keep working without this stream, so a client
    /// that hammers it is spending requests to restore something no caller is blocked on.
    static let serverStream = StreamBackoff(base: .seconds(2), ceiling: .seconds(120))

    /// The attempt number standing for "the server closed the stream, as it may".
    ///
    /// 2025-11-25 (SEP-1699) lets a server disconnect a stream whenever it likes and expects
    /// the client to poll. A quiet close is therefore not a failure, and scoring it as one
    /// climbs the backoff until a perfectly healthy server is barely watched. Naming the
    /// steady cadence here keeps that distinction out of the reconnect loop, where it would
    /// read as an arbitrary number.
    static let pollingAttempt = 1

    /// How long to wait before an attempt.
    ///
    /// - Parameter attempt: Which attempt this is. `0` is the first and does not wait: a
    ///   stream dropped for a transient reason should come back at once, and making every
    ///   reconnect pay a second is how a blip becomes a visible outage.
    /// - Returns: The delay, never negative and never above ``ceiling``.
    func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }

        // Doubling is done on the *exponent* rather than by multiplying a Duration, and it
        // stops as soon as the ceiling is reached. Doubling nanoseconds in `Int` is the real
        // failure mode of this kind of arithmetic: it passes a plausible test at attempt 10
        // and yields a negative duration somewhere past attempt 60, which reaches `Task.sleep`
        // as either a throw or an instant return depending on the platform.
        var delay = base
        for _ in 1..<max(attempt, 1) {
            if delay >= ceiling { return ceiling }
            delay += delay
        }
        return min(delay, ceiling)
    }
}
