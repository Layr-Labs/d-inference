import Foundation
import Testing

@testable import ProviderCore

@Suite("ModelPrefetchCoordinator queue", .serialized)
struct ModelPrefetchQueueTests {

    @Test("higher-priority queued prefetch is serviced before lower-priority ones")
    func priorityOrdering() async throws {
        // Single in-flight slot: while one download runs, the rest queue and the
        // scheduler must dispatch them strictly by priority (highest first).
        let prefetcher = GatedPrefetcher()
        let advertised = AdvertisedRecorder()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { _ in .needsFetch },
            onVerified: { id in advertised.record(id) },
            maxConcurrent: 1
        )

        let sinkLow = RecordingSink()
        let sinkHigh = RecordingSink()
        let sinkMid = RecordingSink()

        // 1) Low-priority request dispatches immediately and parks in its body.
        await coord.handlePrefetch(modelId: "org/low", priority: 1, sink: sinkLow)
        await prefetcher.bodyStarted.wait()
        let runningFirst = await coord.inFlightCount()
        #expect(runningFirst == 1)
        #expect(prefetcher.startOrder == ["org/low"]) // low is the one in flight

        // 2) While low is in flight, enqueue mid then high (mid arrives FIRST but
        //    is lower priority, proving the scheduler orders by priority, not by
        //    arrival).
        await coord.handlePrefetch(modelId: "org/mid", priority: 5, sink: sinkMid)
        await coord.handlePrefetch(modelId: "org/high", priority: 10, sink: sinkHigh)
        let queued = await coord.queuedCount()
        #expect(queued == 2)
        let stillOne = await coord.inFlightCount()
        #expect(stillOne == 1) // bounded concurrency: still just low running

        // 3) Release low → slot frees → scheduler must pick HIGH (10) over MID (5).
        prefetcher.release("org/low")
        await prefetcher.bodyStarted.wait()
        #expect(prefetcher.startOrder == ["org/low", "org/high"])
        let queuedAfterHigh = await coord.queuedCount()
        #expect(queuedAfterHigh == 1) // mid still waiting

        // 4) Release high → slot frees → only MID remains.
        prefetcher.release("org/high")
        await prefetcher.bodyStarted.wait()
        #expect(prefetcher.startOrder == ["org/low", "org/high", "org/mid"])

        // 5) Drain: release mid and let everything verify.
        prefetcher.release("org/mid")
        _ = await sinkLow.waitForTerminal()
        _ = await sinkHigh.waitForTerminal()
        _ = await sinkMid.waitForTerminal()
        #expect(sinkLow.terminal()?.status == .verified)
        #expect(sinkHigh.terminal()?.status == .verified)
        #expect(sinkMid.terminal()?.status == .verified)
        // All three re-advertised (order: completion order = low, high, mid).
        #expect(Set(advertised.ids) == ["org/low", "org/high", "org/mid"])
        let drained = await coord.inFlightCount()
        #expect(drained == 0)

        await coord.shutdown(timeout: .seconds(3))
    }

    @Test("a more-urgent duplicate promotes a queued request ahead of the queue")
    func duplicatePromotesPriority() async throws {
        // low runs; A (prio 2) and B (prio 3) queue. A second request for A with
        // a HIGHER priority (5) must promote A ahead of B, without a 2nd download.
        let prefetcher = GatedPrefetcher()
        let coord = ModelPrefetchCoordinator(
            prefetcher: prefetcher,
            preCheck: { _ in .needsFetch },
            onVerified: { _ in },
            maxConcurrent: 1
        )
        let sinkLow = RecordingSink()
        let sinkA1 = RecordingSink()
        let sinkB = RecordingSink()
        let sinkA2 = RecordingSink()

        await coord.handlePrefetch(modelId: "org/low", priority: 1, sink: sinkLow)
        await prefetcher.bodyStarted.wait()

        await coord.handlePrefetch(modelId: "org/A", priority: 2, sink: sinkA1)
        await coord.handlePrefetch(modelId: "org/B", priority: 3, sink: sinkB)
        // Re-request A at higher priority than B → promotes A. Coalesces (no new
        // queue entry, no second download).
        await coord.handlePrefetch(modelId: "org/A", priority: 5, sink: sinkA2)
        let queued = await coord.queuedCount()
        #expect(queued == 2) // still only A and B queued (A coalesced)

        prefetcher.release("org/low")
        await prefetcher.bodyStarted.wait()
        // A (now prio 5) jumps ahead of B (prio 3).
        #expect(prefetcher.startOrder == ["org/low", "org/A"])

        prefetcher.release("org/A")
        await prefetcher.bodyStarted.wait()
        #expect(prefetcher.startOrder == ["org/low", "org/A", "org/B"])
        // A was downloaded exactly once despite two requests (coalesced).
        let aStarts = prefetcher.startOrder.filter { $0 == "org/A" }.count
        #expect(aStarts == 1)
        // Both A subscribers see the same lifecycle (each got its own .started).
        #expect(sinkA1.statuses.first == .started)
        #expect(sinkA2.statuses.first == .started)

        prefetcher.release("org/B")
        await coord.shutdown(timeout: .seconds(3))
    }
}
