// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: per-donation gate", .serialized)
struct SSDPrefixCacheDonationGateTests {

    /// Poll briefly and assert NOTHING was written (negative settling).
    private func expectNoWrites(_ cache: SSDPrefixCache, dir: URL) async {
        try? await Task.sleep(for: .milliseconds(300))
        #expect(cache.stats().blocksWritten == 0)
        #expect(cache.index.count == 0)
        #expect(dbk3Files(under: dir).isEmpty)
    }

    private func donate(_ cache: SSDPrefixCache, tokenCount: Int) {
        cache.donate(
            tokens: Array(0 ..< tokenCount),
            snapshots: fixtureSnapshots(tokenCount: tokenCount),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
    }

    @Test("gpt-oss constants: sub-2.5k donations skipped, above-floor donations persist")
    func gptOssConstantsGate() async throws {
        let dir = tempDir("gate-gptoss")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        // Real gpt-oss-20b numbers: bound 12 × 128 = 1,536; benefit floor
        // 1,024 ⇒ persist only donations of MORE than 2,560 tokens.
        let cache = makeCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock,
            blockSize: 256, adoptionBound: 1536, minEffectiveTokens: 1024)
        defer { cache.close() }

        // Exactly at the floor (2,560 = 10 whole blocks): not adoptable ⇒
        // skipped (disk-wear win; nothing on disk).
        donate(cache, tokenCount: 2560)
        await expectNoWrites(cache, dir: dir)

        // One block past the floor: persists ALL its whole blocks (the
        // leading blocks are needed for the contiguous adoption run).
        donate(cache, tokenCount: 2816 + 3)  // 11 whole blocks + tail
        let deadline = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < deadline, cache.index.count < 11 {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(cache.index.count == 11)
        #expect(dbk3Files(under: dir).count == 11)
    }

    @Test("gemma constants: the >27.1k evidence-backed tail caches; shorter writes nothing")
    func gemmaConstantsGate() async throws {
        let dir = tempDir("gate-gemma")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        // Real Gemma numbers: bound 25,600 + measured saved-token floor 1,536.
        let cache = makeCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock,
            blockSize: 256, adoptionBound: 25_600, minEffectiveTokens: 1_536)
        defer { cache.close() }

        // A typical prompt (4k) AND the exact floor both write nothing —
        // the negative that used to be enforced by excluding gemma wholesale.
        donate(cache, tokenCount: 4096)
        await expectNoWrites(cache, dir: dir)
        donate(cache, tokenCount: 27_136)
        await expectNoWrites(cache, dir: dir)

        // The long-context tail (107 whole blocks = 27,392 tokens) persists.
        donate(cache, tokenCount: 27_392 + 5)
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline, cache.index.count < 107 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(cache.index.count == 107)
    }

    @Test("unknown/saturated adoption bound: never persists (the only 'never cached' case)")
    func saturatedBoundNeverPersists() async throws {
        let dir = tempDir("gate-unknown")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        let cache = makeCache(
            dir: dir, kek: SymmetricKey(size: .bits256), clock: clock,
            blockSize: 256, adoptionBound: Int.max, minEffectiveTokens: 1024)
        defer { cache.close() }
        donate(cache, tokenCount: 26_880)
        await expectNoWrites(cache, dir: dir)
    }

