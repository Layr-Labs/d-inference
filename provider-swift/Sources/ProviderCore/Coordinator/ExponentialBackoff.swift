import Foundation

public struct ExponentialBackoff: Sendable {
    private var current: TimeInterval
    private let base: TimeInterval
    private let max: TimeInterval

    public init(base: TimeInterval = 1.0, max: TimeInterval = 30.0) {
        self.base = base
        self.current = base
        self.max = max
    }

    /// Returns the range of the next backoff delay using "equal jitter": from
    /// half the deterministic exponential delay to all of it. The caller draws
    /// the delay uniformly from the range. The deterministic component still
    /// doubles (capped at `max`).
    ///
    /// Jitter matters at fleet scale: without it, every provider that dropped on
    /// the same coordinator blip reconnects in lockstep (1s, 2s, 4s, …), and the
    /// synchronized reconnect herd can knock the coordinator straight back over.
    /// Spreading reconnects across the window breaks that resonance.
    public mutating func nextDelayRange() -> ClosedRange<TimeInterval> {
        let deterministic = current
        current = Swift.min(current * 2, max)
        return (deterministic / 2)...deterministic
    }

    public mutating func reset() {
        current = base
    }
}
