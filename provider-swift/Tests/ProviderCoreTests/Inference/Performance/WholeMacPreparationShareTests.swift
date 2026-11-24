import Foundation
import Testing
@testable import ProviderCore

/// `WholeMacServiceBudget.acquirePreparation`: a prompt being prepared holds
/// one serving share, which its owner's `acquire` takes over in place.
@Suite("A prompt preparation's serving share")
struct WholeMacPreparationShareTests {
    @Test("other requests' preparation shares are occupied capacity")
    func preparationsFillTheWidth() {
        let budget = WholeMacServiceBudget()
        #expect(budget.acquirePreparation(ownerID: "a", concurrency: 2))
        #expect(budget.acquirePreparation(ownerID: "b", concurrency: 2))
        #expect(!budget.acquirePreparation(ownerID: "c", concurrency: 2))
        #expect(!budget.acquire(ownerID: "c", concurrency: 2))
        budget.releasePreparation(ownerID: "b")
        #expect(budget.acquire(ownerID: "c", concurrency: 2))
    }

    @Test("the owner's acquire takes its share over on a full Mac, and a later release of the preparation keeps it")
    func acquireTakesTheShareOver() {
        let budget = WholeMacServiceBudget()
        #expect(budget.acquire(ownerID: "busy", concurrency: 2))
        #expect(budget.acquirePreparation(ownerID: "a", concurrency: 2))
        #expect(budget.acquire(ownerID: "a", concurrency: 2))
        #expect(budget.preparationCount == 0)
        budget.releasePreparation(ownerID: "a")
        #expect(budget.count == 2)
        #expect(budget.usedFraction == 1)
        budget.release(ownerID: "a")
        #expect(budget.count == 1)
    }

    @Test("a share is held once per owner, and a continuation may still take its stopped row's place")
    func oneSharePerOwner() {
        let budget = WholeMacServiceBudget()
        #expect(budget.acquirePreparation(ownerID: "a", concurrency: 1))
        #expect(!budget.acquirePreparation(ownerID: "a", concurrency: 1))
        #expect(budget.acquirePreparation(ownerID: "b", concurrency: 1, overcommit: true))
        budget.releasePreparation(ownerID: "a")
        budget.releasePreparation(ownerID: "b")
        #expect(budget.preparationCount == 0)
    }

    @Test("reported usage and idleness start at acquire, as before")
    func reportingStartsAtAcquire() {
        let budget = WholeMacServiceBudget()
        #expect(budget.acquirePreparation(ownerID: "a", concurrency: 2))
        #expect(budget.usedFraction == 0)
        #expect(budget.isIdle)
        #expect(budget.snapshot().usedFraction == 0)
        budget.releasePreparation(ownerID: "a")
    }

    @Test("the idle prefill-evidence recovery cannot take the whole Mac beside another preparation")
    func recoveryWaitsForOtherPreparations() {
        let budget = WholeMacServiceBudget()
        #expect(budget.acquirePreparation(ownerID: "other", concurrency: 4))
        #expect(budget.acquirePreparation(ownerID: "a", concurrency: 4))
        #expect(!budget.acquire(ownerID: "a", concurrency: 1, requiresIdle: true))
        budget.releasePreparation(ownerID: "other")
        #expect(budget.acquire(ownerID: "a", concurrency: 1, requiresIdle: true))
        #expect(budget.preparationCount == 0)
    }
}
