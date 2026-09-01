import Foundation
import Testing
@testable import MCPClient

/// How long to wait before reconnecting a dropped stream.
///
/// Split from the waiting itself so it can be tested at all. A backoff whose arithmetic lives
/// inline in a `Task.sleep` can only be checked by sleeping, which makes a suite slow and
/// timing-dependent; as a pure function every case is a table.
///
/// `SwiftDeterminism` was considered and does not fit: `WallClock` virtualises *reading* time,
/// and the untestable part of a backoff is *waiting*. Separating policy from suspension is the
/// fix, and it needs no dependency.
@Suite("Stream backoff")
struct StreamBackoffTests {

    /// The first retry does not wait. A stream that dropped for a transient reason should come
    /// back at once; making every reconnect pay a second is how a brief blip becomes a visible
    /// outage.
    @Test("The first attempt does not wait")
    func firstAttemptIsImmediate() {
        #expect(StreamBackoff.standard.delay(forAttempt: 0) == .zero)
    }

    /// Doubling, from the base. The shape everything else assumes.
    @Test("Delays double from the base", arguments: [
        (1, Duration.seconds(1)),
        (2, Duration.seconds(2)),
        (3, Duration.seconds(4)),
        (4, Duration.seconds(8))
    ])
    func delaysDouble(attempt: Int, expected: Duration) {
        #expect(StreamBackoff.standard.delay(forAttempt: attempt) == expected)
    }

    /// Bounded. Unbounded doubling reaches hours, and a client that waits hours to reconnect
    /// has stopped being a client — it looks identical to one that gave up, except it still
    /// holds resources.
    @Test("Delays are capped rather than doubling forever")
    func delaysAreCapped() {
        let policy = StreamBackoff(base: .seconds(1), ceiling: .seconds(30))

        #expect(policy.delay(forAttempt: 20) == .seconds(30))
        #expect(policy.delay(forAttempt: 1_000) == .seconds(30))
    }

    /// A negative attempt is a caller bug, not a reason to compute a negative delay and pass
    /// it to `Task.sleep`, which would throw or return immediately depending on the platform.
    @Test("A nonsensical attempt number yields no wait rather than a negative one")
    func negativeAttemptIsClamped() {
        #expect(StreamBackoff.standard.delay(forAttempt: -1) == .zero)
    }

    /// The GET stream's loss is not fatal — request/response keeps working without it — so it
    /// waits longer between attempts than a channel whose loss ends the connection. Stated as
    /// a separate policy rather than a magic number at the call site.
    @Test("The server-stream policy is gentler than the default")
    func serverStreamPolicyIsGentler() {
        let ordinary = StreamBackoff.standard.delay(forAttempt: 3)
        let serverStream = StreamBackoff.serverStream.delay(forAttempt: 3)

        #expect(serverStream > ordinary,
                "the GET stream retries as aggressively as a channel whose loss is fatal")
    }

    /// Overflow is the failure this kind of arithmetic actually has: doubling in `Int`
    /// nanoseconds passes a plausible-looking test at attempt 10 and produces a negative
    /// duration somewhere past attempt 60.
    @Test("A very large attempt number stays at the ceiling")
    func largeAttemptDoesNotOverflow() {
        let delay = StreamBackoff.standard.delay(forAttempt: Int.max)

        #expect(delay == StreamBackoff.standard.ceiling)
        #expect(delay > .zero)
    }
}

/// The legacy transport's reconnect delays, which had no test at all before the policy was
/// separated from the sleeping.
@Suite("Stream backoff — legacy SSE")
struct LegacySSEBackoffTests {

    /// The delays a default `HTTPSSETransport` waits, in order. Its base is 1 second and it
    /// makes three attempts, so this is the whole schedule.
    @Test("The default schedule is immediate, then 1s, 2s, 4s")
    func defaultSchedule() {
        let backoff = StreamBackoff(base: .seconds(1.0), ceiling: .seconds(30))

        #expect((0...3).map { backoff.delay(forAttempt: $0) }
                == [.zero, .seconds(1), .seconds(2), .seconds(4)])
    }

    /// A fractional base is honoured rather than truncated — the transport takes a
    /// `TimeInterval`, and a caller asking for half a second should get half a second.
    @Test("A fractional base survives")
    func fractionalBase() {
        let backoff = StreamBackoff(base: .seconds(0.5), ceiling: .seconds(30))

        #expect(backoff.delay(forAttempt: 1) == .milliseconds(500))
        #expect(backoff.delay(forAttempt: 2) == .seconds(1))
    }

    /// The bound this gained. A caller raising `maxReconnectAttempts` used to buy delays that
    /// doubled without limit; attempt 20 was over a week.
    @Test("A large attempt count no longer buys an unbounded wait")
    func largeAttemptCountIsBounded() {
        let backoff = StreamBackoff(base: .seconds(1.0), ceiling: .seconds(30))

        #expect(backoff.delay(forAttempt: 20) == .seconds(30))
    }
}
