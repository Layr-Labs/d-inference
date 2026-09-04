// Copyright © 2026 Eigen Labs.
//
// T1-13 (1) — the ping/pong timeout and the suspension heuristic run on the
// monotonic ContinuousClock, never the wall clock. Pinned with an injected
// clock: what the tracker reports is a function of the instants it was
// handed, so a wall-clock step cannot reach it.

import Foundation
import Testing

@testable import ProviderCore

/// Scripted ContinuousClock: advances only when told to.
private final class ScriptedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var now: ContinuousClock.Instant { lock.withLock { instant } }

    func advance(_ duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

@Suite("Link clocks (T1-13)")
struct LinkClockTests {

    @Test("pong age is measured on the injected monotonic instants")
    func pongAgeFollowsInjectedClock() {
        let clock = ScriptedClock()
        let tracker = PongTracker(now: { clock.now })
        #expect(tracker.elapsed() == .zero)

        clock.advance(.seconds(25))
        #expect(tracker.elapsed() == .seconds(25))

        // A pong resets the age; the wall clock never entered the arithmetic.
        tracker.recordPong()
        #expect(tracker.elapsed() == .zero)
        clock.advance(.seconds(31))
        #expect(tracker.elapsed() == .seconds(31))
        #expect(tracker.elapsed() > .seconds(30))  // the pong-timeout bar
    }

    @Test("the default tracker reads the live ContinuousClock, not CFAbsoluteTime")
    func defaultTrackerIsMonotonic() async throws {
        let tracker = PongTracker()
        let before = tracker.elapsed()
        try await Task.sleep(for: .milliseconds(20))
        let after = tracker.elapsed()
        #expect(after > before)
        #expect(after < .seconds(5))
    }

    @Test("suspension is a tick gap beyond three ping intervals")
    func suspensionRule() {
        let ping: Duration = .seconds(10)
        #expect(!CoordinatorClient.suspensionDetected(gap: .seconds(10), pingInterval: ping))
        #expect(!CoordinatorClient.suspensionDetected(gap: .seconds(30), pingInterval: ping))
        #expect(CoordinatorClient.suspensionDetected(gap: .seconds(31), pingInterval: ping))
        #expect(CoordinatorClient.suspensionDetected(gap: .seconds(3600), pingInterval: ping))
    }
}
