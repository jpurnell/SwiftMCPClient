import Foundation
import NIOCore

extension TimeAmount {
    /// Converts a `TimeInterval` to a `TimeAmount` without ever stopping the process.
    ///
    /// `TimeAmount` counts nanoseconds in an `Int64`, and `Int64(_:)` traps on a NaN, an
    /// infinity, or any value outside its range. The transports take their timeouts as
    /// `TimeInterval`, which admits all of those, so this conversion answers every `Double`:
    ///
    /// - A NaN or any negative value is a wait of nothing. There is no right length for a
    ///   timeout that was never a number, and failing every request at once is the version of
    ///   wrong that gets noticed.
    /// - Positive infinity, or any finite value past what `Int64` nanoseconds can hold, is the
    ///   longest wait NIO can express. `NIODeadline` saturates to `distantFuture` when it is
    ///   added, so the maximum is safe to pass on.
    /// - Anything else keeps nanosecond precision. Truncating to whole seconds, as `Int64(_:)`
    ///   would, turns a half-second timeout into no timeout at all.
    ///
    /// - Parameter interval: A duration in seconds.
    /// - Returns: The nearest `TimeAmount`, rounded toward zero.
    static func seconds(clamping interval: TimeInterval) -> TimeAmount {
        guard interval.isFinite else {
            // NaN compares false against everything, so it lands in the zero arm with -inf.
            return interval > 0 ? .nanoseconds(.max) : .nanoseconds(0)
        }
        guard interval > 0 else { return .nanoseconds(0) }
        let nanoseconds = (interval * 1_000_000_000).rounded(.towardZero)
        guard let whole = Int64(exactly: nanoseconds) else {
            // Finite and positive, so the only way `exactly` is nil is overflow.
            return .nanoseconds(.max)
        }
        return .nanoseconds(whole)
    }
}
