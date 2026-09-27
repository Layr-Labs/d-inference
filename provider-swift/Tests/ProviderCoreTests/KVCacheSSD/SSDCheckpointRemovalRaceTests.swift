import Foundation
import MLX
@testable import MLXLMCommon
import Testing
@testable import ProviderCore

private final class EvictionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var freed = 0
    func record(_ bytes: Int) { lock.withLock { freed += bytes } }
    var bytesFreed: Int { lock.withLock { freed } }
}

/// Per-file removals no longer fence readers behind an epoch change, so a
/// reader can find its checkpoint already gone. That is an ordinary miss, not
/// corruption, and a store that lost its root must not pin the disk budget.
@Suite("Complete checkpoint removal races", .serialized)
struct SSDCheckpointRemovalRaceTests {
    private func tag(
        _ f: SSDHybridCheckpointTestFixture, _ store: SSDHybridCheckpointStore, position: Int
    ) throws -> Data {
        try #require(SSDPrefixCache.hexDecode(
            f.file(store, position: position).deletingPathExtension().lastPathComponent))
    }

    @Test("a checkpoint unlinked behind the index is an absent miss, not corruption")
    func unlinkedBehindIndex() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        defer { store.close() }
        #expect(try await f.donate(store, position: 256) == [256])
        #expect(try await f.donate(store, receipt: 11, position: 512) == [512])
        let epoch = try #require(store.config.epochStore?.current)
        try FileManager.default.removeItem(at: f.file(store, position: 512))
        #expect(store.index.count == 2)

        let missed = await store.stage(requestID: .init(801), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(missed.disposition == .missAbsent)
        #expect(store.stats().corruptDropped == 0)
        #expect(store.stats().misses == 1)
        #expect(!store.index.contains(tag16: try tag(f, store, position: 512)))
        #expect(store.index.contains(tag16: try tag(f, store, position: 256)))
        #expect(store.config.epochStore?.current == epoch)

        // The shorter checkpoint is untouched and serves the next request.
        let staged = await store.stage(requestID: .init(802), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
        #expect(staged.staged)
        #expect(staged.stagedTokens == 256)
        await store.abandonStaging(requestID: .init(802))
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("eviction between a reader's manifest read and its full read is an absent miss and leaks nothing")
    func evictionDuringRead() async throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let store = try f.makeStore()
        defer { store.close() }
        #expect(try await f.donate(store) == [256])
        let epoch = try #require(store.config.epochStore?.current)
        let capability = try #require(store.prefixCacheV2Capability())
        let file = f.file(store)
        let probe = EvictionProbe()

        // The import-plan callback runs after the manifest was authenticated
        // and before the full read, while the reader holds its file access.
        let result = await store.stage(requestID: .init(811), request: f.request(),
                                       reserveReadScratch: f.reserveReadScratch) { manifest in
            probe.record(store.evictOldestEntry())
            return try f.plan(manifest)
        }
        #expect(probe.bytesFreed > 0)
        #expect(result.disposition == .missAbsent)
        #expect(store.stats().evictions == 1)
        #expect(store.stats().corruptDropped == 0)
        #expect(store.index.count == 0)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability() == capability)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await f.budget.outstandingReservedBytes() == 0)
        #expect(f.codec.admission.bytesReserved == 0)
    }

    @Test("concurrent readers and eviction never report corruption, rotate, or leak reservations")
    func concurrentReadersAndEviction() async throws {
        let f = try SSDHybridCheckpointTestFixture(tokenCount: 1025)
        defer { f.remove() }
        let store = try f.makeStore()
        defer { store.close() }
        let epoch = try #require(store.config.epochStore?.current)
        var receipt: UInt64 = 2_000
        for round in 0..<6 {
            for position in [256, 512, 768, 1024] {
                receipt += 1
                #expect(try await f.donate(store, receipt: receipt, position: position) == [position])
            }
            let seen = await withTaskGroup(of: [SSDPrefixCacheStageDisposition].self) { group in
                for reader in 0..<3 {
                    let base = UInt64(10_000 + round * 100 + reader * 10)
                    group.addTask {
                        var dispositions: [SSDPrefixCacheStageDisposition] = []
                        for attempt in 0..<4 {
                            let id = CBv2RequestID(base + UInt64(attempt))
                            let result = await store.stage(
                                requestID: id, request: f.request(),
                                reserveReadScratch: f.reserveReadScratch, makeImportPlan: f.plan)
                            dispositions.append(result.disposition)
                            await store.abandonStaging(requestID: id)
                        }
                        return dispositions
                    }
                }
                group.addTask {
                    var passes = 0
                    while store.index.count > 0, passes < 1_000 {
                        _ = store.evictOldestEntry()
                        passes += 1
                        await Task.yield()
                    }
                    return []
                }
                var all: [SSDPrefixCacheStageDisposition] = []
                for await dispositions in group { all += dispositions }
                return all
            }
            #expect(seen.count == 12)
            #expect(!seen.contains(.missCorrupt))
            #expect(store.index.count == 0)
            #expect(store.index.totalBytes == 0)
        }
        #expect(store.stats().corruptDropped == 0)
        #expect(store.stats().evictions == 24)
        #expect(store.config.epochStore?.current == epoch)
        #expect(store.prefixCacheV2Capability()?.cacheEpoch == epoch)
        await store.closeAndWait()
        #expect(store.stats().stagedBytesInUse == 0)
        #expect(await f.budget.outstandingReservedBytes() == 0)
    }

    @Test("a read failure is absent only for ENOENT or a missing file, never for present bytes")
    func absentFailureClassification() throws {
        let f = try SSDHybridCheckpointTestFixture()
        defer { f.remove() }
        let url = SSDBlockStore.fileURL(root: f.modelRoot, tag16Hex: String(repeating: "a", count: 32))
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preCheck = SSDBlockStoreError.ioFailure("unsafe block path")
        let raced = SSDBlockStoreError.posixFailure("openat read", code: ENOENT)
        let denied = SSDBlockStoreError.posixFailure("openat read", code: EACCES)
        let corrupt = SSDBlockStoreError.authenticationFailed("chunk tag")

        // Missing: both the pre-check shape and the typed code are absent.
        #expect(SSDBlockStore.isAbsentBlockFailure(preCheck, at: url, under: f.modelRoot))
        #expect(SSDBlockStore.isAbsentBlockFailure(raced, at: url, under: f.modelRoot))
        #expect(SSDBlockStore.isAbsentBlockFailure(corrupt, at: url, under: f.modelRoot))

        // Present: only the typed ENOENT (unlink raced, file since rewritten).
        try Data("present".utf8).write(to: url)
        #expect(SSDBlockStore.isAbsentBlockFailure(raced, at: url, under: f.modelRoot))
        #expect(!SSDBlockStore.isAbsentBlockFailure(preCheck, at: url, under: f.modelRoot))
        #expect(!SSDBlockStore.isAbsentBlockFailure(denied, at: url, under: f.modelRoot))
        #expect(!SSDBlockStore.isAbsentBlockFailure(corrupt, at: url, under: f.modelRoot))

        // Replaced by a link: invalid, so it stays on the corruption path.
        let outside = f.root.appendingPathComponent("outside-\(UUID().uuidString)")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        #expect(!SSDBlockStore.isAbsentBlockFailure(preCheck, at: url, under: f.modelRoot))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("a disowned store reconciles its index so the box-wide budget stops over-evicting")
    func disownedStoreReleasesPhantomBytes() async throws {
        let a = try SSDHybridCheckpointTestFixture()
        let b = try SSDHybridCheckpointTestFixture()
        defer { a.remove(); b.remove() }
        let disk = SSDDiskBudget()
        let stale = try a.makeStore(diskBudget: disk)
        let healthy = try b.makeStore(diskBudget: disk)
        defer { stale.close(); healthy.close() }
        #expect(try await a.donate(stale) == [256])
        #expect(try await b.donate(healthy) == [256])
        let healthyBytes = healthy.diskBytesOnDisk
        #expect(healthyBytes > 0)

        // A different-binding successor wipes the root and disowns `stale`,
        // which stays registered until its owner closes it.
        _ = try SSDCacheEpochStore(root: a.modelRoot, binding: .init(
            modelId: "fixture-model", modelAggregateHash: a.identity.modelAggregateHash,
            promptContractId: a.identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: PrefixCachePolicy.blockSize, layoutEpoch: SSDHybridCheckpointEnvelope.layoutEpoch(
                identity: a.identity, backendLayout: a.backendLayout),
            keyFingerprint: "rotated-key"))
        #expect(stale.config.epochStore?.current == nil)
        #expect(!FileManager.default.fileExists(atPath: a.file(stale).path))
        #expect(stale.diskBytesOnDisk > 0, "phantom bytes until the index is reconciled")
        // File-touching removal stays refused for the disowned store.
        #expect(stale.evictOldestEntry() == 0)

        disk.reconcileAll()
        #expect(stale.index.count == 0)
        #expect(stale.diskBytesOnDisk == 0)
        #expect(disk.totalBytes == healthyBytes)
        #expect(disk.enforce(budgetBytes: healthyBytes) == 0)
        #expect(healthy.index.count == 1)
        #expect(healthy.stats().evictions == 0)
        let staged = await healthy.stage(requestID: .init(821), request: b.request(),
                                         reserveReadScratch: b.reserveReadScratch, makeImportPlan: b.plan)
        #expect(staged.staged)
        await healthy.abandonStaging(requestID: .init(821))
        await stale.closeAndWait()
        await healthy.closeAndWait()
    }
}
