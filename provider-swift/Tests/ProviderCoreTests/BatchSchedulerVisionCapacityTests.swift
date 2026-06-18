import Foundation
import Testing
@testable import ProviderCore

// Regression for the VLM load under-report behind the gemma-4 over-admission
// incident: the vision/media path serves through the container's non-batched
// prepare/generate route and reserves memory via `reserveVisionRequest` instead
// of inserting an `activeBridges` entry. `capacity().activeRequests` used to be
// `activeBridges.count` alone, so a provider busy with N concurrent media
// requests reported itself idle to the coordinator, which routes on that count —
// inviting over-admission. These pin that in-flight vision requests now count
// toward the reported active concurrency, and that the lifecycle (reserve →
// release, failed reserve, cancelAll) keeps the count exact.

private let gib: UInt64 = 1024 * 1024 * 1024

@Suite("BatchScheduler vision capacity accounting")
struct BatchSchedulerVisionCapacityTests {

    @Test("in-flight vision request counts toward capacity().activeRequests")
    func visionReservationBumpsActiveRequests() async {
        let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
        }
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: budget)

        #expect(await scheduler.activeRequestCount == 0)

        let ok = await scheduler.reserveVisionRequest(
            requestId: "vlm-1", mediaDecodeBytes: 1024, kvTokens: 8)
        #expect(ok, "reservation must fit against an 8 GiB budget")
        #expect(await scheduler.activeRequestCount == 1,
            "an in-flight media request must be visible to the coordinator")

        await scheduler.releaseVisionRequest(requestId: "vlm-1")
        #expect(await scheduler.activeRequestCount == 0,
            "release must restore the idle count")
    }

    @Test("concurrent vision requests sum; release is idempotent")
    func concurrentVisionRequestsSumAndReleaseIsIdempotent() async {
        let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
        }
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: budget)

        for id in ["a", "b", "c"] {
            _ = await scheduler.reserveVisionRequest(
                requestId: id, mediaDecodeBytes: 1024, kvTokens: 8)
        }
        #expect(await scheduler.activeRequestCount == 3)

        // The VLM stream releases on finish, on throw, AND on onTermination, so
        // the same id can be released more than once. The count must not go
        // negative or double-decrement.
        await scheduler.releaseVisionRequest(requestId: "a")
        await scheduler.releaseVisionRequest(requestId: "a")
        #expect(await scheduler.activeRequestCount == 2,
            "a double release of one id must drop the count by exactly one")
    }

    @Test("a rejected vision reservation does not inflate the active count")
    func rejectedReservationDoesNotCount() async {
        // capFraction 1.0 of a 2 GiB total collapses to the hardCap OS floor (0),
        // so any positive-byte reservation is rejected.
        let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(total: 2 * gib, active: 0, cache: 0, systemAvailable: 0)
        }
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: budget)

        let ok = await scheduler.reserveVisionRequest(
            requestId: "rejected", mediaDecodeBytes: 4 * gib, kvTokens: 1_000_000)
        #expect(!ok, "an over-budget media reservation must be rejected")
        #expect(await scheduler.activeRequestCount == 0,
            "a rejected reserve never starts generation, so it must not be counted")
    }

    @Test("budgeting disabled (nil budget) still tracks in-flight vision load")
    func nilBudgetStillTracksLoad() async {
        // Legacy "always proceed" path: no kvBudget. The request still runs and
        // occupies the model, so it must still be reported as active.
        let scheduler = BatchScheduler(maxConcurrentRequests: 4, defaultMaxTokens: 4096)

        let ok = await scheduler.reserveVisionRequest(
            requestId: "vlm-nobudget", mediaDecodeBytes: 1024, kvTokens: 8)
        #expect(ok, "nil budget always proceeds")
        #expect(await scheduler.activeRequestCount == 1,
            "even with budgeting disabled, in-flight media must be reported as load")

        await scheduler.releaseVisionRequest(requestId: "vlm-nobudget")
        #expect(await scheduler.activeRequestCount == 0)
    }

    @Test("activeRequestCount sums batched (text) bridges and vision requests")
    func textBridgesAndVisionRequestsSumTogether() async {
        let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
        }
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: budget)

        // Two text (batched) requests via the activeBridges path...
        await scheduler._testSeedBridge(id: "text-1", promptTokens: 100, maxTokens: 50)
        await scheduler._testSeedBridge(id: "text-2", promptTokens: 100, maxTokens: 50)
        // ...and one vision request via the non-batched reservation path.
        _ = await scheduler.reserveVisionRequest(
            requestId: "vlm-1", mediaDecodeBytes: 1024, kvTokens: 8)

        #expect(await scheduler.activeRequestCount == 3,
            "the reported active count must be text bridges + in-flight vision, not either alone")
    }

    @Test("cancelAll clears in-flight vision reservations")
    func cancelAllClearsVisionRequests() async {
        let budget = GlobalKVCacheBudget(capFraction: 1.0, activationReserveBytes: 0) {
            GlobalKVCacheBudget.MemorySnapshot(total: 8 * gib, active: 0, cache: 0, systemAvailable: .max)
        }
        let scheduler = BatchScheduler(
            maxConcurrentRequests: 4, defaultMaxTokens: 4096, kvBudget: budget)

        for id in ["x", "y"] {
            _ = await scheduler.reserveVisionRequest(
                requestId: id, mediaDecodeBytes: 1024, kvTokens: 8)
        }
        #expect(await scheduler.activeRequestCount == 2)

        await scheduler.cancelAll()
        #expect(await scheduler.activeRequestCount == 0,
            "a drain/cancelAll must release vision reservations like it does bridges")
    }
}
