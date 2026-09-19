import Foundation

/// A bounded opportunity to resample real OS headroom after owned Qwen4
/// resources have retired. This carries no bytes and grants no allocation
/// credit. Callers must rerun their complete admission calculation after each
/// suspension and retain the atomic final load permit.
struct NativeMemoryRetirementWindow: Sendable {
    static let maximumDuration: Duration = .seconds(2)
    static let sampleInterval: Duration = .milliseconds(25)
    let deadline: ContinuousClock.Instant

    init(retiredAt: ContinuousClock.Instant = .now) {
        deadline = retiredAt.advanced(by: Self.maximumDuration)
    }

    func nextDelay(now: ContinuousClock.Instant = .now) -> Duration? {
        guard now < deadline else { return nil }
        return min(Self.sampleInterval, now.duration(to: deadline))
    }

    func pauseForRecheck() async throws -> Bool {
        try Task.checkCancellation()
        guard let delay = nextDelay() else { return false }
        try await Task.sleep(for: delay)
        return true
    }
}
