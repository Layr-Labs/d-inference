import Foundation

/// More requests than the installed pair runs at once. The pair runs as many
/// as it has batch lanes (one when it serves one at a time); further requests
/// wait in arrival order, at most `Limits.maximumWaiting` of them, and each
/// starts when a lane frees. A request that finds the queue full
/// is refused with 429 (retry later: capacity frees as requests finish); one
/// that finds the session not serving (starting, stopping, failed) or that
/// waited longer than `waitCeiling` is refused with 503. A client that goes
/// away while queued leaves the queue. The first-token budget and the request
/// deadline start when the request leaves the queue, as they would for a
/// request that arrived at that moment.
enum DistributedRequestQueue {
    /// Requests that may wait behind the running ones by default: the
    /// single-Mac engine's waiting depth (`CBv2Contracts`), so a burst the
    /// single-Mac product queues is queued by a pair too, not refused.
    static let defaultMaximumWaiting = 64
    /// The most a configuration may set: every waiter holds an open HTTP
    /// response (`DistributedHTTPResponses`) and polls every `pollInterval`.
    static let maximumWaitingBound = 1024
    /// The most batch lanes a pair runs (`DistributedInstalledPlan.batchLanes`).
    static let maximumLanes = 8
    /// The owner's environment may set the waiting depth (0...1024; 0 refuses
    /// every request that finds all lanes busy).
    static let waitingEnvironmentName = "DARKBLOOM_CLUSTER_QUEUE_WAITING"
    static let fullMessage = "Distributed request queue full"
    static let waitedTooLongMessage = "Distributed request waited too long in the queue"
    static let pollInterval: Duration = .milliseconds(10)

    /// The queue's bounds for one local server, fixed when it starts.
    struct Limits: Equatable, Sendable {
        /// Requests that may wait behind the running ones.
        let maximumWaiting: Int

        init(maximumWaiting: Int = DistributedRequestQueue.defaultMaximumWaiting) {
            self.maximumWaiting = min(max(0, maximumWaiting), DistributedRequestQueue.maximumWaitingBound)
        }

        static let standard = Limits()

        /// The owner's setting, or the default when it names none. A value
        /// that is not an integer in 0...1024 is not served: the default is.
        static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Limits {
            guard let raw = environment[DistributedRequestQueue.waitingEnvironmentName]?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let value = Int(raw), (0...DistributedRequestQueue.maximumWaitingBound).contains(value) else {
                return .standard
            }
            return Limits(maximumWaiting: value)
        }

        /// Live HTTP responses at once (`DistributedHTTPResponses.limit`):
        /// the most lanes a pair runs and the queue behind them.
        var responseLimit: Int { maximumWaiting + DistributedRequestQueue.maximumLanes }

        /// The longest one request may wait: with `lanes` running at once, a
        /// request behind a full queue gets a lane after at most
        /// `maximumWaiting / lanes + 1` request lifetimes (each request ahead
        /// ends by its own deadline).
        func waitCeiling(requestTimeout: Duration, lanes: Int) -> Duration {
            let lanes = max(1, lanes)
            return requestTimeout * ((maximumWaiting + lanes) / lanes)
        }
    }
}
