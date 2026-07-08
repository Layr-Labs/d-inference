// Copyright © 2026 Eigen Labs.
//
// Bounded write-behind pipeline for the SSD prefix cache: donations are
// extracted to host buffers on the engine's donation queue (inside
// `SSDPrefixCache.donate`), then handed here for the slow work —
// endurance/rate accounting, low-disk guard, DBK2 encrypt, atomic write,
// index insert, box-wide budget enforcement, opportunistic TTL sweep.
//
// Bounding model = `CheckpointCapturePipeline` (the fix for the Gemma-4
// Metal resource-exhaustion class): a small AsyncStream buffer feeds ONE
// serial consumer; at most `maxJobs` jobs (and `maxQueuedBytes` host
// bytes) sit buffered, and overflow DROPS the donation — the cache is
// best-effort, the engine is never back-pressured. Failure at any step is
// skip + counter: a lost block is a future cold prefill, never an error.
//
// Ordering invariant (spec §3.2): the index is updated LAST, after the
// durable rename — the index never references a file that isn't fully on
// disk. Crash between write and index insert: the startup scan finds the
// file. Crash mid-write: the temp sweep removes the orphan.

import CryptoKit
import Foundation
#if canImport(os)
import os
#endif

// MARK: - Job payloads

/// One encrypted block waiting to be written. `chunks` are compact host
/// `Data` buffers (already extracted from the donated device arrays).
struct SSDBlockWrite: Sendable {
    let tag16: Data
    let tag16Hex: String
    let metadata: SSDBlockMetadata
    let chunks: [Data]
    let plaintextBytes: Int
}

/// One donation's worth of NEW blocks (already deduped against the index
/// and the in-flight set).
struct SSDDonationJob: Sendable {
    let blocks: [SSDBlockWrite]
    let totalBytes: Int
}

// MARK: - Endurance rate limiter

/// Continuous-refill token bucket over encrypted bytes written
/// (default cap 150 GB/day — protects the 512 GB hot-box worst case;
/// at expected fleet volumes it never binds). Capacity 0 ⇒ unlimited.
final class SSDWriteRateLimiter: @unchecked Sendable {
    private let capBytesPerDay: Double
    private var tokens: Double
    private var lastRefill: Double
    private let nowSeconds: @Sendable () -> Double
    private let lock = NSLock()

    init(
        capBytesPerDay: Int,
        nowSeconds: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) {
        self.capBytesPerDay = Double(max(0, capBytesPerDay))
        self.tokens = Double(max(0, capBytesPerDay))
        self.nowSeconds = nowSeconds
        self.lastRefill = nowSeconds()
    }

    /// Consume `bytes` if the bucket allows; false ⇒ the write is dropped.
    func tryConsume(bytes: Int) -> Bool {
        guard capBytesPerDay > 0 else { return true }
        return lock.withLock {
            let now = nowSeconds()
            let elapsed = max(0, now - lastRefill)
            tokens = min(capBytesPerDay, tokens + elapsed * capBytesPerDay / 86_400.0)
            lastRefill = now
            guard tokens >= Double(bytes) else { return false }
            tokens -= Double(bytes)
            return true
        }
    }

    /// Cheap pre-check (no consumption) so `donate` can skip extraction
    /// work when the bucket is already empty.
    func mightAccept(bytes: Int) -> Bool {
        guard capBytesPerDay > 0 else { return true }
        return lock.withLock {
            let now = nowSeconds()
            let refilled = min(
                capBytesPerDay, tokens + max(0, now - lastRefill) * capBytesPerDay / 86_400.0)
            return refilled >= Double(bytes)
        }
    }
}

// MARK: - Write-behind

final class SSDWriteBehind: @unchecked Sendable {

    struct Config: Sendable {
        let root: URL
        let kekKey: SymmetricKey
        let strictFsync: Bool
        let ttlSeconds: Int64
        let maxJobs: Int
        let maxQueuedBytes: Int
        /// Box-wide budget resolver, re-evaluated per enforcement (env +
        /// live free disk — `PrefixCachePolicy.ssdDiskBudgetBytes`).
        let diskBudgetBytes: @Sendable () -> Int
        /// Volume (free, capacity) probe for the low-disk guard.
        let volumeSpace: @Sendable () -> (free: Int, capacity: Int)?
        let nowSeconds: @Sendable () -> Int64
    }

    private let config: Config
    private let rateLimiter: SSDWriteRateLimiter
    private let index: SSDBlockIndex
    private let diskBudget: SSDDiskBudget
    private let stats: SSDPrefixCacheStatsBox
    /// Removes a tag from the owner's in-flight set once its write landed
    /// (or was dropped) — dedupe correctness for concurrent donations.
    private let onBlockSettled: @Sendable (Data) -> Void
    /// TTL sweep hook (owner unlinks expired files) — run opportunistically
    /// after each job, on this serial consumer.
    private let sweepExpired: @Sendable () -> Void

    private let queuedBytesLock = NSLock()
    private var queuedBytes = 0
    /// Jobs admitted but not yet picked up by the consumer (see `submit`).
    private var queuedJobs = 0
    private var enospcCooldownUntil: Int64 = 0
    private var pipeline: CheckpointCapturePipeline<SSDDonationJob>!

