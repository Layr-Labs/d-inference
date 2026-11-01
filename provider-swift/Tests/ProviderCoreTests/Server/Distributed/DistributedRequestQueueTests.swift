import Foundation
import Testing
@testable import ProviderCore

/// The local API's queue bounds: the waiting depth an owner may set, the
/// responses it implies and how long one waiter may wait.
struct DistributedRequestQueueTests {
    @Test func theDefaultDepthIsTheSingleMacEngines() {
        #expect(DistributedRequestQueue.Limits.standard.maximumWaiting == 64)
        #expect(DistributedRequestQueue.Limits.fromEnvironment([:]) == .standard)
        // Every waiter and every lane holds one live response.
        #expect(DistributedRequestQueue.Limits.standard.responseLimit == 64 + DistributedRequestQueue.maximumLanes)
        #expect(DistributedHTTPResponses().limit == DistributedRequestQueue.Limits.standard.responseLimit)
    }

    @Test func theOwnersEnvironmentSetsTheDepthWithinItsBound() {
        let name = DistributedRequestQueue.waitingEnvironmentName
        #expect(DistributedRequestQueue.Limits.fromEnvironment([name: " 16 "]).maximumWaiting == 16)
        #expect(DistributedRequestQueue.Limits.fromEnvironment([name: "0"]).maximumWaiting == 0)
        #expect(DistributedRequestQueue.Limits.fromEnvironment([name: "1024"]).maximumWaiting == 1024)
        // Outside 0...1024 or not a number: the default, never a larger queue.
        for raw in ["1025", "-1", "many", ""] {
            #expect(DistributedRequestQueue.Limits.fromEnvironment([name: raw]) == .standard, "\(raw)")
        }
        #expect(DistributedRequestQueue.Limits(maximumWaiting: 5000).maximumWaiting == 1024)
    }

    /// A waiter behind a full queue gets a lane after at most
    /// `waiting / lanes + 1` request lifetimes.
    @Test func theWaitCeilingCountsTheLanesAhead() {
        let limits = DistributedRequestQueue.Limits(maximumWaiting: 8)
        #expect(limits.waitCeiling(requestTimeout: .seconds(10), lanes: 1) == .seconds(90))
        #expect(limits.waitCeiling(requestTimeout: .seconds(10), lanes: 8) == .seconds(20))
        #expect(limits.waitCeiling(requestTimeout: .seconds(10), lanes: 0) == .seconds(90))
        #expect(DistributedRequestQueue.Limits.standard.waitCeiling(requestTimeout: .seconds(1), lanes: 8) == .seconds(9))
        #expect(DistributedRequestQueue.Limits(maximumWaiting: 0).waitCeiling(requestTimeout: .seconds(3), lanes: 4) == .seconds(3))
    }
}
