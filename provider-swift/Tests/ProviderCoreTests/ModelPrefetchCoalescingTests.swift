import Foundation
import Testing

@testable import ProviderCore


@Suite("ModelPrefetchCoordinator coalescing", .serialized)
struct ModelPrefetchCoalescingTests {

    @Test("duplicate concurrent prefetches for the same model coalesce to one download")
    func duplicatesCoalesce() async throws {
        let prefetcher = FakePrefetcher(.blockUntilCancelled)
        let coord = makeCoordinator(prefetcher: prefetcher)
        let sinkA = RecordingSink()
        let sinkB = RecordingSink()

        await coord.handlePrefetch(modelId: "org/dup", priority: 1, sink: sinkA)
        await prefetcher.started.wait() // first task is running
        // Second request for the SAME id while the first is in flight.
        await coord.handlePrefetch(modelId: "org/dup", priority: 1, sink: sinkB)

        // Both subscribers got their own `.started`.
        #expect(sinkA.statuses.first == .started)
        #expect(sinkB.statuses.first == .started)
        // Only ONE underlying download task exists, and the fake was invoked once.
        let inflight = await coord.inFlightCount()
        #expect(inflight == 1)
        #expect(prefetcher.callCount == 1)

        await coord.shutdown(timeout: .seconds(3))
    }
}
