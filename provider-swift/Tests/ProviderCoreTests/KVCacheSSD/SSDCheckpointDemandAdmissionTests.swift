import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// Demand-gated complete-checkpoint admission: with a coordinator hint the
/// store writes only for observed fleet-wide repeat demand, a local repeat or
/// first sight; without one it keeps writing every captured checkpoint.
@Suite("Checkpoint demand-gated admission", .serialized)
struct SSDCheckpointDemandAdmissionTests {
    private func outcome(_ recorder: PrefixCacheDonationTelemetry, _ outcome: PrefixCacheDonationOutcome) -> UInt64 {
        recorder.snapshot().first { $0.outcome == outcome }?.count ?? 0
    }

    @Test("write class matrix")
    func writeClassMatrix() {
        typealias D = SSDCheckpointDonationDemand
        func writeClass(
            _ demand: D?, localRepeat: Bool = false, restored: Bool = false, floor: Int = 256
        ) -> SSDWriteClass? {
            SSDCheckpointDemand.writeClass(
                demand: demand, localRepeat: localRepeat, restored: restored, minEffectiveTokens: floor)
        }
        // No hint keeps the legacy write, whatever else is known.
        #expect(writeClass(nil) == .novel)
        #expect(writeClass(nil, restored: true) == .novel)
        // Fleet-novel: no repeat and no first sight.
        #expect(writeClass(D(repeatedPrefixTokens: 0)) == nil)
        #expect(writeClass(D(repeatedPrefixTokens: 255)) == nil)
        // A restore alone never creates demand the coordinator did not send.
        #expect(writeClass(D(repeatedPrefixTokens: 0), restored: true) == nil)
        // A coordinator repeat at the floor keeps the novel-share class.
        #expect(writeClass(D(repeatedPrefixTokens: 256)) == .novel)
        #expect(writeClass(D(repeatedPrefixTokens: 256, firstSightTokens: 1024)) == .novel)
        // First sight alone is speculative, and only from the floor up.
        #expect(writeClass(D(repeatedPrefixTokens: 0, firstSightTokens: 256)) == .speculative)
        #expect(writeClass(D(repeatedPrefixTokens: 255, firstSightTokens: 256)) == .speculative)
        #expect(writeClass(D(repeatedPrefixTokens: 0, firstSightTokens: 255)) == nil)
        // Restoring from this store proves the prefix was written here before.
        #expect(writeClass(D(repeatedPrefixTokens: 0, firstSightTokens: 256), restored: true) == .novel)
        #expect(writeClass(D(repeatedPrefixTokens: 0, firstSightTokens: 255), restored: true) == nil)
        // A local repeat outranks every coordinator count.
        #expect(writeClass(nil, localRepeat: true) == .repeated)
        #expect(writeClass(D(repeatedPrefixTokens: 0), localRepeat: true) == .repeated)
        #expect(writeClass(D(repeatedPrefixTokens: 0, firstSightTokens: 256), localRepeat: true) == .repeated)
        #expect(D(repeatedPrefixTokens: -1).repeatedPrefixTokens == 0)
        #expect(D(repeatedPrefixTokens: 0, firstSightTokens: -1).firstSightTokens == 0)
        #expect(D(repeatedPrefixTokens: 256).firstSightTokens == 0)
        // A zero floor still requires a positive count: 0 means "none".
        #expect(writeClass(D(repeatedPrefixTokens: 0), floor: 0) == nil)
        #expect(writeClass(D(repeatedPrefixTokens: 1), floor: 0) == .novel)
        #expect(writeClass(D(repeatedPrefixTokens: 0, firstSightTokens: 1), floor: 0) == .speculative)
    }

