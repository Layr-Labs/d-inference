import Foundation
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Fleet-repeat checkpoint write priority", .serialized)
struct SSDCheckpointFleetWritePriorityTests {
    private func plaintextBytes(_ fixture: SSDHybridCheckpointTestFixture, position: Int) throws -> Int {
        try SSDHybridCheckpointEnvelope(manifest: fixture.manifest(position: position),
                                       maximumPlaintextBytes: 16 << 20).plaintextBytes
    }

    @Test("deepest-first publication preserves a covered fork when novel writes are exhausted")
    func demandedForkSurvivesNovelBudgetContention() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 6_145)
        defer { fixture.remove() }
        let bytes = try plaintextBytes(fixture, position: 5_120)
        let cap = bytes * 30
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.rateLimiter.consume(bytes: Int(Double(cap) * 0.9), repeated: false) == .accepted)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 5_120), requestID: .init(5))
        // A real COMPLETE batch offers endpoints sequentially, deepest first.
        // The unique extension must not spend the fleet-repeat reserve.
        #expect(try await fixture.donate(store, receipt: 5, position: 6_144).isEmpty)
        #expect(try await fixture.donate(store, receipt: 5, position: 5_120) == [5_120])
        #expect(try await fixture.donate(store, receipt: 5, position: 1_024) == [1_024])
        #expect(store.stats().filesWritten == 2)
        #expect(outcomes.snapshot().first { $0.outcome == .writePriorityLimited }?.count == 1)
        var fork = fixture.request()
        fork.promptTokens = Array(fixture.tokens.prefix(5_120)) + Array(repeating: 29, count: 200)
        let request = fork
        let result = await store.stage(requestID: .init(6), request: request,
            reserveReadScratch: fixture.reserveReadScratch) { manifest in
                try fixture.codec.plan(manifest: manifest, request: request)
            }
        #expect(result.staged)
        #expect(result.stagedTokens == 5_120)
        store.completeStaging(requestID: .init(6))
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
    }

    @Test("fleet demand keeps the two-writer bound and a refused fork can retry after contention")
    func fleetDemandCannotBypassWriterQueue() async throws {
        let fixture = try SSDHybridCheckpointTestFixture(tokenCount: 6_145)
        defer { fixture.remove() }
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(donationRecorder: outcomes)
        defer { store.close() }
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        store.afterPublishBeforeIndexForTesting = { try? barrier.block() }
        let firstSource = try fixture.source(position: 1_024)
        let secondSource = try fixture.source(position: 2_048)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 5_120), requestID: .init(8))
        let first = Task {
            await withCheckedContinuation { continuation in
                store.donate(firstSource, requestID: .init(8), tokens: fixture.tokens, cacheSalt: "tenant-a") {
                    continuation.resume(returning: $0)
                }
            }
        }
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        let second = Task {
            await withCheckedContinuation { continuation in
                store.donate(secondSource, requestID: .init(8), tokens: fixture.tokens, cacheSalt: "tenant-a") {
                    continuation.resume(returning: $0)
                }
            }
        }
        try await SSDCheckpointCoordinationTestSupport.waitUntil {
            store.lock.withLock { store.writing.count == 2 }
        }
        #expect(try await fixture.donate(store, receipt: 8, position: 5_120).isEmpty)
        #expect(outcomes.snapshot().first { $0.outcome == .writeQueueFull }?.count == 1)
        #expect(store.lock.withLock { store.writing.count } == 2)
        barrier.release()
        #expect(await first.value == [1_024])
        #expect(await second.value == [2_048])
        #expect(try await fixture.donate(store, receipt: 8, position: 5_120) == [5_120])
        #expect(store.stats().filesWritten == 3)
        #expect(store.lock.withLock { store.writing.isEmpty })
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
    }

    @Test("a discarded or absent fleet hint never claims reserved repeat priority")
    func missingDemandRemainsNovel() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let store = try fixture.makeStore(writeNowSeconds: { 0 })
        defer { store.close() }
        store.registerDonationDemand(.init(repeatedPrefixTokens: 512), requestID: .init(7))
        store.discardDonationDemand(requestID: .init(7))
        let policy = store.donationWritePolicy(requestID: .init(7), localRepeat: false, checkpointPosition: 256)
        #expect(policy.refusal == nil, "missing hints retain legacy write admission")
        #expect(!policy.repeated)
        #expect(store.donationWritePolicy(requestID: nil, localRepeat: false, checkpointPosition: 256).repeated == false)
        #expect(store.donationWritePolicy(requestID: nil, localRepeat: true, checkpointPosition: 256).repeated)
        await store.closeAndWait()
    }

    @Test("a fleet-covered checkpoint uses the repeat reserve on its first local sighting")
    func fleetRepeatUsesReservedBudget() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let bytes = try plaintextBytes(fixture, position: 256)
        let cap = bytes * 20
        let novel = Int(Double(cap) * 0.9)
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.rateLimiter.consume(bytes: novel, repeated: false) == .accepted)
        #expect(store.rateLimiter.admission(bytes: bytes, repeated: false) == .priorityLimited)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 256), requestID: .init(1))

        // This crosses both advisory admission and the actual writer debit.
        #expect(try await fixture.donate(store, receipt: 1) == [256])
        #expect(store.stats().filesWritten == 1)
        #expect(outcomes.snapshot().first { $0.outcome == .donated }?.count == 1)
        #expect(store.rateLimiter.admission(bytes: cap - novel - bytes + 1, repeated: true) == .rateLimited)
        #expect(store.rateLimiter.admission(bytes: 1, repeated: false) == .priorityLimited)
        await store.closeAndWait()
    }

    @Test("a repeated preamble does not grant its unique extension repeat priority")
    func uncoveredExtensionRemainsNovel() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let bytes = try plaintextBytes(fixture, position: 512)
        let cap = bytes * 20
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.rateLimiter.consume(bytes: Int(Double(cap) * 0.9), repeated: false) == .accepted)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 256), requestID: .init(2))
        #expect(try await fixture.donate(store, receipt: 2, position: 512).isEmpty)
        #expect(outcomes.snapshot().first { $0.outcome == .writePriorityLimited }?.count == 1)
        #expect(store.stats().filesWritten == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.file(store, position: 512).path))
        // The exact tag's second sighting is a real provider-local repeat.
        store.registerDonationDemand(.init(repeatedPrefixTokens: 0), requestID: .init(3))
        #expect(try await fixture.donate(store, receipt: 3, position: 512) == [512])
        await store.closeAndWait()
    }

    @Test("fleet repeat priority cannot exceed the unchanged total endurance cap")
    func fleetRepeatStillPaysTotalBudget() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let cap = try plaintextBytes(fixture, position: 256) * 20
        let outcomes = PrefixCacheDonationTelemetry()
        let store = try fixture.makeStore(maxWriteBytesPerDay: cap, donationRecorder: outcomes, writeNowSeconds: { 0 })
        defer { store.close() }
        #expect(store.rateLimiter.consume(bytes: cap, repeated: true) == .accepted)
        store.registerDonationDemand(.init(repeatedPrefixTokens: 512), requestID: .init(4))
        #expect(try await fixture.donate(store, receipt: 4).isEmpty)
        #expect(outcomes.snapshot().first { $0.outcome == .writeRateLimited }?.count == 1)
        #expect(store.stats().filesWritten == 0)
        await store.closeAndWait()
    }
}
