import Foundation
import Testing
@testable import ProviderCore

@Suite("Owned SSD retirement", .serialized)
struct SSDOwnedEntryRetirementTests {
    final class Fixture {
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
