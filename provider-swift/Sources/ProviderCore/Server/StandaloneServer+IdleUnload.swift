import Foundation

/// StandaloneServer -- the memory setting for Only me.
extension StandaloneServer {
    /// Checks once a minute; nothing yet.
    public func startIdleUnload(minutes: UInt64, every interval: Duration = .seconds(60)) {}

    /// One pass: how many models were unloaded.
    @discardableResult
    func unloadIdleModels(idleFor: Duration, now: ContinuousClock.Instant = .now) async -> Int { 0 }
}
