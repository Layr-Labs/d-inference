import Foundation

/// Watches a member session's heartbeat report (`cluster_session`) and calls
/// `changed` with each new value. (Failing-first stub: reports nothing yet.)
enum NativePairSessionStatusWatch {
    static func start(pollMilliseconds: Int = 25, current: @escaping @Sendable () -> ClusterSessionStatus?,
                      live: @escaping @Sendable () -> Bool, changed: @escaping @Sendable (ClusterSessionStatus) -> Void) {}
}
