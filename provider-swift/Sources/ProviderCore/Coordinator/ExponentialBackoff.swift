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

    /// Returns the next backoff delay using "equal jitter": half the
    /// deterministic exponential delay, plus a random amount up to the other
    /// half. The deterministic component still doubles (capped at `max`).
    ///
    /// Jitter matters at fleet scale: without it, every provider that dropped on
    /// the same coordinator blip reconnects in lockstep (1s, 2s, 4s, …), and the
    /// synchronized reconnect herd can knock the coordinator straight back over.
    /// Spreading reconnects across the window breaks that resonance.
    public mutating func nextDelay() -> TimeInterval {
        let deterministic = current
        current = Swift.min(current * 2, max)
        let half = deterministic / 2
        return half + Double.random(in: 0...half)
    }

    public mutating func reset() {
        current = base
    }
}
