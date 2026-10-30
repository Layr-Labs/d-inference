import CryptoKit
import Darwin
import Foundation
import Testing
@testable import ProviderCore

@Suite("Attention donations charge the write ledger once", .serialized)
struct SSDWriteBehindLedgerChargeTests {
    private static let now: Double = 100_000

    /// Holds the shared ledger's lock the way another writer's charge does.
    private final class LedgerHolder: @unchecked Sendable {
        private let path: String
        private let lock = NSLock()
        private var descriptor: Int32 = -1
        private var holds = 0

        init(root: URL) { path = root.appendingPathComponent(".write-budget").path }

        /// Times the lock was taken. Checked in the test body, since `hold`
        /// can run on the writer's task.
        var acquisitions: Int { lock.withLock { holds } }

        func hold() {
            lock.withLock {
                guard descriptor < 0 else { return }
                let opened = open(path, O_RDWR | O_CLOEXEC)
                guard opened >= 0 else { return }
                guard flock(opened, LOCK_EX) == 0 else { close(opened); return }
                descriptor = opened
                holds += 1
            }
        }

        func release() {
            lock.withLock {
                guard descriptor >= 0 else { return }
                flock(descriptor, LOCK_UN)
                close(descriptor)
                descriptor = -1
            }
        }
    }

