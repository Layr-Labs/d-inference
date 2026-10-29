import Foundation
import Testing
@testable import ProviderCore

@Suite("Owned SSD retirement", .serialized)
struct SSDOwnedEntryRetirementTests {
    // Synchronous component fixture: real retirement and budget coordination,
    // without either production store's native payload or lifecycle machinery.
    final class Fixture: SSDEvictableStore {
        let root: URL
        let model: URL
        let index = SSDBlockIndex()
        let binding = SSDCacheEpochStore.Binding(modelId: "fixture", modelAggregateHash: "weights",
            promptContractId: "contract", blockHashVersion: "hash", blockSize: 256,
            layoutEpoch: "layout", keyFingerprint: "key")
        let epoch: SSDCacheEpochStore

        init() throws {
            root = try SSDTestDirectory.parent()
                .appendingPathComponent("owned-retirement-\(UUID().uuidString)")
            model = root.appendingPathComponent("111111111111")
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            epoch = try SSDCacheEpochStore(root: model, binding: binding)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func file(_ byte: UInt8) throws -> URL {
            let tag = Data(repeating: byte, count: 16)
            let url = SSDBlockStore.fileURL(root: model, tag16Hex: tag.hexString)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Filesystem-only fixture; native authenticated payloads are tested
            // separately by SSDCheckpointPublicationTests.
            try Data(repeating: byte, count: 64).write(to: url)
            index.insert(tag16: tag, fileBytes: 64, lastAccess: Int64(byte))
            return url
        }

        func evictOldest() -> Int {
            SSDOwnedEntryRetirement.evictOldest(index: index) { tag in
                let url = SSDBlockStore.fileURL(root: model, tag16Hex: tag.hexString)
                return retire([url])
            }
        }

        var evictionRoot: URL { model }
        var ownsEvictionRoot: Bool { epoch.current != nil }
        var diskBytesOnDisk: Int { index.totalBytes }
        func oldestEntryAccess() -> Int64? { index.oldest()?.lastAccess }
        func evictOldestEntry() -> Int { evictOldest() }
        func retireOwnedEntries(_ urls: [URL]) -> Set<String> { retire(urls).removed }
        func reconcileExternalRemovals() {
            SSDOwnedEntryRetirement.reconcileMissingEntries(root: model, index: index)
        }
        func performExternalDestructiveChange(_ body: () -> Void) -> Bool {
            let completed: Void? = epoch.performOwnedRetirement {
                body()
                reconcileExternalRemovals()
            }
            return completed != nil
        }
        private func retire(_ urls: [URL]) -> SSDOwnedEntryRetirement.Result {
            let result = SSDOwnedEntryRetirement.remove(
                urls: urls, root: model, index: index, epochStore: epoch) ?? .init()
            if result.externalChange { reconcileExternalRemovals() }
            return result
        }
    }

    @Test("eviction uses the tag tie-break, frees one file, and preserves survivor identity")
    func oldestEviction() throws {
        let f = try Fixture()
        let survivor = try f.file(2), oldest = try f.file(1)
        f.index.touch(tags16: [Data(repeating: 1, count: 16)], now: 2)
        let epoch = try #require(f.epoch.current)
        #expect(f.epoch.takeNextSequence(expectedEpoch: epoch) == 1)
        let bytes = try Data(contentsOf: survivor)
        #expect(f.evictOldest() == 64)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(try Data(contentsOf: survivor) == bytes)
        #expect(f.index.totalBytes == 64)
        #expect(f.epoch.current == epoch)
        #expect(f.epoch.takeNextSequence(expectedEpoch: epoch) == 2)
    }

