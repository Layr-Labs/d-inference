import Foundation
import Testing
@testable import ProviderCore

@Suite("Checkpoint demand and write priority", .serialized)
struct SSDCheckpointDemandTests {
    @Test("first-seen tags remain distinct, expire, and cannot grow metadata beyond the bound")
    func boundedDemand() {
        let demand = SSDCheckpointDemand(limit: 2, ttlSeconds: 60)
        let a = Data([1]), b = Data([2]), c = Data([3])
        #expect(!demand.observe(a, now: 100))
        #expect(!demand.observe(b, now: 101))
        #expect(demand.observe(a, now: 110))
        #expect(!demand.observe(c, now: 111))
        #expect(demand.count == 2)
        #expect(demand.observe(a, now: 112))
        #expect(!demand.observe(a, now: 172))
        #expect(!demand.observe(a, now: 171))
    }

    @Test("novel writes preserve a reserve that repeated prefixes can use without raising the cap")
    func repeatReserve() {
        let limiter = SSDWriteRateLimiter(capBytesPerDay: 1000, repeatReserveFraction: 0.1, nowSeconds: { 0 })
        #expect(limiter.tryConsume(bytes: 900, repeated: false))
        #expect(!limiter.mightAccept(bytes: 1, repeated: false))
        #expect(!limiter.tryConsume(bytes: 1, repeated: false))
        #expect(limiter.mightAccept(bytes: 100))
        #expect(limiter.tryConsume(bytes: 100))
        #expect(!limiter.tryConsume(bytes: 1))
        let unlimited = SSDWriteRateLimiter(capBytesPerDay: 0)
        #expect(unlimited.tryConsume(bytes: 1 << 30, repeated: false))
    }
    @Test("a repeated checkpoint can use the reserve and durable duplicates do not consume more writes")
    func repeatedCheckpointSurvivesWritePressure() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let cap = 1 << 30
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.rateLimiter.tryConsume(bytes: Int(Double(cap) * 0.9), repeated: false))
        #expect(try await fixture.donate(store).isEmpty)
        #expect(store.stats().filesWritten == 0)
        #expect(outcomes.snapshot().contains { $0.outcome == .writePriorityLimited && $0.count == 1 })
        #expect(try await fixture.donate(store) == [256])
        #expect(try await fixture.donate(store) == [256])
        #expect(store.stats().filesWritten == 1)
        let hit = await store.stage(requestID: .init(888), request: fixture.request(),
            reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(hit.staged)
        await store.abandonStaging(requestID: .init(888))
        await store.closeAndWait()
    }

    @Test("novel writes refill promptly and a backwards clock cannot mint write allowance")
    func independentRefillAndClock() {
        final class Clock: @unchecked Sendable {
            var now: Double = 0
        }
        let clock = Clock()
        let limiter = SSDWriteRateLimiter(capBytesPerDay: 1000, repeatReserveFraction: 0.1,
                                          nowSeconds: { clock.now })
        #expect(limiter.tryConsume(bytes: 900, repeated: false))
        #expect(limiter.tryConsume(bytes: 100))
        clock.now = 8640
        #expect(limiter.tryConsume(bytes: 80, repeated: false))
        #expect(limiter.tryConsume(bytes: 20))
        clock.now = 0
        #expect(!limiter.tryConsume(bytes: 1))
        clock.now = 8640
        #expect(!limiter.tryConsume(bytes: 1))
        #expect(!limiter.tryConsume(bytes: -1))
        #expect(!limiter.mightAccept(bytes: -1))
    }

}
