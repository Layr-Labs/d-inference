import Foundation
import Testing
@testable import ProviderCore

/// The pair slot's owner wraps the session's execution owner; the slot's
/// engine admits as many requests at once as that owner's batch lanes.
struct ClusterPairSlotOwnerLanesTests {
    @Test func theSlotOwnerForwardsThePairsLanes() {
        let inner = DistributedTestOwner()
        #expect(ClusterPairSlotOwner(inner).concurrentRequests == 1)
        inner.lanes = 8
        #expect(ClusterPairSlotOwner(inner).concurrentRequests == 8)
    }
}
