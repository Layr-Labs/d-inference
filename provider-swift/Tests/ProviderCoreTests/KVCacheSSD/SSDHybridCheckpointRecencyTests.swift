import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Complete checkpoint coordinated recency retention", .serialized)
struct SSDHybridCheckpointRecencyTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Int64 = 1000
        var now: Int64 { lock.withLock { seconds } }
        func advance(to value: Int64) { lock.withLock { seconds = value } }
    }

    private func makeStore(_ fixture: SSDHybridCheckpointTestFixture, clock: Clock,
                           ttlSeconds: Int64 = 60) throws -> SSDHybridCheckpointStore {
        let epoch = try SSDCacheEpochStore(root: fixture.modelRoot, binding: .init(
            modelId: "fixture-model", modelAggregateHash: fixture.identity.modelAggregateHash,
            promptContractId: fixture.identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: fixture.identity, backendLayout: fixture.backendLayout), keyFingerprint: "fixture-key"))
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: "fixture-model", identity: fixture.identity, backendLayout: fixture.backendLayout,
            root: fixture.modelRoot, dedicatedRoot: fixture.root, epochStore: epoch,
            maxReadBytes: 16 << 20, maxStageMillis: 1000, minEffectiveTokens: 256,
            ttlSeconds: ttlSeconds, strictFsync: false, nowSeconds: { clock.now },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: fixture.key, kvBudget: fixture.budget, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        return store
    }

    @Test("complete TTL characterization: expired indexed files refuse reads without waiting for a sweep",
          arguments: [1799, 1800, 1801])
    func ttlReadBoundaryWithoutSweep(age: Int) async throws {
        try await Device.withDefaultDevice(.cpu) {
            #expect(Device.defaultDevice().deviceType == .cpu)
            let fixture = try SSDHybridCheckpointTestFixture()
            defer {
                do { try FileManager.default.removeItem(at: fixture.root) }
                catch { Issue.record("complete expiry fixture cleanup failed: \(error)") }
            }
            let clock = Clock()
            let store = try makeStore(fixture, clock: clock, ttlSeconds: SSDPrefixCachePolicy.defaultTTLSeconds)
            do {
                let donated = try await fixture.donate(store)
                try #require(donated == [256], "donation setup must publish the fixture checkpoint")
                await store.waitForWritesForTesting()
                try #require(store.stats().entries == 1)
                try #require(store.index.oldest()?.lastAccess == 1000)
                try #require(store.stats().filesRead == 0)
                let file = fixture.file(store)
                let original = try Data(contentsOf: file)
                clock.advance(to: 1000 + Int64(age))
                let result = await store.stage(requestID: .init(510), request: fixture.request(),
                    reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
                let expectedStage = Int64(age) < SSDPrefixCachePolicy.defaultTTLSeconds
                #expect(result.staged == expectedStage)
                #expect(store.stats().filesRead == (expectedStage ? 2 : 0))
                if expectedStage {
                    #expect(result.stagedTokens == 256)
                } else {
                    #expect(result.disposition == .missAbsent)
                    #expect(store.stats().stagedBytesInUse == 0)
                }
                // Eligibility refusal is separate from deletion: no sweep ran.
                #expect(store.stats().entries == 1)
                let retained = try Data(contentsOf: file)
                #expect(retained == original)
                await store.abandonStaging(requestID: .init(510))
            } catch {
                await store.closeAndWait()
                throw error
            }
            await store.closeAndWait()
            #expect(store.stats().stagedBytesInUse == 0)
            #expect(await fixture.budget.outstandingReservedBytes() == 0)
            #expect(fixture.codec.admission.bytesReserved == 0)
        }
    }

    @Test("successful reads persist sliding TTL across restart without changing ciphertext or epoch")
    func slidingTTLAndRestart() async throws {
        let fixture = try SSDHybridCheckpointTestFixture()
        defer { fixture.remove() }
        let clock = Clock()
        let first = try makeStore(fixture, clock: clock)
        defer { first.close() }
        #expect(try await fixture.donate(first) == [256])
        let file = fixture.file(first)
        let original = try Data(contentsOf: file)
        let epoch = first.config.epochStore?.current
        for (identifier, timestamp): (UInt64, Int64) in [(501, 1050), (502, 1090)] {
            clock.advance(to: timestamp)
            let result = await first.stage(requestID: .init(identifier), request: fixture.request(),
                                           reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
            #expect(result.staged)
            await first.abandonStaging(requestID: .init(identifier))
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attributes[.modificationDate] as? Date == Date(timeIntervalSince1970: Double(timestamp)))
        }
        await first.closeAndWait()
        clock.advance(to: 1120)
        let restarted = try makeStore(fixture, clock: clock)
        defer { restarted.close() }
        #expect(restarted.stats().entries == 1)
        #expect(restarted.config.epochStore?.current == epoch)
        let restored = await restarted.stage(requestID: .init(503), request: fixture.request(),
                                             reserveReadScratch: fixture.reserveReadScratch, makeImportPlan: fixture.plan)
        #expect(restored.staged)
        #expect(try Data(contentsOf: file) == original)
        await restarted.closeAndWait()
        #expect(await fixture.budget.outstandingReservedBytes() == 0)
        clock.advance(to: 1180)
        let expired = try makeStore(fixture, clock: clock)
        defer { expired.close() }
        #expect(expired.stats().entries == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        // TTL expiry at scan is a per-file removal: the epoch survives it.
        #expect(expired.config.epochStore?.current == epoch)
        await expired.closeAndWait()
    }
}
