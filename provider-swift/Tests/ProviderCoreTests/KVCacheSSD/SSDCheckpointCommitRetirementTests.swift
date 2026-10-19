import CryptoKit
import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

/// The real encrypted writers pause after rename (or duplicate authentication),
/// before publication. No model is needed; the complete fixture uses CPU tensors.
@Suite("Checkpoint commit and owned retirement", .serialized)
struct SSDCheckpointCommitRetirementTests {
    @Test("whole-root eviction cannot retire an uncommitted writer or authenticated duplicate",
          arguments: [false, true])
    func wholeRootRace(duplicate: Bool) async throws {
        try await Device.withDefaultDevice(.cpu) {
            let f = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
            defer { f.remove() }
            let store = try f.makeStore(diskBudget: .shared)
            defer { store.close() }
            // This unrelated checkpoint must remain readable and advertised.
            #expect(try await f.donate(store, receipt: 10, position: 512) == [512])
            if duplicate { #expect(try await f.donate(store, receipt: 11, position: 256) == [256]) }
            let epoch = try #require(store.config.epochStore?.current)
            let file = f.file(store, position: 256)
            let survivor = f.file(store, position: 512)
            let survivorBytes = try Data(contentsOf: survivor)
            let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
            defer { barrier.release() }
            store.lock.withLock {
                store.beforeWriteIndexForTesting = { url, alreadyDurable in
                    #expect(url == file)
                    #expect(alreadyDurable == duplicate)
                    do { try barrier.block() } catch { Issue.record("writer barrier timed out: \(error)") }
                }
            }
            let publications = SSDCheckpointPublicationTests.Publications()
            store.registerReadyReceipt(requestID: .init(12), promptTokens: f.tokens,
                cacheScope: "tenant-a", callback: publications.append)
            let donation = Task { try await f.donate(store, receipt: 12, position: 256) }
            defer { donation.cancel() }
            try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
            let tag = try #require(SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent))
            #expect(store.index.contains(tag16: tag) == duplicate)
            let fileBytes = try Data(contentsOf: file)
            #expect(!fileBytes.isEmpty)
            let now = Int64(Date().timeIntervalSince1970)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(now - 30))], ofItemAtPath: file.path)
            // Newer inactive roots exceed the whole-root budget but are absent
            // from active-store accounting, matching the original review race.
            for model in ["111111111111", "222222222222"] {
                let root = f.root.appendingPathComponent(model)
                try SSDBlockStore.prepareModelRoot(dedicatedRoot: f.root, modelRoot: root)
                let copy = SSDBlockStore.fileURL(root: root, tag16Hex: tag.hexString)
                try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file, to: copy)
                try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(now - 10))], ofItemAtPath: copy.path)
            }
            let limit = survivorBytes.count + 2 * fileBytes.count
            let result = SSDWholeRootMaintainer().maintain(root: f.root, ttlSeconds: 3600,
                nowSeconds: now, budgetBytes: limit)
            SSDDiskBudget.shared.reconcileAll()
            #expect(result.filesSeen == 4)
            #expect(result.budgetEvicted == 1)
            #expect(result.bytesAfter <= limit)
            #expect(try Data(contentsOf: file) == fileBytes, "in-flight oldest file must be skipped")
            #expect(try Data(contentsOf: survivor) == survivorBytes)
            #expect(store.config.epochStore?.current == epoch)
            barrier.release()
            #expect(try await donation.value == [256])
            #expect(store.index.contains(tag16: tag))
            let authenticated = try SSDBlockStore.read(from: file, kekKey: f.key)
            #expect(!authenticated.1.isEmpty)
            store.publishReady(requestID: .init(12), positions: [256])
            #expect(publications.count == 1)
            // Self-eviction after commit is still permitted and clears index.
            #expect(store.retireOwnedEntries([file]) == [file.path])
            #expect(!store.index.contains(tag16: tag))
            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try Data(contentsOf: survivor) == survivorBytes)
            #expect(store.config.epochStore?.current == epoch)
            await store.closeAndWait()
            #expect(SSDCheckpointFileCoordinator.shared.pendingCount(for: file) == 0)
        }
    }

    @Test("post-commit budget eviction prevents READY instead of pinning the new file")
    func committedVictimIsNotPublished() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let f = try SSDHybridCheckpointTestFixture()
            defer { f.remove() }
            let store = try f.makeStore(diskBudgetBytes: { 0 })
            defer { store.close() }
            let publications = SSDCheckpointPublicationTests.Publications()
            store.registerReadyReceipt(requestID: .init(10), promptTokens: f.tokens,
                cacheScope: "tenant-a", callback: publications.append)
            #expect(try await f.donate(store).isEmpty)
            #expect(store.index.count == 0)
            #expect(!FileManager.default.fileExists(atPath: f.file(store).path))
            store.publishReady(requestID: .init(10), positions: [256])
            #expect(publications.count == 0)
            await store.closeAndWait()
        }
    }

    @Test("close cancels a queued writer lease and settles without writing")
    func closeQueuedWriter() async throws {
        try await Device.withDefaultDevice(.cpu) {
            let f = try SSDHybridCheckpointTestFixture()
            defer { f.remove() }
            let store = try f.makeStore()
            defer { store.close() }
            let file = f.file(store)
            let owner = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: file))
            defer { owner.release() }
            let donation = Task { try await f.donate(store) }
            defer { donation.cancel() }
            try await SSDCheckpointCoordinationTestSupport.waitUntil {
                SSDCheckpointFileCoordinator.shared.pendingCount(for: file) == 1
            }
            store.close()
            #expect(try await donation.value.isEmpty)
            await store.closeAndWait()
            #expect(SSDCheckpointFileCoordinator.shared.pendingCount(for: file) == 0)
            #expect(store.index.count == 0)
            #expect(store.stats().filesWritten == 0)
            #expect(store.stats().writeHostBytesInUse == 0)
        }
    }

    @Test("attention write-behind holds the same lease across rename and indexing")
    func attentionWriterRace() async throws {
        let f = try SSDOwnedEntryRetirementTests.Fixture()
        let tag = Data(repeating: 1, count: 16)
        let file = SSDBlockStore.fileURL(root: f.model, tag16Hex: tag.hexString)
        let key = SymmetricKey(size: .bits256)
        let chunk = Data(repeating: 7, count: 32)
        let block = SSDBlockWrite(tag16: tag, tag16Hex: tag.hexString,
            metadata: .init(lookupTag: (tag + tag).hexString, weightHash: "fixture",
                layoutEpoch: "layout", blockSize: 8, layerCount: 1,
                chunks: [.init(layerIndex: 0, tensor: 0, shape: [1, 1, 8, 2], dtype: "float16")],
                chunkPlaintextSizes: [chunk.count], createdAt: 10_000),
            chunks: [chunk], plaintextBytes: chunk.count)
        let barrier = SSDCheckpointCoordinationTestSupport.Barrier()
        defer { barrier.release() }
        let stats = SSDPrefixCacheStatsBox()
        let writer = SSDWriteBehind(config: .init(root: f.model, kekKey: key,
            strictFsync: false, ttlSeconds: 0, maxJobs: 1, maxQueuedBytes: 1 << 20,
            diskBudgetBytes: { 1 << 20 }, volumeSpace: { nil }, nowSeconds: { 10_000 },
            maintainWholeRoot: nil, writeBlock: { block, url in
                let bytes = try SSDBlockStore.write(to: url, metadata: block.metadata,
                    chunks: block.chunks, kekKey: key, strictFsync: false)
                try barrier.block()
                return bytes
            }), rateLimiter: SSDWriteRateLimiter(capBytesPerDay: 0), index: f.index,
            diskBudget: SSDDiskBudget(), stats: stats, onBlockSettled: { _ in }, sweepExpired: {})
        defer { writer.close() }
        #expect(writer.submit(.init(blocks: [block], totalBytes: chunk.count)))
        try await SSDCheckpointCoordinationTestSupport.waitUntil { barrier.isEntered }
        #expect(!f.index.contains(tag16: tag))
        let epoch = try #require(f.epoch.current)
        let result = try #require(SSDOwnedEntryRetirement.remove(urls: [file], root: f.model,
            index: f.index, epochStore: f.epoch))
        #expect(result.removed.isEmpty)
        #expect(!result.externalChange)
        barrier.release()
        await writer.waitUntilDrained()
        #expect(stats.snapshot().blocksWritten == 1)
        #expect(f.index.contains(tag16: tag))
        #expect(try SSDBlockStore.read(from: file, kekKey: key).1 == [chunk])
        #expect(f.epoch.current == epoch)
    }
}
