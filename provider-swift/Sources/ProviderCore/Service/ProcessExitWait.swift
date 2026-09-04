/// Bounded synchronous wait for a predecessor provider instance to go away.
///
/// Since the daemon traps SIGTERM and drains in-flight work (refuse → drain →
/// close, up to `ProviderLoop.gracefulDrainTimeout`), "the old instance is
/// gone" is no longer true a few hundred milliseconds after `launchctl
/// bootout` or a SIGTERM: an idle daemon is alive for seconds (its teardown),
/// a busy one for up to the drain bound. Both `LaunchAgent.installAndStart`
/// (bootstrap of a label whose previous instance is still exiting fails with
/// EIO) and `ProcessLifecycle.acquireSingleInstanceLock` (a second SIGTERM is
/// the trap's forced-exit path) have to wait for it. One poll loop, pure
/// (clock and sleep injected) so the bound and the announcement are
/// unit-testable without a process to wait on.
import Foundation

enum ProcessExitWait {

    static let defaultPollInterval: Duration = .milliseconds(250)

    /// How long a wait may run before `onWaiting` announces it — a fast exit
    /// stays silent, a real drain tells the operator what is happening.
    static let announceAfter: Duration = .seconds(1)

    /// Poll `gone` until it is true or `bound` elapses. Returns whether the
    /// predecessor went away inside the bound. `onWaiting` fires at most once,
    /// the first time the wait exceeds `announceAfter`, with the bound.
    @discardableResult
    static func wait(
        bound: Duration,
        pollInterval: Duration = defaultPollInterval,
        now: () -> ContinuousClock.Instant = { .now },
        sleep: (Duration) -> Void = { duration in
            Thread.sleep(forTimeInterval: duration.timeInterval)
        },
        onWaiting: (Duration) -> Void = { _ in },
        gone: () -> Bool
    ) -> Bool {
        let started = now()
        var announced = false
        while !gone() {
            let elapsed = now() - started
            if elapsed >= bound { return false }
            if !announced, elapsed >= announceAfter {
                announced = true
                onWaiting(bound)
            }
            sleep(min(pollInterval, bound - elapsed))
        }
        return true
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for the Foundation sleep/deadline APIs.
    var timeInterval: TimeInterval {
        TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18
    }
}
