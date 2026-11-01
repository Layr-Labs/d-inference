import Foundation

/// A proposal can be discarded while metadata is being read (for example,
/// its queue emptied). Throttle attempts without permanently consuming the
/// serving generation; only the host knows whether a proposal was accepted.
struct DistributedAutomaticBatchAttempt {
    private var last: ContinuousClock.Instant?

    mutating func begin(now: ContinuousClock.Instant = .now) -> Bool {
        guard last.map({ $0.duration(to: now) >= .seconds(30) }) ?? true else { return false }
        last = now
        return true
    }
}
