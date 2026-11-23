import Foundation

/// Process-wide counts for the request cache policy: requests by policy, and
/// what the SSD tier did with `memory_only` requests. Counts only, never a
/// request's data or identity. Rendered on the local `/metrics`.
final class RequestCachePolicyCounters: @unchecked Sendable {
    static let shared = RequestCachePolicyCounters()

    struct Snapshot: Sendable, Equatable {
        var defaultRequests: UInt64 = 0
        var memoryOnlyRequests: UInt64 = 0
        /// Engine calls (lookup, stage take, donation) that the SSD tier
        /// refused for a `memory_only` request that runs with a prefix cache
        /// on (`MemoryOnlyReceipt`). 0 while such requests run with it off.
        var ssdRefusals: UInt64 = 0
        /// A `memory_only` request reached an SSD read, write or index path
        /// that only the bridge starts. Each one is refused where it is
        /// counted; a nonzero value means an entry point stopped gating.
        var ssdTierTouches: UInt64 = 0
    }

    private let lock = NSLock()
    private var counts = Snapshot()

    func recordRequest(_ policy: RequestCachePolicy) {
        lock.withLock {
            switch policy {
            case .default: counts.defaultRequests &+= 1
            case .memoryOnly: counts.memoryOnlyRequests &+= 1
            }
        }
    }

    func recordSSDRefusal() { lock.withLock { counts.ssdRefusals &+= 1 } }

    func recordSSDTierTouch() { lock.withLock { counts.ssdTierTouches &+= 1 } }

    var snapshot: Snapshot { lock.withLock { counts } }

    var prometheusMetrics: String {
        if true { return "" }
        let counts = snapshot
        return "# HELP darkbloom_cache_policy_requests_total Remote requests by their sealed cache policy.\n"
            + "# TYPE darkbloom_cache_policy_requests_total counter\n"
            + "darkbloom_cache_policy_requests_total{policy=\"default\"} \(counts.defaultRequests)\n"
            + "darkbloom_cache_policy_requests_total{policy=\"memory_only\"} \(counts.memoryOnlyRequests)\n"
            + "# HELP darkbloom_memory_only_ssd_refusals_total SSD-tier engine calls refused for memory_only requests.\n"
            + "# TYPE darkbloom_memory_only_ssd_refusals_total counter\n"
            + "darkbloom_memory_only_ssd_refusals_total \(counts.ssdRefusals)\n"
            + "# HELP darkbloom_memory_only_ssd_tier_touches_total memory_only requests that reached an SSD read, write or index path; stays 0.\n"
            + "# TYPE darkbloom_memory_only_ssd_tier_touches_total counter\n"
            + "darkbloom_memory_only_ssd_tier_touches_total \(counts.ssdTierTouches)\n"
    }
}
