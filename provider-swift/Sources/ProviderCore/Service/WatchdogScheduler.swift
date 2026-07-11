import Foundation

/// Monotonic in-process cadence for the persistent watchdog LaunchAgent.
public struct WatchdogScheduler: Sendable {
    public let interval: Duration

    public init(interval: Duration = .seconds(60)) {
        precondition(interval > .zero)
        self.interval = interval
    }

    /// Ticks immediately, then sleeps on Swift's monotonic `ContinuousClock`.
    /// Cancellation always exits through the sleep boundary instead of spinning.
    public func run(
        tick: @escaping @Sendable () async -> Void
    ) async {
        while !Task.isCancelled {
            await tick()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
