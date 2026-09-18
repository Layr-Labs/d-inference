import Foundation
import MLXLMCommon
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

    private func makeStore(_ fixture: SSDHybridCheckpointTestFixture, clock: Clock) throws -> SSDHybridCheckpointStore {
        let epoch = try SSDCacheEpochStore(root: fixture.modelRoot, binding: .init(
            modelId: "fixture-model", modelAggregateHash: fixture.identity.modelAggregateHash,
            promptContractId: fixture.identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: fixture.identity, backendLayout: fixture.backendLayout), keyFingerprint: "fixture-key"))
        let store = SSDHybridCheckpointStore(config: .init(
            modelId: "fixture-model", identity: fixture.identity, backendLayout: fixture.backendLayout,
            root: fixture.modelRoot, dedicatedRoot: fixture.root, epochStore: epoch,
            maxReadBytes: 16 << 20, maxStageMillis: 1000, minEffectiveTokens: 256,
            ttlSeconds: 60, strictFsync: false, nowSeconds: { clock.now },
            diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
            kekKey: fixture.key, kvBudget: fixture.budget, diskBudget: SSDDiskBudget(), maxWriteBytesPerDay: 1 << 30)
        store.scanOnDisk()
        return store
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
        #expect(expired.config.epochStore?.current != epoch)
        await expired.closeAndWait()
    }
}
