import Testing
import NIOCore
@testable import MCPClient

/// `TimeAmount` counts nanoseconds in an `Int64`, and `Int64(_:)` traps on a NaN, an
/// infinity, or anything outside its range. The transports take their timeouts as
/// `TimeInterval`, so the conversion has to answer every `Double` without stopping the process.
@Suite("TimeAmount from TimeInterval")
struct TimeAmountConversionTests {

    @Test("Whole seconds convert exactly")
    func wholeSeconds() {
        #expect(TimeAmount.seconds(clamping: 30.0) == .seconds(30))
    }

    @Test("Fractional seconds keep their precision rather than truncating to zero")
    func fractionalSeconds() {
        #expect(TimeAmount.seconds(clamping: 0.5) == .milliseconds(500))
        #expect(TimeAmount.seconds(clamping: 1.25) == .milliseconds(1250))
    }

    @Test("Zero is zero")
    func zero() {
        #expect(TimeAmount.seconds(clamping: 0.0) == .nanoseconds(0))
    }

    @Test("A NaN is a timeout of nothing, not a crash")
    func nan() {
        #expect(TimeAmount.seconds(clamping: .nan) == .nanoseconds(0))
    }

    @Test("Positive infinity is the longest representable wait")
    func positiveInfinity() {
        #expect(TimeAmount.seconds(clamping: .infinity) == .nanoseconds(.max))
    }

    @Test("Negative values, finite or not, clamp to zero")
    func negatives() {
        #expect(TimeAmount.seconds(clamping: -1.0) == .nanoseconds(0))
        #expect(TimeAmount.seconds(clamping: -.infinity) == .nanoseconds(0))
        #expect(TimeAmount.seconds(clamping: -1e300) == .nanoseconds(0))
    }

    @Test("Finite values past Int64 nanoseconds clamp to the maximum")
    func overflow() {
        // 1e300 seconds overflows even before the nanosecond scaling; 1e10 seconds overflows
        // only after it (Int64.max nanoseconds is a little over 9.2e9 seconds).
        #expect(TimeAmount.seconds(clamping: 1e300) == .nanoseconds(.max))
        #expect(TimeAmount.seconds(clamping: 1e10) == .nanoseconds(.max))
    }

    @Test("The largest representable value round-trips near the limit")
    func nearLimit() {
        let amount = TimeAmount.seconds(clamping: 9.0e9)
        #expect(amount == .seconds(9_000_000_000))
    }
}