    @Test("persisted-run byte cap: blocks beyond maxStageBytes are never written (leading run kept)")
    func byteCapTrimsPersistedRun() async throws {
        let dir = tempDir("gate-bytecap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = ClockBox(10_000)
        // Fixture block bytes: 2 tensors × [1,2,8,8] f16 = 2 × 256 B = 512 B
        // PLAINTEXT (the donate-side cap's unit). Cap at 3 blocks' worth:
        // an 8-block donation persists only blocks 1..3 (a valid contiguous
        // prefix run); 4.. are unstageable wear.
        let kek = SymmetricKey(size: .bits256)
        let writer = makeCache(
            dir: dir, kek: kek, clock: clock,
            minEffectiveTokens: fixtureBlockSize, maxStageBytes: 3 * 512)
        writer.donate(
            tokens: Array(0 ..< 64),
            snapshots: fixtureSnapshots(tokenCount: 64),
            layerKinds: fixtureLayerKinds,
            cacheSalt: nil)
        #expect(await waitForIndexCount(writer, atLeast: 3))
        try? await Task.sleep(for: .milliseconds(200))
        #expect(writer.index.count == 3)
        #expect(dbk3Files(under: dir).count == 3)
        writer.close()

        // The persisted run is the LEADING prefix (contiguous from block 1):
        // a reader with an uncapped STAGE budget (the stage cap counts
        // on-disk bytes, which include DBK3 overhead) adopts exactly the
        // 3 persisted blocks.
        let reader = makeCache(
            dir: dir, kek: kek, clock: clock, minEffectiveTokens: fixtureBlockSize)
        defer { reader.close() }
        reader.scanOnDisk()
        let staged = await reader.stage(
            requestID: "r-cap", promptTokens: Array(0 ..< 64) + [1], cacheScope: "")
        #expect(staged.staged)
        let hit = reader.lookup(
            tokens: Array(0 ..< 64) + [1], layerKinds: fixtureLayerKinds, cacheSalt: nil)
        #expect(hit?.matched == 3 * fixtureBlockSize)
        if let hit {
            reader.endAdoption(
                tokens: Array(0 ..< 64) + [1], matched: hit.matched, cacheSalt: nil)
        }
        reader.completeStaging(requestID: "r-cap")
    }

    @Test("stage cap below hybrid benefit floor writes no unusable blocks")
    func byteCapBelowBenefitFloorSkipsDonation() async throws {
        let dir = tempDir("gate-bytecap-floor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            adoptionBound: 32,
            minEffectiveTokens: 8,
            maxStageBytes: 3 * 512)
        defer { cache.close() }

        donate(cache, tokenCount: 64)
        await expectNoWrites(cache, dir: dir)
    }

    @Test("write-behind admits one full max-size (~600 MB) donation; oversize is dropped, never stalled")
    func writeBehindBigDonationAdmission() async throws {
        let dir = tempDir("gate-bigjob")
        defer { try? FileManager.default.removeItem(at: dir) }
        // Effective queue-byte cap must clear a ~600 MB gemma tail donation.
        let effectiveCap = max(
            SSDPrefixCachePolicy.writeQueueMaxBytes,
            SSDPrefixCachePolicy.defaultMaxStageBytes + SSDPrefixCachePolicy.writeQueueSlackBytes)
        #expect(effectiveCap > 629_145_600)

        let kek = SymmetricKey(size: .bits256)
        let stats = SSDPrefixCacheStatsBox()
        let index = SSDBlockIndex()
        let writeBehind = SSDWriteBehind(
            config: SSDWriteBehind.Config(
                root: dir, kekKey: kek, strictFsync: false, ttlSeconds: 0,
                maxJobs: 2, maxQueuedBytes: effectiveCap,
                diskBudgetBytes: { 1 << 40 },
                volumeSpace: { nil },
                nowSeconds: { 10_000 },
                maintainWholeRoot: nil,
                writeBlock: nil),
            rateLimiter: SSDWriteRateLimiter(capBytesPerDay: 0),
            index: index, diskBudget: SSDDiskBudget(), stats: stats,
            onBlockSettled: { _ in }, sweepExpired: {})
        defer { writeBehind.close() }

        // A job CLAIMING 600 MB (tiny real chunks — admission is what's
        // under test) is admitted and consumed: graceful, no stall.
        func syntheticJob(tagByte: UInt8, claimedBytes: Int) -> SSDDonationJob {
            let tag16 = Data(repeating: tagByte, count: 16)
            let chunk = Data(repeating: 1, count: 256)
            let metadata = SSDBlockMetadata(
                lookupTag: SSDLookupKeys.hex(tag16 + tag16),
                weightHash: "w", layoutEpoch: "e", blockSize: 8, layerCount: 2,
                chunks: [
                    SSDBlockChunkDescriptor(
                        layerIndex: 0, tensor: 0, shape: [1, 2, 8, 8], dtype: "float16")
                ],
                chunkPlaintextSizes: [256], createdAt: 10_000)
            return SSDDonationJob(
                blocks: [SSDBlockWrite(
                    tag16: tag16, tag16Hex: SSDLookupKeys.hex(tag16),
                    metadata: metadata, chunks: [chunk], plaintextBytes: 256)],
                totalBytes: claimedBytes)
        }
        #expect(writeBehind.submit(syntheticJob(tagByte: 0xA1, claimedBytes: 629_145_600)))
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, stats.snapshot().blocksWritten < 1 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(stats.snapshot().blocksWritten == 1, "600 MB donation must be consumed, not stalled")

        // A job larger than the whole cap is rejected IMMEDIATELY
        // (deterministic regardless of consumer state) — drop, not stall.
        #expect(!writeBehind.submit(syntheticJob(tagByte: 0xB2, claimedBytes: effectiveCap + 1)))
    }
}
