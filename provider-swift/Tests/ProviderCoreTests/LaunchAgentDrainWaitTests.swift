// Copyright © 2026 Eigen Labs.
//
// `darkbloom start` over a running daemon: since SIGTERM drains instead of
// killing, `installAndStart` must wait for the booted-out instance to leave
// launchd's table before it bootstraps the new plist (a bootstrap of a label
// whose previous instance is still exiting fails with EIO — measured on a
// throwaway label), and the new process's single-instance lock must wait for
// a draining predecessor instead of sending it the second SIGTERM that the
// trap turns into a forced exit. The poll loop is pure; these tests drive it
// with an injected probe and clock.

import Foundation
import Testing

@testable import ProviderCore

/// Fake monotonic clock: `sleep` advances it, so the loop's timing is exact.
private final class FakeClock {
    private let origin = ContinuousClock.Instant.now
    private(set) var elapsed: Duration = .zero
    var now: ContinuousClock.Instant { origin.advanced(by: elapsed) }
    func advance(_ d: Duration) { elapsed += d }
}

@Suite("LaunchAgent drain wait (predecessor exit)")
struct LaunchAgentDrainWaitTests {

    @Test("returns at once, silently, when the predecessor is already gone")
    func alreadyGone() {
        let clock = FakeClock()
        var announced = false
        var polls = 0
        let gone = ProcessExitWait.wait(
            bound: .seconds(135),
            now: { clock.now },
            sleep: { clock.advance($0) },
            onWaiting: { _ in announced = true },
            gone: { polls += 1; return true })
        #expect(gone)
        #expect(polls == 1)
        #expect(!announced)
    }

    @Test("waits through a drain, announces once past 1 s, and returns when the probe flips")
    func waitsForDrain() {
        let clock = FakeClock()
        var announcements: [Duration] = []
        // The predecessor exits 3.1 s in — a short drain plus teardown.
        let gone = ProcessExitWait.wait(
            bound: .seconds(135),
            now: { clock.now },
            sleep: { clock.advance($0) },
            onWaiting: { announcements.append($0) },
            gone: { clock.elapsed >= .seconds(3) + .milliseconds(100) })
        #expect(gone)
        #expect(announcements == [.seconds(135)], "announce exactly once, with the bound")
        #expect(clock.elapsed >= .seconds(3) + .milliseconds(100))
        #expect(clock.elapsed < .seconds(4), "kept polling at the 250 ms cadence: \(clock.elapsed)")
    }

    @Test("gives up at the bound when the predecessor never exits")
    func boundedByExitTimeOut() {
        let clock = FakeClock()
        var polls = 0
        let gone = ProcessExitWait.wait(
            bound: .seconds(10),
            now: { clock.now },
            sleep: { clock.advance($0) },
            gone: { polls += 1; return false })
        #expect(!gone)
        #expect(clock.elapsed == .seconds(10), "overshot the bound: \(clock.elapsed)")
        #expect(polls == 41, "10 s at 250 ms polls plus the final check, got \(polls)")
    }

    /// The bound `installAndStart` waits for is launchd's SIGKILL budget for
    /// the old job plus a margin: past that the old process is dead by
    /// construction and a bootstrap can proceed.
    @Test("installAndStart waits at least ExitTimeOut for the old job")
    func installWaitCoversExitTimeOut() {
        #expect(LaunchAgent.previousInstanceExitBound
            >= .seconds(LaunchAgent.exitTimeOutSeconds))
    }
}
