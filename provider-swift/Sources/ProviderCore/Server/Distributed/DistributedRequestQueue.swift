import Foundation

/// More requests than the installed pair runs at once. The pair runs as many
/// as it has batch lanes (one when it serves one at a time); further requests
/// wait in arrival order, at most `maximumWaiting` of them, and each starts
/// when a lane frees. A request that finds the queue full
/// is refused with 429 (retry later: capacity frees as requests finish); one
/// that finds the session not serving (starting, stopping, failed) or that
/// waited longer than `waitCeiling` is refused with 503. A client that goes
/// away while queued leaves the queue. The first-token budget and the request
/// deadline start when the request leaves the queue, as they would for a
/// request that arrived at that moment.
enum DistributedRequestQueue {
    /// Requests that may wait behind the running one.
    static let maximumWaiting = 8
    /// The most batch lanes a pair runs (`DistributedInstalledPlan.batchLanes`).
    static let maximumLanes = 8
    static let fullMessage = "Distributed request queue full"
    static let waitedTooLongMessage = "Distributed request waited too long in the queue"
    static let pollInterval: Duration = .milliseconds(10)

    /// The longest one request may wait: a full queue ahead of it, each at
    /// its own request deadline.
    static func waitCeiling(requestTimeout: Duration) -> Duration {
        requestTimeout * (maximumWaiting + 1)
    }
}
