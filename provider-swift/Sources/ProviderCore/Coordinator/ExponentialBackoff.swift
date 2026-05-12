import Foundation

public struct ExponentialBackoff: Sendable {
    private var current: TimeInterval
    private let max: TimeInterval

    public init(base: TimeInterval = 1.0, max: TimeInterval = 30.0) {
        self.current = base
        self.max = max
    }

    public mutating func nextDelay() -> TimeInterval {
        let delay = current
        current = Swift.min(current * 2, max)
        return delay
    }

    public mutating func reset() {
        current = 1.0
    }
}
