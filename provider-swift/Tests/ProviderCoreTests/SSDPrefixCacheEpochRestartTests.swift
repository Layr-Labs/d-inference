// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

@Suite("SSD prefix cache: epoch and restart", .serialized)
struct SSDPrefixCacheEpochRestartTests {
    private let tokenCount = 64


    @Test("restart warmth: a FRESH cache over the same dir scans, stages, and adopts byte-exactly")
    func restartWarmthRoundTrip() async throws {
        let dir = tempDir("warmth")
        defer { try? FileManager.default.removeItem(at: dir) }
        let kek = SymmetricKey(size: .bits256)
        let clock = ClockBox(10_000)
        let tokens = Array(0 ..< tokenCount)

        let writer = makeCache(dir: dir, kek: kek, clock: clock)
        donateFixture(writer, tokens: tokens)
        #expect(await waitForIndexCount(writer, atLeast: 8))
        writer.close()

        // "Restart": new instance, same dir + install key; index rebuilt by scan.
        let reader = makeCache(dir: dir, kek: kek, clock: clock)
        defer { reader.close() }
        reader.scanOnDisk()
        #expect(reader.index.count == 8)

        // Stage for a prompt extending the donated prefix.
        let prompt = tokens + Array(1000 ..< 1004)
        let staged = await reader.stage(requestID: "req-1", promptTokens: prompt, cacheScope: "")
        #expect(staged.staged)
        #expect(reader.bytesInUse > 0)

        // Engine-side synchronous lookup hits the staging map.
        let hit = reader.lookup(tokens: prompt, layerKinds: fixtureLayerKinds, cacheSalt: nil)
        let (matched, prefix) = try #require(hit)
        #expect(reader.stats().tokensSaved == 0, "lookup M is not terminal saved-prefill truth")
        reader.recordPrefillTokensSaved(7)
        #expect(reader.stats().tokensSaved == 7)
        #expect(matched == tokenCount)  // 8 whole blocks
        #expect(prefix.count == 2)
        #expect(prefix[1] == nil)  // windowed layer never cached
        let adopted = try #require(prefix[0])
        #expect(adopted.offset == matched)
        #expect(adopted.keys.shape == [1, fixtureKVHeads, matched, fixtureHeadDim])

        // Byte-exact vs the donor arrays (the exactness invariant).
        let donor = fixtureSnapshots(tokenCount: tokens.count)[0]!
        let keyDelta = abs(
            adopted.keys.asType(.float32)
                - donor.keys[.ellipsis, 0 ..< matched, 0...].asType(.float32)
        ).max().item(Float.self)
        let valueDelta = abs(
            adopted.values.asType(.float32)
                - donor.values[.ellipsis, 0 ..< matched, 0...].asType(.float32)
        ).max().item(Float.self)
        #expect(keyDelta == 0)
        #expect(valueDelta == 0)

        // endAdoption (the engine's balanced release) drains the staging map.
        reader.endAdoption(tokens: prompt, matched: matched, cacheSalt: nil)
        #expect(reader.bytesInUse == 0)
        // Backstop after the fact is a no-op.
        reader.completeStaging(requestID: "req-1")
        #expect(reader.stats().hits == 1)
    }

    @Test("active capacity eviction persists a new epoch before unlink")
    func activeEvictionRotatesEpoch() async throws {
        let dir = tempDir("active-epoch-eviction")
        defer { try? FileManager.default.removeItem(at: dir) }
        let layoutEpoch = SSDBlockStore.layoutEpoch(
            blockSize: fixtureBlockSize, layerKinds: fixtureLayerKinds)
        let binding = SSDCacheEpochStore.Binding(
            modelId: "test-model",
            modelAggregateHash: "test-weight-hash",
            promptContractId: "test-prompt-contract",
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: fixtureBlockSize,
            layoutEpoch: layoutEpoch,
            keyFingerprint: String(repeating: "e", count: 64))
        let epochStore = try SSDCacheEpochStore(root: dir, binding: binding)
        let originalEpoch = try #require(epochStore.current)
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            epochStore: epochStore)
        defer { cache.close() }

        donateFixture(cache, tokens: Array(0 ..< tokenCount), seed: 1)
        #expect(await waitForIndexCount(cache, atLeast: 1))
        #expect(cache.evictOldestEntry() > 0)
        let rotatedEpoch = try #require(epochStore.current)
        #expect(rotatedEpoch != originalEpoch)
        #expect(try SSDCacheEpochStore(root: dir, binding: binding).current == rotatedEpoch)
    }

    @Test("capability publication waits for destructive mutation completion")
    func destructiveMutationBracketsCapabilityPublication() async throws {
        let dir = tempDir("epoch-publication-bracket")
        defer { try? FileManager.default.removeItem(at: dir) }
        let binding = SSDCacheEpochStore.Binding(
            modelId: "test-model",
            modelAggregateHash: "test-weight-hash",
            promptContractId: "test-prompt-contract",
            blockHashVersion: CBv2BlockHasher.version,
            blockSize: fixtureBlockSize,
            layoutEpoch: SSDBlockStore.layoutEpoch(
                blockSize: fixtureBlockSize, layerKinds: fixtureLayerKinds),
            keyFingerprint: String(repeating: "e", count: 64))
        let epochStore = try SSDCacheEpochStore(root: dir, binding: binding)
        let cache = makeCache(
            dir: dir,
            kek: SymmetricKey(size: .bits256),
            clock: ClockBox(10_000),
            epochStore: epochStore)
        defer { cache.close() }

        cache.startBackgroundTasks(sweepIntervalSeconds: 3_600)
        var advertised: PrefixCacheV2Capability?
        for _ in 0 ..< 100 {
            advertised = cache.prefixCacheV2Capability()
            if advertised != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let original = try #require(advertised)
        let (entered, enteredContinuation) = AsyncStream.makeStream(
            of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let release = DispatchSemaphore(value: 0)
        let mutation = Task.detached {
            cache.holdDestructiveEpochForTesting {
                enteredContinuation.yield(())
                release.wait()
            }
        }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()

        let mutationAdvertisement = cache.prefixCacheAdvertisement(
            base: PrefixCacheModelStatus(
                modelId: "test-model",
                backend: .contiguous,
                replayStrategy: .direct,
                state: .pending,
                reason: .scanPending))
        #expect(mutationAdvertisement.capability == nil)
        #expect(mutationAdvertisement.status.state == .pending)
        #expect(mutationAdvertisement.status.reason == .scanPending)
        #expect(
            cache.takeNextPrefixCacheV2Sequence(expectedEpoch: original.cacheEpoch) == nil)

        release.signal()
        #expect(await mutation.value)
        let current = try #require(cache.prefixCacheV2Capability())
        #expect(current.cacheEpoch != original.cacheEpoch)
    }
}
