import Foundation

// The pair's leader takes local requests beside Darkbloom. Red-test scaffolding
// only: the counts the tests read. The next commit implements them.

extension ProviderLoop {
    /// Local requests waiting for one of the pair's lanes.
    var clusterPairLocalWaitingCount: Int { 0 }
    /// The owner's use of the pair through this Mac's API: local requests
    /// waiting for a lane or holding one.
    var clusterPairLocalRequestsInUse: Int { 0 }
    func setClusterPairLocalQueueForTesting(maximumWaiting: Int) {}
}
