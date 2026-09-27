import Foundation

/// One stage call owns this scalar meter. Streaming reads are synchronous on
/// that task; the meter never retains a manifest, native buffer or request.
/// The original first attempt remains unchanged. Only the optional retry is
/// constrained by the remaining raw-byte/time allowance from the original start.
final class SSDCheckpointReadBudget {
    enum Exhausted: Error { case bytes, time }

    private let maximumBytes: Int
    private let maximumMillis: Double
    private let started: ContinuousClock.Instant
    private let now: @Sendable () -> ContinuousClock.Instant
    private(set) var consumedBytes = 0
    private(set) var retrying = false

    init(maximumBytes: Int, maximumMillis: Int, started: ContinuousClock.Instant,
         now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.maximumBytes = max(0, maximumBytes)
        self.maximumMillis = Double(max(0, maximumMillis))
        self.started = started
        self.now = now
    }

    var elapsedMillis: Double {
        let duration = started.duration(to: now()).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }

    func beginRetry(estimatedFileBytes: Int) -> Bool {
        let elapsed = elapsedMillis
        guard !retrying, estimatedFileBytes >= 0, consumedBytes <= maximumBytes,
            estimatedFileBytes <= maximumBytes - consumedBytes,
            elapsed.isFinite, elapsed >= 0, elapsed < maximumMillis,
            elapsed + SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: estimatedFileBytes) <= maximumMillis
        else { return false }
        retrying = true
        return true
    }

    func checkTime() throws {
        guard retrying else { return }
        let elapsed = elapsedMillis
        guard elapsed.isFinite, elapsed >= 0, elapsed < maximumMillis
        else { throw Exhausted.time }
    }

    /// Reserve before Data allocation/IO. readExactly owns this complete span,
    /// even if the OS delivers it in partial reads; zero checks time only.
    /// EOF's one-byte probe is deliberately charged conservatively. First-leg
    /// accounting saturates rather than introducing a new first-attempt refusal.
    func beforeRead(_ count: Int) throws {
        try checkTime()
        let (next, overflow) = consumedBytes.addingReportingOverflow(max(0, count))
        if retrying, count < 0 || overflow || next > maximumBytes { throw Exhausted.bytes }
        consumedBytes = overflow ? Int.max : next
    }
}