    #if canImport(os)
    private static let logger = Logger(
        subsystem: "com.darkbloom.provider", category: "ssd_write_behind")
    #endif

    init(
        config: Config,
        rateLimiter: SSDWriteRateLimiter,
        index: SSDBlockIndex,
        diskBudget: SSDDiskBudget,
        stats: SSDPrefixCacheStatsBox,
        onBlockSettled: @escaping @Sendable (Data) -> Void,
        sweepExpired: @escaping @Sendable () -> Void
    ) {
        self.config = config
        self.rateLimiter = rateLimiter
        self.index = index
        self.diskBudget = diskBudget
        self.stats = stats
        self.onBlockSettled = onBlockSettled
        self.sweepExpired = sweepExpired
        self.pipeline = CheckpointCapturePipeline<SSDDonationJob>(
            capacity: max(1, config.maxJobs)
        ) { [weak self] job in
            self?.consume(job)
        }
    }

    /// Enqueue a donation job. Non-blocking; false ⇒ dropped (queue full /
    /// byte cap) — the caller settles the in-flight tags and counts the
    /// drop. Safe to call from the engine's donation queue.
    ///
    /// Admission is bounded on OUR job/byte counters (< maxJobs and
    /// ≤ maxQueuedBytes) so the pipeline's `.bufferingNewest` buffer can
    /// never overflow: an overflow would silently EVICT the OLDEST job,
    /// stranding its in-flight dedupe tags until restart (those blocks
    /// could never be rewritten). With the pre-count, a full queue drops
    /// THIS donation instead — whose tags the caller settles immediately.
    func submit(_ job: SSDDonationJob) -> Bool {
        let admitted = queuedBytesLock.withLock { () -> Bool in
            guard queuedJobs < config.maxJobs,
                queuedBytes + job.totalBytes <= config.maxQueuedBytes
            else { return false }
            queuedJobs += 1
            queuedBytes += job.totalBytes
            return true
        }
        guard admitted else { return false }
        guard pipeline.submit(job) else {
            // Pipeline shut down (never a capacity eviction — see above).
            queuedBytesLock.withLock {
                queuedJobs -= 1
                queuedBytes -= job.totalBytes
            }
            return false
        }
        return true
    }

    /// Stop accepting and cancel the consumer. In-flight write completes;
    /// buffered jobs are dropped (their in-flight tags are settled by the
    /// owner's `close()` clearing the whole set). On-disk files remain —
    /// they are the product.
    func close() {
        pipeline.shutdown()
    }

    /// Test seam: await the consumer draining.
    func waitUntilDrained() async {
        await pipeline.waitUntilDrained()
    }

    // MARK: - Consumer (serial)

    private func consume(_ job: SSDDonationJob) {
        queuedBytesLock.withLock {
            queuedJobs -= 1
            queuedBytes -= job.totalBytes
        }
        defer {
            // Opportunistic maintenance on the serial consumer: TTL sweep +
            // box-wide LRU budget enforcement (unlink-only, spec §4.1).
            sweepExpired()
            diskBudget.enforce(budgetBytes: config.diskBudgetBytes())
        }

        let now = config.nowSeconds()
        if now < queuedBytesLock.withLock({ enospcCooldownUntil }) {
            settleAll(job, dropped: job.blocks.count)
            return
        }
        // Low-disk guard: stop writing under max(20 GiB, 5% capacity) free.
        if let space = config.volumeSpace() {
            let floor = SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: space.capacity)
            if space.free < floor {
                settleAll(job, dropped: job.blocks.count)
                return
            }
        }

        for block in job.blocks {
            defer { onBlockSettled(block.tag16) }
            guard rateLimiter.tryConsume(bytes: block.plaintextBytes) else {
                stats.add(donationsDropped: 1, writeRateLimited: 1)
                continue
            }
            let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: block.tag16Hex)
            do {
                try SSDBlockStore.write(
                    to: url, metadata: block.metadata, chunks: block.chunks,
                    kekKey: config.kekKey, strictFsync: config.strictFsync)
            } catch {
                stats.add(donationsDropped: 1)
                if isENOSPC(error) {
                    queuedBytesLock.withLock {
                        enospcCooldownUntil = now + SSDPrefixCachePolicy.enospcCooldownSeconds
                    }
                    #if canImport(os)
                    Self.logger.warning(
                        "ssd prefix cache: ENOSPC — pausing writes for \(SSDPrefixCachePolicy.enospcCooldownSeconds)s")
                    #endif
                }
                continue
            }
            let fileBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                ?? block.plaintextBytes
            // Index LAST, after the durable rename (spec §3.2 step 7).
            index.insert(tag16: block.tag16, fileBytes: fileBytes, lastAccess: now)
            stats.add(blocksWritten: 1, bytesWritten: fileBytes)
        }
    }

    private func settleAll(_ job: SSDDonationJob, dropped: Int) {
        for block in job.blocks { onBlockSettled(block.tag16) }
        stats.add(donationsDropped: dropped)
    }

    private func isENOSPC(_ error: Error) -> Bool {
        // Surface shape: SSDBlockStoreError.ioFailure(wrapping CocoaError /
        // POSIXError ENOSPC). String probe keeps this dependency-free.
        String(describing: error).contains("No space left on device")
    }
}