    private func directory(_ label: String) throws -> URL {
        let url = try SSDTestDirectory.parent()
            .appendingPathComponent("ssd-ledger-charge-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func block(_ index: UInt8) -> SSDBlockWrite {
        let tag = Data(repeating: index, count: 16)
        return SSDBlockWrite(
            tag16: tag, tag16Hex: SSDLookupKeys.hex(tag),
            metadata: SSDBlockMetadata(
                lookupTag: String(repeating: "ab", count: 32), weightHash: "w", layoutEpoch: "layout",
                blockSize: 8, layerCount: 1, chunks: [], chunkPlaintextSizes: [], createdAt: 10_000),
            chunks: [], plaintextBytes: 1)
    }

    private func writer(
        root: URL, limiter: SSDWriteRateLimiter, stats: SSDPrefixCacheStatsBox,
        writeBlock: @escaping @Sendable (SSDBlockWrite, URL) throws -> Int = { _, _ in 1 },
        onBlockSettled: @escaping @Sendable (Data) -> Void = { _ in }
    ) -> SSDWriteBehind {
        SSDWriteBehind(
            config: .init(
                root: root, kekKey: SymmetricKey(size: .bits256), strictFsync: false, ttlSeconds: 0,
                maxJobs: 2, maxQueuedBytes: 1 << 20, diskBudgetBytes: { 1 << 20 }, volumeSpace: { nil },
                nowSeconds: { 10_000 }, maintainWholeRoot: nil, writeBlock: writeBlock),
            rateLimiter: limiter, index: SSDBlockIndex(), diskBudget: SSDDiskBudget(), stats: stats,
            onBlockSettled: onBlockSettled, sweepExpired: {})
    }

    private func donate(_ writer: SSDWriteBehind, blocks: Int) async {
        #expect(writer.submit(.init(blocks: (1 ... blocks).map { block(UInt8($0)) }, totalBytes: blocks)))
        await writer.waitUntilDrained()
        writer.close()
    }

    private func blockCost() throws -> Int {
        try SSDBlockStore.serializedByteCount(metadata: block(1).metadata)
    }

    @Test("a donation of several blocks touches the shared ledger once, for their summed size")
    func oneChargePerDonation() async throws {
        let ledgerRoot = try directory("ledger"), modelRoot = try directory("model")
        defer { for url in [ledgerRoot, modelRoot] { try? FileManager.default.removeItem(at: url) } }
        let limiter = SSDWriteRateLimiter(
            capBytesPerDay: 1 << 30, writeBudget: try SSDWriteBudget(root: ledgerRoot),
            nowSeconds: { Self.now })
        let holder = LedgerHolder(root: ledgerRoot)
        defer { holder.release() }
        let stats = SSDPrefixCacheStatsBox()
        // Another writer takes the ledger as the first block is written. A
        // per-block charge for any later block would then be refused.
        await donate(
            writer(root: modelRoot, limiter: limiter, stats: stats,
                   writeBlock: { _, _ in holder.hold(); return 1 }),
            blocks: 4)
        #expect(holder.acquisitions == 1)
        #expect(stats.snapshot().blocksWritten == 4)
        #expect(stats.snapshot().writeRateLimited == 0)
        holder.release()
        // The ledger holds exactly the four blocks' serialized size.
        let charged = 4 * (try blockCost())
        let ledger = try SSDWriteBudget(root: ledgerRoot)
        #expect(ledger.admit(bytes: 0, capBytesPerDay: charged, now: Self.now, consume: false))
        #expect(!ledger.admit(bytes: 1, capBytesPerDay: charged, now: Self.now, consume: false))
    }

    @Test("a donation charge refused by a busy ledger falls back to charging block by block")
    func busyLedgerFallsBackToBlockCharges() async throws {
        let ledgerRoot = try directory("ledger"), modelRoot = try directory("model")
        defer { for url in [ledgerRoot, modelRoot] { try? FileManager.default.removeItem(at: url) } }
        let limiter = SSDWriteRateLimiter(
            capBytesPerDay: 1 << 30, writeBudget: try SSDWriteBudget(root: ledgerRoot),
            nowSeconds: { Self.now })
        let holder = LedgerHolder(root: ledgerRoot)
        defer { holder.release() }
        let stats = SSDPrefixCacheStatsBox()
        // The ledger is busy for the donation's charge and the first block's,
        // then free for the remaining blocks.
        holder.hold()
        #expect(holder.acquisitions == 1)
        await donate(
            writer(root: modelRoot, limiter: limiter, stats: stats,
                   onBlockSettled: { _ in holder.release() }),
            blocks: 4)
        #expect(stats.snapshot().blocksWritten == 3)
        #expect(stats.snapshot().writeRateLimited == 1)
    }

    @Test("near the daily cap, the leading blocks that fit are still written")
    func nearCapWritesLeadingBlocks() async throws {
        let ledgerRoot = try directory("ledger"), modelRoot = try directory("model")
        defer { for url in [ledgerRoot, modelRoot] { try? FileManager.default.removeItem(at: url) } }
        let cost = try blockCost()
        let limiter = SSDWriteRateLimiter(
            capBytesPerDay: 2 * cost + cost / 2, writeBudget: try SSDWriteBudget(root: ledgerRoot),
            nowSeconds: { Self.now })
        let stats = SSDPrefixCacheStatsBox()
        await donate(writer(root: modelRoot, limiter: limiter, stats: stats), blocks: 4)
        #expect(stats.snapshot().blocksWritten == 2)
        #expect(stats.snapshot().writeRateLimited == 2)
    }

    @Test("when other stores have spent the shared ledger, the leading blocks that fit are still written")
    func nearSharedLedgerCapWritesLeadingBlocks() async throws {
        let ledgerRoot = try directory("ledger"), modelRoot = try directory("model")
        defer { for url in [ledgerRoot, modelRoot] { try? FileManager.default.removeItem(at: url) } }
        let cost = try blockCost()
        let cap = 1 << 30
        // This store's own bucket is full; another store has spent the shared
        // ledger down to two and a half blocks.
        #expect(try SSDWriteBudget(root: ledgerRoot).admit(
            bytes: cap - (2 * cost + cost / 2), capBytesPerDay: cap, now: Self.now, consume: true))
        let limiter = SSDWriteRateLimiter(
            capBytesPerDay: cap, writeBudget: try SSDWriteBudget(root: ledgerRoot), nowSeconds: { Self.now })
        let stats = SSDPrefixCacheStatsBox()
        await donate(writer(root: modelRoot, limiter: limiter, stats: stats), blocks: 4)
        #expect(stats.snapshot().blocksWritten == 2)
        #expect(stats.snapshot().writeRateLimited == 2)
    }
}
