/// Reconnect policy rows: the backoff reset after a session of 60 s or more, the
/// 0-1 s wait without growth for close code 1012, and the unchanged backoff for
/// every other end. The policy returns the range that `runLoop` draws the wait
/// from, so each row checks exact ranges.

import Foundation
import Network
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

    @Test("a session open for 60 s or more resets the backoff before the next wait",
          arguments: [Duration.seconds(60), .seconds(61), .seconds(3600)])
    func stableSessionResetsBackoff(openDuration: Duration) {
        var policy = Self.policy(afterShortSessions: 3)
        // Without the reset this range is 4...8.
        let afterStable = policy.nextDelayRange(
            after: CoordinatorSessionEnd(openDuration: openDuration, closeCode: nil))
        #expect(afterStable == (0.5...1.0))
        // The backoff grows again from the shortest wait.
        let next = policy.nextDelayRange(after: Self.shortTransportClose)
        #expect(next == (1.0...2.0))
    }

    @Test("a session open for less than 60 s keeps the grown backoff",
          arguments: [Duration.seconds(60) - .milliseconds(1), .seconds(1), .zero])
    func shortSessionKeepsBackoff(openDuration: Duration) {
        var policy = Self.policy(afterShortSessions: 3)
        let range = policy.nextDelayRange(
            after: CoordinatorSessionEnd(openDuration: openDuration, closeCode: nil))
        #expect(range == (4.0...8.0))
    }

    @Test("close code 1012 gives 0 to 1 s and does not grow the backoff")
    func serviceRestartWaitsUpToOneSecondWithoutGrowth() {
        var policy = Self.policy(afterShortSessions: 2)
        let restart = CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1012)
        for _ in 0..<3 {
            let range = policy.nextDelayRange(after: restart)
            #expect(range == (0.0...1.0))
        }
        // The next other end continues from the backoff that the two sessions grew.
        let next = policy.nextDelayRange(after: Self.shortTransportClose)
        #expect(next == (2.0...4.0))
    }

    @Test("close code 1012 after a session open for 60 s also resets the backoff")
    func serviceRestartAfterStableSessionResetsBackoff() {
        var policy = Self.policy(afterShortSessions: 3)
        let restart = policy.nextDelayRange(
            after: CoordinatorSessionEnd(openDuration: .seconds(60), closeCode: 1012))
        #expect(restart == (0.0...1.0))
        let next = policy.nextDelayRange(after: Self.shortTransportClose)
        #expect(next == (0.5...1.0))
    }

    @Test("other close codes, a transport close and a refused attempt keep the backoff",
          arguments: [
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1000),
              CoordinatorSessionEnd(openDuration: .seconds(1), closeCode: 1001),
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

    @Test("each Network.framework close-code case gives the code number on the wire")
    func closeCodeWireValue() {
        #expect(NWProtocolWebSocket.CloseCode.protocolCode(.goingAway).wireValue == 1001)
        #expect(NWProtocolWebSocket.CloseCode.applicationCode(3001).wireValue == 3001)
        #expect(NWProtocolWebSocket.CloseCode.privateCode(4001).wireValue == 4001)
    }
}
