import CryptoKit
import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

/// Budget eviction of a closed store, for both active store types. A closed
/// store refuses every removal and is never reopened, so a pass over it frees
/// nothing whether it ends at once or refuses each remaining candidate.
@Suite("Closed SSD store eviction", .serialized)
struct SSDClosedStoreEvictionTests {
    enum Kind: CaseIterable {
        case prefix
        case checkpoint
    }

    /// One active store over real files and a real epoch record. Retirement
    /// never reads payloads, so the indexed files are plain fixtures.
    final class ActiveStore: @unchecked Sendable {
        let store: any SSDEvictableStore
        let index: SSDBlockIndex
        let root: URL
        let close: () -> Void
        let evictions: () -> Int
        private let cleanup: () -> Void
        private(set) var files: [URL] = []

        init(_ kind: Kind, diskBudget: SSDDiskBudget = SSDDiskBudget()) throws {
            switch kind {
            case .prefix:
                let dedicated = try SSDTestDirectory.parent()
                    .appendingPathComponent("closed-eviction-\(UUID().uuidString)", isDirectory: true)
                let model = dedicated.appendingPathComponent("0123456789ab", isDirectory: true)
                try SSDBlockStore.prepareModelRoot(dedicatedRoot: dedicated, modelRoot: model)
                let epochStore = try SSDCacheEpochStore(root: model, binding: .init(
                    modelId: "closed-eviction", modelAggregateHash: "weights", promptContractId: "contract",
                    blockHashVersion: "dbk3", blockSize: 8, layoutEpoch: "layout", keyFingerprint: "key"))
                let kinds = [CBv2LayerKind(attention: .full, headDim: 8, kvHeads: 2, queryHeads: 4)]
                let cache = SSDPrefixCache(
                    config: .init(
                        modelId: "closed-eviction", promptContractID: "contract", weightHash: "weights",
                        blockSize: 8, adoptionBoundTokens: 0,
                        layoutEpoch: SSDBlockStore.layoutEpoch(blockSize: 8, layerKinds: kinds),
                        epochStore: epochStore, root: model, ttlSeconds: 3_600, minEffectiveTokens: 8,
                        maxStageBytes: 1 << 30, maxStageMillis: 1_000_000,
                        nowSeconds: { Int64(Date().timeIntervalSince1970) }),
                    kekKey: SymmetricKey(size: .bits256), kvBudget: nil, diskBudget: diskBudget,
                    maxWriteBytesPerDay: 0, diskBudgetBytes: { 1 << 40 })
                store = cache
                index = cache.index
                root = model
                close = { cache.close() }
                evictions = { cache.stats().evictions }
                cleanup = { try? FileManager.default.removeItem(at: dedicated) }
            case .checkpoint:
                let fixture = try SSDHybridCheckpointTestFixture()
                let checkpoints = try fixture.makeStore(diskBudget: diskBudget)
                store = checkpoints
                index = checkpoints.index
                root = fixture.modelRoot
                close = { checkpoints.close() }
                evictions = { checkpoints.stats().evictions }
                cleanup = { fixture.remove() }
            }
        }

        deinit {
            close()
            cleanup()
        }

        /// Indexed regular files, oldest first, all within the TTL.
        func addFiles(_ count: Int, marker: UInt8, newest: Int64) throws {
            for i in 0 ..< count {
                var tag = Data(repeating: marker, count: 16)
                tag[14] = UInt8(i >> 8)
                tag[15] = UInt8(i & 0xFF)
                let url = SSDBlockStore.fileURL(root: root, tag16Hex: tag.hexString)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: marker, count: 64).write(to: url)
                index.insert(tag16: tag, fileBytes: 64, lastAccess: newest - Int64(count - i))
                files.append(url)
            }
        }

        var filesPresent: Int { files.count(where: { FileManager.default.fileExists(atPath: $0.path) }) }
    }

    @Test("a closed store evicts nothing and does not stop eviction in a peer", arguments: Kind.allCases)
    func closedStoreEvictsNothing(kind: Kind) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let closed = try ActiveStore(kind)
        try closed.addFiles(8, marker: 0xC1, newest: now - 100)
        closed.close()

        #expect(closed.store.evictOldestEntry() == 0)
        #expect(closed.index.count == 8)
        #expect(closed.filesPresent == 8)
        #expect(closed.evictions() == 0)

        // close() deregisters last; until then the budget can still pick it.
        let peer = try ActiveStore(kind)
        try peer.addFiles(4, marker: 0xC2, newest: now)
        let budget = SSDDiskBudget()
        budget.register(closed.store)
        budget.register(peer.store)
        #expect(budget.enforce(budgetBytes: budget.totalBytes - 1) == 1)
        #expect(closed.index.count == 8)
        #expect(closed.filesPresent == 8)
        #expect(closed.evictions() == 0)
        #expect(peer.index.count == 3)
        #expect(peer.filesPresent == 3)
        #expect(peer.evictions() == 1)
        #expect(FileManager.default.fileExists(atPath: peer.files[1].path))
        #expect(!FileManager.default.fileExists(atPath: peer.files[0].path))
    }

    /// The pass walks many busy (leased) files before it reaches deletable
    /// ones, and the store closes while it does: each busy attempt rereads
    /// the epoch record and probes the lease. A closed store refuses every
    /// later candidate, so the pass frees nothing whether it stops or refuses
    /// each remaining one in turn. A pass that starts after the close starts
    /// closed, with the same outcome.
    @Test("a store that closes during a pass frees nothing", arguments: Kind.allCases)
    func closingDuringAPassFreesNothing(kind: Kind) throws {
        let now = Int64(Date().timeIntervalSince1970)
        let s = try ActiveStore(kind)
        let busy = 3_000, deletable = 8
        try s.addFiles(busy + deletable, marker: 0xC3, newest: now)
        let leases = try s.files.prefix(busy).map {
            try #require(SSDCheckpointFileCoordinator.shared.tryAcquire(to: $0))
        }
        defer { leases.forEach { $0.release() } }

        let outcome = Outcome()
        let store = s.store
        Thread.detachNewThread {
            outcome.freed = store.evictOldestEntry()
            outcome.done.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        s.close()
        #expect(outcome.done.wait(timeout: .now() + 300) == .success)

        #expect(outcome.freed == 0)
        #expect(s.index.count == busy + deletable)
        #expect(s.filesPresent == busy + deletable)
        #expect(s.evictions() == 0)
    }
}

private final class Outcome: @unchecked Sendable {
    var freed = -1
    let done = DispatchSemaphore(value: 0)
}