    @Test("a fleet-novel checkpoint is skipped without writing bytes or charging write budget")
    func novelHintSkipsWrite() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let cap = 1 << 30
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        let novelBudget = Int(Double(cap) * 0.9)
        #expect(store.rateLimiter.mightAccept(bytes: novelBudget, repeated: false))
        #expect(store.rateLimiter.mightAccept(bytes: cap, repeated: true))

        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(10))
        #expect(try await fixture.donate(store, receipt: 10).isEmpty)
        #expect(outcome(outcomes, .skippedNovel) == 1)
        #expect(store.stats().filesWritten == 0)
        #expect(store.stats().entries == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(store).path))
        // The whole novel share and the whole total budget are still
        // available: nothing was charged.
        #expect(store.rateLimiter.mightAccept(bytes: novelBudget, repeated: false))
        #expect(store.rateLimiter.mightAccept(bytes: cap, repeated: true))
        // The tag was still recorded locally.
        #expect(store.writeDemand.count == 1)

        // Contrast: a real write does charge the budget. The same tag is now
        // a local repeat, so it debits the total budget, not the novel share.
        store.registerDonationDemand(.init(repeatedPrefixTokens: 256), requestID: .init(11))
        #expect(try await fixture.donate(store, receipt: 11) == [256])
        #expect(outcome(outcomes, .donated) == 1)
        #expect(!store.rateLimiter.mightAccept(bytes: cap, repeated: true))
        #expect(store.rateLimiter.mightAccept(bytes: novelBudget, repeated: false))
        await store.closeAndWait()
    }

    @Test("a hint below the effective-token floor is still novel")
    func hintBelowFloorSkips() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        #expect(store.config.minEffectiveTokens == 256)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 128), requestID: .init(12))
        #expect(try await fixture.donate(store, receipt: 12).isEmpty)
        #expect(outcome(outcomes, .skippedNovel) == 1)
        #expect(store.stats().filesWritten == 0)
        await store.closeAndWait()
    }

    @Test("a frame with first sight and no repeat count is speculative, not legacy")
    func firstSightWithoutRepeatCountIsSpeculative() {
        let firstSightOnly = RemotePrefixCacheContext(
            cacheScope: "tenant-a", cacheReceiptNonce: "nonce", firstSightTokens: 2_048)
        #expect(firstSightOnly.donationDemand
            == SSDCheckpointDonationDemand(repeatedPrefixTokens: 0, firstSightTokens: 2_048))
        #expect(SSDCheckpointDemand.writeClass(
            demand: firstSightOnly.donationDemand, localRepeat: false, restored: false,
            minEffectiveTokens: 256) == .speculative)
        // Neither count, or first sight outside any cache scope, is no hint.
        #expect(RemotePrefixCacheContext(cacheScope: "tenant-a", cacheReceiptNonce: "nonce").donationDemand == nil)
        #expect(RemotePrefixCacheContext(
            cacheScope: "tenant-a", cacheReceiptNonce: "nonce", firstSightTokens: 0).donationDemand == nil)
        #expect(RemotePrefixCacheContext(
            cacheScope: nil, cacheReceiptNonce: "nonce", firstSightTokens: 2_048).donationDemand == nil)
    }

    @Test("first sight below the effective-token floor is skipped as novel")
    func firstSightBelowFloorSkips() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        store.registerDonationDemand(.init(repeatedPrefixTokens: 0, firstSightTokens: 128), requestID: .init(26))
        #expect(try await fixture.donate(store, receipt: 26).isEmpty)
        #expect(outcome(outcomes, .skippedNovel) == 1)
        #expect(outcome(outcomes, .writeSpeculativeLimited) == 0)
        #expect(store.stats().filesWritten == 0)
        await store.closeAndWait()
    }

    @Test("a hint at or above the floor writes")
    func hintAtFloorDonates() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        store.registerDonationDemand(.init(repeatedPrefixTokens: 4096), requestID: .init(13))
        #expect(try await fixture.donate(store, receipt: 13) == [256])
        #expect(outcome(outcomes, .donated) == 1)
        #expect(outcome(outcomes, .skippedNovel) == 0)
        #expect(store.stats().filesWritten == 1)
        await store.closeAndWait()
    }

    @Test("a local second sighting qualifies even when the coordinator hint is 0")
    func localRepeatDonatesDespiteNovelHint() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(14))
        #expect(try await fixture.donate(store, receipt: 14).isEmpty)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(15))
        #expect(try await fixture.donate(store, receipt: 15) == [256])
        #expect(outcome(outcomes, .skippedNovel) == 1)
        #expect(outcome(outcomes, .donated) == 1)
        #expect(store.stats().filesWritten == 1)
        await store.closeAndWait()
    }

    @Test("without a hint (older coordinator, standalone) every checkpoint is written as before")
    func absentHintKeepsLegacyWrite() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        #expect(store.donationDemandHints.demand(for: .init(16)) == nil)
        #expect(try await fixture.donate(store, receipt: 16) == [256])
        #expect(outcome(outcomes, .donated) == 1)
        #expect(outcome(outcomes, .skippedNovel) == 0)
        await store.closeAndWait()
    }

    @Test("durable duplicates bypass the gate and still settle already_durable")
    func durableDuplicateBypassesGate() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let first = try fixture.makeStore()
        first.registerDonationDemand(.init(repeatedPrefixTokens: 1024), requestID: .init(17))
        #expect(try await fixture.donate(first, receipt: 17) == [256])
        await first.closeAndWait()

        // A restarted store has an empty local history and a novel hint, yet
        // the checkpoint is already on disk: revalidate, do not skip.
        let outcomes = PrefixCacheDonationTelemetry()
        let second = try fixture.makeStore(donationRecorder: outcomes)
        defer { second.close() }
        #expect(second.stats().entries == 1)
        second.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(18))
        #expect(try await fixture.donate(second, receipt: 18) == [256])
        #expect(outcome(outcomes, .alreadyDurable) == 1)
        #expect(outcome(outcomes, .skippedNovel) == 0)
        #expect(second.stats().filesWritten == 0)
        await second.closeAndWait()
    }

    @Test("hints are per receipt, survive an abandoned stage, clear at terminal, and are bounded")
    func hintLifecycle() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore()
        defer { store.close() }
        store.registerDonationDemand(.init(repeatedPrefixTokens: 512), requestID: .init(20))
        #expect(store.donationDemandHints.demand(for: .init(20))?.repeatedPrefixTokens == 512)
        #expect(store.donationDemandHints.demand(for: .init(21)) == nil)
        #expect(store.donationDemandHints.demand(for: nil) == nil)
        store.completeStaging(requestID: .init(20))
        #expect(store.donationDemandHints.count == 0)

        // Abandoning a staged read does not end the request: the bridge retries
        // the same receipt cold, and its completion still consults the hint.
        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(22))
        await store.abandonStaging(requestID: .init(22))
        #expect(store.donationDemandHints.demand(for: .init(22))?.repeatedPrefixTokens == 0)
        #expect(store.offeredWriteClass(requestID: .init(22), localRepeat: false) == nil)
        store.completeStaging(requestID: .init(22))
        #expect(store.donationDemandHints.count == 0)

        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(23))
        store.discardDonationDemand(requestID: .init(23))
        #expect(store.donationDemandHints.count == 0)

        let bounded = SSDCheckpointDemandHints(limit: 3)
        for id in 1...5 { bounded.register(.init(repeatedPrefixTokens: id), requestID: .init(UInt64(id))) }
        #expect(bounded.count == 3)
        #expect(bounded.demand(for: .init(1)) == nil)
        #expect(bounded.demand(for: .init(5))?.repeatedPrefixTokens == 5)
        bounded.register(.init(repeatedPrefixTokens: 9), requestID: .init(5))
        #expect(bounded.count == 3)
        #expect(bounded.demand(for: .init(5))?.repeatedPrefixTokens == 9)

        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(24))
        store.close()
        #expect(store.donationDemandHints.count == 0)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(25))
        #expect(store.donationDemandHints.count == 0)
    }
}