    @Test("eviction skips busy files, terminates when all are busy, and resumes after release")
    func busyEviction() throws {
        let f = try Fixture()
        let oldest = try f.file(1), second = try f.file(2), victim = try f.file(3)
        let firstLease = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: oldest))
        defer { firstLease.release() }
        let secondLease = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: second))
        defer { secondLease.release() }
        #expect(f.evictOldest() == 64)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
        #expect(f.evictOldest() == 0)
        #expect(f.index.totalBytes == 128)
        #expect(try Data(contentsOf: oldest) == Data(repeating: 1, count: 64))
        #expect(try Data(contentsOf: second) == Data(repeating: 2, count: 64))
        firstLease.release()
        #expect(f.evictOldest() == 64)
        #expect(!FileManager.default.fileExists(atPath: oldest.path))
        #expect(f.index.totalBytes == 64)
    }

    @Test("an undeletable oldest file does not pin newer eviction candidates")
    func undeletableEviction() throws {
        let f = try Fixture()
        let oldest = try f.file(1), victim = try f.file(2)
        let fanout = oldest.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fanout.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fanout.path) }
        #expect(f.evictOldest() == 64)
        #expect(try Data(contentsOf: oldest) == Data(repeating: 1, count: 64))
        #expect(!FileManager.default.fileExists(atPath: victim.path))
        #expect(f.index.totalBytes == 64)
    }

    @Test("external loss stops eviction after reconciliation, including in the fallback",
          arguments: [false, true], [false, true])
    func externalLossStopsEviction(busyOldest: Bool, symlink: Bool) throws {
        let f = try Fixture()
        let oldest = try f.file(1), missing = try f.file(2), survivor = try f.file(3)
        let epoch = try #require(f.epoch.current)
        let lease: SSDCheckpointFileCoordinator.Access?
        if busyOldest {
            let acquired: SSDCheckpointFileCoordinator.Access =
                try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: oldest))
            lease = acquired
        } else {
            lease = nil
        }
        defer { lease?.release() }
        let lost = busyOldest ? missing : oldest
        try FileManager.default.removeItem(at: lost)
        if symlink { try FileManager.default.createSymbolicLink(at: lost, withDestinationURL: survivor) }
        #expect(f.evictOldest() == 0)
        #expect(f.index.totalBytes == 128)
        #expect(f.index.count == 2)
        #expect(try Data(contentsOf: survivor) == Data(repeating: 3, count: 64))
        #expect(f.epoch.current == epoch)
        if busyOldest { #expect(try Data(contentsOf: oldest) == Data(repeating: 1, count: 64)) }
        else { #expect(try Data(contentsOf: missing) == Data(repeating: 2, count: 64)) }
    }

    @Test("budget rechecks reconciled usage and counts only needed physical retirements",
          arguments: [false, true], [128, 192])
    func budgetAfterExternalLoss(busyOldest: Bool, limit: Int) throws {
        let f = try Fixture(), peer = try Fixture()
        let oldest = try f.file(1), second = try f.file(2), third = try f.file(3)
        let peerFile = try peer.file(4)
        let epoch = try #require(f.epoch.current)
        let lease = busyOldest ? SSDCheckpointFileCoordinator.shared.tryAcquire(to: oldest) : nil
        if busyOldest { _ = try #require(lease) }
        defer { lease?.release() }
        try FileManager.default.removeItem(at: busyOldest ? second : oldest)
        let budget = SSDDiskBudget()
        budget.register(f)
        budget.register(peer)
        #expect(budget.totalBytes == 256)
        let expectedEvictions = limit == 192 ? 0 : 1
        #expect(budget.enforce(budgetBytes: limit) == expectedEvictions)
        #expect(budget.evictionCount == expectedEvictions)
        #expect(budget.totalBytes == limit)
        let candidate = busyOldest ? third : second
        #expect(FileManager.default.fileExists(atPath: candidate.path) == (expectedEvictions == 0))
        let survivor = busyOldest ? oldest : third
        #expect(try Data(contentsOf: survivor) == Data(repeating: busyOldest ? 1 : 3, count: 64))
        #expect(try Data(contentsOf: peerFile) == Data(repeating: 4, count: 64))
        #expect(f.epoch.current == epoch)
    }

    @Test("a fully leased store does not stop budget eviction in another store")
    func budgetSkipsBusyStore() throws {
        let busy = try Fixture(), peer = try Fixture()
        let oldest = try busy.file(1), victim = try peer.file(2)
        let lease = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: oldest))
        defer { lease.release() }
        let budget = SSDDiskBudget()
        budget.register(busy)
        budget.register(peer)
        #expect(budget.enforce(budgetBytes: 0) == 1)
        #expect(budget.evictionCount == 1)
        #expect(budget.totalBytes == 64)
        #expect(try Data(contentsOf: oldest) == Data(repeating: 1, count: 64))
        #expect(!FileManager.default.fileExists(atPath: victim.path))
    }

    @Test("a refused epoch leaves all files indexed and untouched")
    func disownedEviction() throws {
        let f = try Fixture()
        let first = try f.file(1), second = try f.file(2)
        try Data("invalid record".utf8).write(to: f.model.appendingPathComponent("cache-epoch.json"))
        #expect(f.evictOldest() == 0)
        #expect(f.index.totalBytes == 128)
        #expect(try Data(contentsOf: first) == Data(repeating: 1, count: 64))
        #expect(try Data(contentsOf: second) == Data(repeating: 2, count: 64))
    }

    @Test("fallback stays bounded when retirement touches the first tag and inserts more entries")
    func boundedFallback() {
        let index = SSDBlockIndex()
        var attempts: [Data] = []
        #expect(SSDOwnedEntryRetirement.evictOldest(index: index) { tag in
            attempts.append(tag)
            return .init()
        } == 0)
        #expect(attempts.isEmpty)
        for byte: UInt8 in [1, 2, 3] {
            index.insert(tag16: Data(repeating: byte, count: 16), fileBytes: 64, lastAccess: Int64(byte))
        }
        #expect(SSDOwnedEntryRetirement.evictOldest(index: index) { tag in
            attempts.append(tag)
            // This also verifies the callback does not hold the index lock.
            index.touch(tags16: [Data(repeating: 1, count: 16)], now: 100)
            if attempts.count > 1 {
                index.insert(tag16: Data(repeating: UInt8(100 + attempts.count), count: 16),
                             fileBytes: 64, lastAccess: 0)
            }
            return .init()
        } == 0)
        #expect(attempts == [1, 2, 3].map { Data(repeating: UInt8($0), count: 16) })
    }

    @Test("fallback snapshots changes during the probe, then freezes order and membership")
    func fallbackSnapshotBoundary() {
        let index = SSDBlockIndex()
        func tag(_ byte: UInt8) -> Data { Data(repeating: byte, count: 16) }
        for byte: UInt8 in [1, 2, 3] {
            index.insert(tag16: tag(byte), fileBytes: 64, lastAccess: Int64(byte))
        }
        var attempts: [Data] = []
        #expect(SSDOwnedEntryRetirement.evictOldest(index: index) { candidate in
            attempts.append(candidate)
            if attempts.count == 1 {
                index.touch(tags16: [tag(1), tag(2)], now: 100)
                index.insert(tag16: tag(4), fileBytes: 64, lastAccess: 0)
            } else {
                // Neither a new oldest entry nor changed recency can restart
                // selection once the fallback snapshot exists.
                index.touch(tags16: [tag(2)], now: -1)
                index.insert(tag16: tag(5), fileBytes: 64, lastAccess: -2)
                index.remove(tag16: tag(1))
                index.insert(tag16: tag(1), fileBytes: 64, lastAccess: -3)
            }
            return .init()
        } == 0)
        #expect(attempts == [1, 4, 3, 2].map { tag($0) })
    }

    @Test("known retirement preserves durable identity, sequence and survivor bytes")
    func preservesIdentity() throws {
        let f = try Fixture()
        let victim = try f.file(1), survivor = try f.file(2)
        let original = try #require(f.epoch.current)
        #expect(f.epoch.takeNextSequence(expectedEpoch: original) == 1)
        let bytes = try Data(contentsOf: survivor)
        let result = try #require(SSDOwnedEntryRetirement.remove(urls: [victim], root: f.model, index: f.index, epochStore: f.epoch))
        #expect(result.removed == [victim.path])
        #expect(result.indexedBytesFreed == 64)
        #expect(!result.externalChange)
        #expect(!FileManager.default.fileExists(atPath: victim.path))
        #expect(try Data(contentsOf: survivor) == bytes)
        #expect(f.epoch.current == original)
        #expect(f.epoch.takeNextSequence(expectedEpoch: original) == 2)
        let reopened = try SSDCacheEpochStore(root: f.model, binding: f.binding)
        #expect(reopened.current == original)
        #expect(reopened.takeNextSequence(expectedEpoch: original) == 3)
    }

    @Test("an unindexed in-flight rename survives while unrelated victims can retire")
    func skipsUncommittedFile() throws {
        let f = try Fixture()
        let inFlight = try f.file(1), victim = try f.file(2), survivor = try f.file(3)
        let tag = Data(repeating: 1, count: 16)
        f.index.remove(tag16: tag)
        let epoch = try #require(f.epoch.current)
        let lease = try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: inFlight))
        defer { lease.release() }
        let result = try #require(SSDOwnedEntryRetirement.remove(
            urls: [inFlight, victim], root: f.model, index: f.index, epochStore: f.epoch))
        #expect(result.removed == [victim.path])
        #expect(!result.externalChange)
        #expect(FileManager.default.fileExists(atPath: inFlight.path))
        #expect(FileManager.default.fileExists(atPath: survivor.path))
        f.index.insert(tag16: tag, fileBytes: 64, lastAccess: 1)
        lease.release()
        let after = try #require(SSDOwnedEntryRetirement.remove(
            urls: [inFlight], root: f.model, index: f.index, epochStore: f.epoch))
        #expect(after.removed == [inFlight.path])
        #expect(!f.index.contains(tag16: tag))
        #expect(f.epoch.current == epoch)
    }

    @Test("unexpected missing and replaced files request destructive reconciliation")
    func unexpectedMutation() throws {
        let f = try Fixture()
        let missing = try f.file(1), replaced = try f.file(2), outside = f.root.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: missing)
        try FileManager.default.removeItem(at: replaced)
        try FileManager.default.createSymbolicLink(at: replaced, withDestinationURL: outside)
        let result = try #require(SSDOwnedEntryRetirement.remove(urls: [missing, replaced], root: f.model, index: f.index, epochStore: f.epoch))
        #expect(result.externalChange)
        #expect(result.removed.isEmpty)
        #expect(f.index.count == 2, "owner must revoke evidence before forgetting unexpected loss")
        #expect(try Data(contentsOf: outside) == Data("untouched".utf8))
    }

    @Test("foreign-root paths are not retired")
    func rejectsForeignPaths() throws {
        let f = try Fixture(), other = try Fixture()
        let own = try f.file(1), foreign = try other.file(1)
        let result = try #require(SSDOwnedEntryRetirement.remove(urls: [foreign], root: f.model, index: f.index, epochStore: f.epoch))
        #expect(result.removed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: own.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test("a long batch retires in short holds, each through the epoch barrier")
    func longBatchRetiresInSlices() throws {
        let f = try Fixture()
        let urls = try (1 ... 40).map { try f.file(UInt8($0)) }
        let original = try #require(f.epoch.current)
        var slices: [Int] = []
        let result = SSDOwnedEntryRetirement.removeInSlices(urls) { slice in
            slices.append(slice.count)
            return SSDOwnedEntryRetirement.remove(urls: slice, root: f.model, index: f.index, epochStore: f.epoch)
        }
        #expect(slices == [16, 16, 8])
        #expect(result.removed == Set(urls.map(\.path)))
        #expect(result.indexedBytesFreed == 40 * 64)
        #expect(!result.externalChange)
        #expect(f.index.count == 0)
        #expect(f.epoch.current == original)
    }

    @Test("a refused slice stops the batch and keeps what earlier slices removed")
    func refusedSliceStopsTheBatch() throws {
        let f = try Fixture()
        let urls = try (1 ... 40).map { try f.file(UInt8($0)) }
        let record = f.model.appendingPathComponent("cache-epoch.json")
        var slices: [Int] = []
        let result = SSDOwnedEntryRetirement.removeInSlices(urls) { slice in
            slices.append(slice.count)
            // Ownership is lost after the first slice.
            if slices.count == 2 { try? Data("invalid record".utf8).write(to: record) }
            return SSDOwnedEntryRetirement.remove(urls: slice, root: f.model, index: f.index, epochStore: f.epoch)
        }
        #expect(slices == [16, 16])
        #expect(result.removed == Set(urls.prefix(16).map(\.path)))
        #expect(urls.dropFirst(16).allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        #expect(f.epoch.current == nil)
    }

    @Test("an empty batch still makes one ownership-checked call")
    func emptyBatchMakesOneCall() throws {
        let f = try Fixture()
        var calls = 0
        let result = SSDOwnedEntryRetirement.removeInSlices([]) { slice in
            calls += 1
            return SSDOwnedEntryRetirement.remove(urls: slice, root: f.model, index: f.index, epochStore: f.epoch)
        }
        #expect(calls == 1)
        #expect(result.removed.isEmpty && result.indexedBytesFreed == 0 && !result.externalChange)
    }

    @Test("invalid epoch record disables retirement and advertisement without deleting files")
    func invalidRecordFailsClosed() throws {
        let f = try Fixture()
        let victim = try f.file(1)
        let record = f.model.appendingPathComponent("cache-epoch.json")
        try Data("invalid record".utf8).write(to: record)
        #expect(SSDOwnedEntryRetirement.remove(urls: [victim], root: f.model, index: f.index, epochStore: f.epoch) == nil)
        #expect(f.epoch.current == nil)
        #expect(FileManager.default.fileExists(atPath: victim.path))
        #expect(f.index.count == 1)
    }
}
