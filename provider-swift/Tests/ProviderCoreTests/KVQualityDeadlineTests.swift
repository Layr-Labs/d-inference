import Foundation
import Testing
@testable import ProviderBenchmark

@Suite("Bounded quality deadline ownership")
struct KVQualityDeadlineTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    @Test func expiredDeadlineFiresOnce() async {
        let counter = Counter()
        let deadline = KVQualityDeadline.start(startedAt: 0, maximumNanoseconds: 1) {
            counter.increment()
        }
        await deadline.value
        #expect(counter.value == 1)
    }

    @Test func cancelledDeadlinesRetireWithoutCancellingCompletedCases() async {
        let counter = Counter()
        var deadlines: [Task<Void, Never>] = []
        for _ in 0..<256 {
            deadlines.append(KVQualityDeadline.start(startedAt: DispatchTime.now().uptimeNanoseconds) {
                counter.increment()
            })
        }
        deadlines.forEach { $0.cancel() }
        for deadline in deadlines { await deadline.value }
        #expect(counter.value == 0)
    }
}
