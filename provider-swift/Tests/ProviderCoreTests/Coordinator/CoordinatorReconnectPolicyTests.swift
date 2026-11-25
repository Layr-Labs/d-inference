/// Reconnect policy rows: the backoff reset and the 0-0.25 s first retry after a
/// session of 60 s or more, no wait for the coordinator's planned close (1012
/// `planned move`), the 0-15 s wait without growth for every other close with
/// code 1001 or 1012, and the unchanged backoff for every other end of a
/// shorter session.
/// The policy returns the range that `runLoop` draws the wait from, so each row
/// checks exact ranges.

import Foundation
import Testing

@testable import ProviderCore

@Suite("CoordinatorReconnectPolicy")
struct CoordinatorReconnectPolicyTests {

    /// The backoff ranges before this policy, for `ExponentialBackoff(base: 1.0, max: 30.0)`.
    private static let backoffRanges: [ClosedRange<TimeInterval>] = [
        0.5...1, 1...2, 2...4, 4...8, 8...16, 15...30, 15...30,
    ]

    /// A session of 1 s that ended without a close frame.
    private static let shortTransportClose = CoordinatorSessionEnd(
        openDuration: .seconds(1), closeCode: nil)

    /// A policy whose backoff grew with `count` short sessions.
    private static func policy(afterShortSessions count: Int) -> CoordinatorReconnectPolicy {
        var policy = CoordinatorReconnectPolicy()
        for _ in 0..<count {
            _ = policy.nextDelayRange(after: shortTransportClose)
        }
        return policy
    }

    @Test("a session open for 60 s or more retries within 0.25 s and resets the backoff",
          arguments: [Duration.seconds(60), .seconds(61), .seconds(3600)])
    func stableSessionRetriesAtOnceAndResetsBackoff(openDuration: Duration) {
        var policy = Self.policy(afterShortSessions: 3)
        // Without the stable session this range is 4...8.
        let afterStable = policy.nextDelayRange(
            after: CoordinatorSessionEnd(openDuration: openDuration, closeCode: nil))
        #expect(afterStable == (0.0...0.25))
        // A failure after it backs off again from the shortest wait.
        let next = policy.nextDelayRange(after: Self.shortTransportClose)
        #expect(next == (0.5...1.0))
        #expect(policy.nextDelayRange(after: Self.shortTransportClose) == (1.0...2.0))
    }

    @Test("a stable session that ends with a close code other than 1001 and 1012 also retries within 0.25 s",
          arguments: [UInt16(1000), 1006, 1008, 1011])
    func stableSessionCloseRetriesAtOnce(closeCode: UInt16) {
        var policy = Self.policy(afterShortSessions: 2)
        let range = policy.nextDelayRange(
            after: CoordinatorSessionEnd(openDuration: .seconds(60), closeCode: closeCode))
        #expect(range == (0.0...0.25))
    }

    @Test("a session open for less than 60 s keeps the grown backoff",
          arguments: [Duration.seconds(60) - .milliseconds(1), .seconds(1), .zero])
    func shortSessionKeepsBackoff(openDuration: Duration) {
        var policy = Self.policy(afterShortSessions: 3)
        let range = policy.nextDelayRange(
            after: CoordinatorSessionEnd(openDuration: openDuration, closeCode: nil))
        #expect(range == (4.0...8.0))
    }

    /// The server side sends 1001 (going away) and 1012 (service restart) to
    /// every provider at once, so the wait spreads the fleet's reconnects.
    @Test("close codes 1001 and 1012 give 0 to 15 s and do not grow the backoff",
          arguments: [UInt16(1001), 1012])
    func fleetCloseSpreadsWithoutGrowth(closeCode: UInt16) {
        var policy = Self.policy(afterShortSessions: 2)
        let close = CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: closeCode)
        for _ in 0..<3 {
            let range = policy.nextDelayRange(after: close)
            #expect(range == (0.0...15.0))
        }
        // The next other end continues from the backoff that the two sessions grew.
        let next = policy.nextDelayRange(after: Self.shortTransportClose)
        #expect(next == (2.0...4.0))
    }

    /// Only the coordinator's close pacer sends 1012 with the reason `planned
    /// move`, at a bounded rate, so the provider reconnects without a wait.
    @Test("a 1012 planned move close gives no wait and does not grow the backoff",
          arguments: [Duration.seconds(1), .seconds(3_600)])
    func plannedCloseGivesNoWait(openDuration: Duration) {
        var policy = Self.policy(afterShortSessions: 2)
        let planned = CoordinatorSessionEnd(openDuration: openDuration, closeCode: 1012, closeReason: "planned move")
        for _ in 0..<3 {
            #expect(policy.nextDelayRange(after: planned) == (0.0...0.0))
        }
        // A short session leaves the grown backoff as it was; a stable one resets it.
        let next = policy.nextDelayRange(after: Self.shortTransportClose)
        #expect(next == (openDuration >= .seconds(60) ? (0.5...1.0) : (2.0...4.0)))
    }

    @Test("a 1001 or 1012 close with any other reason keeps the 0 to 15 s wait",
          arguments: [
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1012, closeReason: "edge restart"),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1012, closeReason: "conductor failover"),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1012, closeReason: "Planned Move"),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1012, closeReason: "planned move "),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1012, closeReason: ""),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1012, closeReason: nil),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1001, closeReason: "planned move"),
          ])
    func otherFleetClosesKeepTheSpread(end: CoordinatorSessionEnd) {
        var policy = CoordinatorReconnectPolicy()
        #expect(policy.nextDelayRange(after: end) == (0.0...15.0))
    }

    @Test("the planned move reason on another close code is not a planned close",
          arguments: [UInt16(1000), 1008, 1011, 1013])
    func plannedReasonOnAnotherCodeKeepsTheBackoff(closeCode: UInt16) {
        var policy = Self.policy(afterShortSessions: 3)
        let end = CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: closeCode, closeReason: "planned move")
        #expect(policy.nextDelayRange(after: end) == (4.0...8.0))
    }

    @Test("close codes 1001 and 1012 after a session open for 60 s also reset the backoff",
          arguments: [UInt16(1001), 1012])
    func fleetCloseAfterStableSessionResetsBackoff(closeCode: UInt16) {
        var policy = Self.policy(afterShortSessions: 3)
        let close = policy.nextDelayRange(
            after: CoordinatorSessionEnd(openDuration: .seconds(3_600), closeCode: closeCode))
        #expect(close == (0.0...15.0))
        let next = policy.nextDelayRange(after: Self.shortTransportClose)
        #expect(next == (0.5...1.0))
    }

    @Test("other close codes, a transport close and a refused attempt keep the backoff",
          arguments: [
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1000),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1008),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1011),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1013),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: nil),
              CoordinatorSessionEnd(openDuration: nil, closeCode: nil),
          ])
    func otherEndsKeepBackoff(end: CoordinatorSessionEnd) {
        var policy = CoordinatorReconnectPolicy()
        var ranges: [ClosedRange<TimeInterval>] = []
        for _ in Self.backoffRanges {
            ranges.append(policy.nextDelayRange(after: end))
        }
        #expect(ranges == Self.backoffRanges)
    }
}
