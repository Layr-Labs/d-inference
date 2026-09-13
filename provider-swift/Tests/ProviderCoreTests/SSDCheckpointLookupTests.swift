import Foundation
import Testing
@testable import ProviderCore

@Suite("Complete SSD checkpoint lookup")
struct SSDCheckpointLookupTests {
    @Test func expiryBoundaryAndClockExtremes() {
        let index = SSDBlockIndex()
        let tag = Data(repeating: 1, count: 16)
        index.insert(tag16: tag, fileBytes: 123, lastAccess: 100)
        #expect(index.freshFileBytes(tag16: tag, now: 109, ttlSeconds: 10) == 123)
        #expect(index.freshFileBytes(tag16: tag, now: 110, ttlSeconds: 10) == nil)
        // Disabled expiry and a clock moving backwards preserve the entry.
        #expect(index.freshFileBytes(tag16: tag, now: Int64.max, ttlSeconds: 0) == 123)
        #expect(index.freshFileBytes(tag16: tag, now: 99, ttlSeconds: 10) == 123)
        index.insert(tag16: tag, fileBytes: 456, lastAccess: Int64.min)
        #expect(index.freshFileBytes(tag16: tag, now: Int64.max, ttlSeconds: 10) == nil)
        // Expiry lookup does not remove storage or mutate its accounting.
        #expect(index.usageSnapshot().entries == 1)
        #expect(index.usageSnapshot().bytes == 456)
    }

    @Test func probingDoesNotRefreshAndMutationsAreVisible() {
        let index = SSDBlockIndex()
        let tag = Data(repeating: 1, count: 16)
        let unrelated = Data(repeating: 2, count: 16)
        index.insert(tag16: unrelated, fileBytes: 900, lastAccess: 0)
        #expect(index.freshFileBytes(tag16: tag, now: 109, ttlSeconds: 10) == nil)
        index.insert(tag16: tag, fileBytes: 123, lastAccess: 100)
        #expect(index.freshFileBytes(tag16: tag, now: 109, ttlSeconds: 10) == 123)
        #expect(index.freshFileBytes(tag16: tag, now: 110, ttlSeconds: 10) == nil)
        index.touch(tags16: [tag], now: 110)
        #expect(index.freshFileBytes(tag16: tag, now: 119, ttlSeconds: 10) == 123)
        index.insert(tag16: tag, fileBytes: 456, lastAccess: 115)
        #expect(index.freshFileBytes(tag16: tag, now: 120, ttlSeconds: 10) == 456)
        index.remove(tag16: tag)
        #expect(index.freshFileBytes(tag16: tag, now: 120, ttlSeconds: 10) == nil)
        #expect(index.usageSnapshot().entries == 1)
        #expect(index.usageSnapshot().bytes == 900)
    }
}
