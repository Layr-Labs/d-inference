import Foundation
import Testing
@testable import ProviderCore

@Suite("SSD block index eviction order")
struct SSDBlockIndexTests {
    @Test("Oldest probe keeps deterministic order after touches and removals")
    func oldestProbe() {
        let index = SSDBlockIndex()
        #expect(index.oldest() == nil)
        let tags = [Data([3]), Data([1]), Data([2])]
        for tag in tags { index.insert(tag16: tag, fileBytes: 10, lastAccess: 5) }
        #expect(index.oldest()?.tag16 == Data([1]))
        #expect(index.oldestEntries().map(\.tag16) == [Data([1]), Data([2]), Data([3])])
        index.touch(tags16: [Data([1])], now: 6)
        #expect(index.oldest()?.tag16 == Data([2]))
        #expect(index.remove(tag16: Data([2])) == 10)
        #expect(index.oldest()?.tag16 == Data([3]))
        #expect(index.oldest()?.fileBytes == 10)
        #expect(index.oldest()?.lastAccess == 5)
        index.removeAll()
        #expect(index.oldest() == nil)
    }
}
