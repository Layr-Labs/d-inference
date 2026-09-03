import Foundation

/// Monotonic in-process cadence for the persistent watchdog LaunchAgent.
public struct WatchdogScheduler: Sendable {
    public let interval: Duration
    private let sleep: @Sendable (Duration) async throws -> Void


    public init(interval: Duration = .seconds(60)) {
        self.init(interval: interval, sleep: taskSleep)
    }

    init(
        interval: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        precondition(interval > .zero)
        self.interval = interval
        self.sleep = sleep
    }

    /// Ticks immediately, then sleeps on Swift's monotonic `ContinuousClock`.
    /// Cancellation always exits through the sleep boundary instead of spinning.
    public func run(
        tick: @escaping @Sendable () async -> Void
    ) async {
        while !Task.isCancelled {
            await tick()
            do {
                try await sleep(interval)
            } catch {
                return
            }
        }
    }
}
