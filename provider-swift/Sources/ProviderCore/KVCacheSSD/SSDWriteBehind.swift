// Copyright © 2026 Eigen Labs.
//
// Bounded write-behind pipeline for the SSD prefix cache: donations are
// extracted to host buffers on the engine's donation queue (inside
// `SSDPrefixCache.donate`), then handed here for the slow work —
// endurance/rate accounting, low-disk guard, DBK3 encrypt, atomic write,
// index insert, box-wide budget enforcement, opportunistic TTL sweep.
//
// Bounding model = `BoundedSingleConsumerPipeline` (né the legacy
// engine's `CheckpointCapturePipeline` — the fix for the Gemma-4
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
    /// Re-probes the durable leading run after at least one block landed (or an
    /// all-deduped job) and post-write maintenance completed. Returns true only
    /// when the surviving run still clears the effective-token floor.
    let onDurable: (@Sendable () -> Bool)?
    let onOutcome: @Sendable (PrefixCacheDonationOutcome) -> Void

    init(
        blocks: [SSDBlockWrite], totalBytes: Int,
        onDurable: (@Sendable () -> Bool)? = nil,
        onOutcome: @escaping @Sendable (PrefixCacheDonationOutcome) -> Void = { _ in }
    ) {
        self.blocks = blocks
        self.totalBytes = totalBytes
        self.onDurable = onDurable
        self.onOutcome = onOutcome
    }
}

enum SSDDonationSubmitResult: Sendable, Equatable {
    case accepted
    case queueFull
    case closed
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
        /// Production whole-root maintenance. nil keeps the legacy registered-
        /// store budget seam used by isolated tests.
        let maintainWholeRoot: (@Sendable () -> Void)?
        /// Failure-injection seam. nil uses the real encrypted DBK3 writer.
        let writeBlock: (@Sendable (SSDBlockWrite, URL) throws -> Int)?
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
    private var closed = false
    private var enospcCooldownUntil: Int64 = 0
    private var pipeline: BoundedSingleConsumerPipeline<SSDDonationJob>!

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
        self.pipeline = BoundedSingleConsumerPipeline<SSDDonationJob>(
            capacity: max(1, config.maxJobs),
            onDropped: { [weak self] job in
                guard let self else {
                    job.onOutcome(.cacheClosed)
                    return
                }
                self.settleDroppedOnClose(job)
            }
        ) { [weak self] job in
            guard let self else {
                job.onOutcome(.cacheClosed)
                return
            }
            self.consume(job)
        }
    }

    /// Cheap endurance pre-check (no consumption): false when the daily
    /// write budget could not cover a `bytes`-sized donation right now, so
    /// `donate` can skip the device-slice/eval/host-copy extraction for
    /// blocks the consumer would drop anyway. Advisory only — the consumer
    /// still `tryConsume`s per block (the bucket can drain between check
    /// and write); correctness never depends on this answer.
    func mightAcceptWrite(bytes: Int) -> Bool {
        rateLimiter.mightAccept(bytes: bytes)
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
        submitWithResult(job) == .accepted
    }

    func submitWithResult(_ job: SSDDonationJob) -> SSDDonationSubmitResult {
        let admission = queuedBytesLock.withLock { () -> SSDDonationSubmitResult in
            guard !closed else { return .closed }
            guard queuedJobs < config.maxJobs,
                queuedBytes + job.totalBytes <= config.maxQueuedBytes
            else { return .queueFull }
            queuedJobs += 1
            queuedBytes += job.totalBytes
            return .accepted
        }
        guard admission == .accepted else { return admission }
        guard pipeline.submit(job) else {
            // Pipeline shut down (never a capacity eviction — see above).
            let result: SSDDonationSubmitResult = queuedBytesLock.withLock {
                queuedJobs -= 1
                queuedBytes -= job.totalBytes
                return closed ? .closed : .queueFull
            }
            return result
        }
        return .accepted
    }

    /// Stop accepting and cancel the consumer. In-flight write completes;
    /// buffered jobs are dropped (their in-flight tags are settled by the
    /// owner's `close()` clearing the whole set). On-disk files remain —
    /// they are the product.
    func close() {
        queuedBytesLock.withLock { closed = true }
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
        // Empty jobs represent all-deduped, already-durable donations. For a
        // real job, at least one successful write allows settlement to reprobe
        // a shorter leading contiguous run after all attempts complete.
        var durableWriteSucceeded = job.blocks.isEmpty
        var rateLimited = false
        var diskUnavailable = false
        defer {
            // Opportunistic maintenance on the serial consumer: TTL sweep +
            // box-wide LRU budget enforcement (unlink-only, spec §4.1).
            sweepExpired()
            if let maintainWholeRoot = config.maintainWholeRoot {
                maintainWholeRoot()
                diskBudget.reconcileAll()
            } else {
                diskBudget.enforce(budgetBytes: config.diskBudgetBytes())
            }
            let readyReceiptSettled = durableWriteSucceeded ? job.onDurable?() : nil
            let closedAtSettlement = queuedBytesLock.withLock { closed }
            let outcome: PrefixCacheDonationOutcome
            if job.blocks.isEmpty {
                outcome = .alreadyDurable
            } else if !durableWriteSucceeded && rateLimited {
                outcome = .writeRateLimited
            } else if !durableWriteSucceeded && diskUnavailable {
                outcome = .diskUnavailable
            } else if !durableWriteSucceeded {
                outcome = .writeFailed
            } else if closedAtSettlement {
                outcome = .cacheClosed
            } else if job.onDurable != nil && readyReceiptSettled != true {
                outcome = .writeFailed
            } else {
                outcome = .donated
            }
            job.onOutcome(outcome)
        }

        let now = config.nowSeconds()
        if now < queuedBytesLock.withLock({ enospcCooldownUntil }) {
            diskUnavailable = true
            settleAll(job, dropped: job.blocks.count)
            return
        }
        // Low-disk guard: stop writing under max(20 GiB, 5% capacity) free.
        if let space = config.volumeSpace() {
            let floor = SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: space.capacity)
            if space.free < floor {
                diskUnavailable = true
                settleAll(job, dropped: job.blocks.count)
                return
            }
        }

        for block in job.blocks {
            defer { onBlockSettled(block.tag16) }
            guard rateLimiter.tryConsume(bytes: block.plaintextBytes) else {
                rateLimited = true
                stats.add(donationsDropped: 1, writeRateLimited: 1)
                continue
            }
            let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: block.tag16Hex)
            guard SSDBlockStore.isSafeBlockURL(url, modelRoot: config.root) else {
                stats.add(donationsDropped: 1)
                continue
            }
            let fileBytes: Int
            let sidecar = block.metadata.windowKind == nil ? 0 : 1
            do {
                if let writeBlock = config.writeBlock {
                    fileBytes = try writeBlock(block, url)
                    index.insert(tag16: block.tag16, fileBytes: fileBytes, lastAccess: now)
                    stats.add(
                        blocksWritten: 1, bytesWritten: fileBytes,
                        windowSidecarsWritten: sidecar)
                    durableWriteSucceeded = true
                    continue
                }
                fileBytes = try SSDBlockStore.write(
                    to: url, metadata: block.metadata, chunks: block.chunks,
                    kekKey: config.kekKey, strictFsync: config.strictFsync)
            } catch {
                stats.add(donationsDropped: 1)
                if isENOSPC(error) {
                    diskUnavailable = true
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
            // Index LAST, after the durable rename (spec §3.2 step 7).
            index.insert(tag16: block.tag16, fileBytes: fileBytes, lastAccess: now)
            stats.add(
                blocksWritten: 1, bytesWritten: fileBytes, windowSidecarsWritten: sidecar)
            durableWriteSucceeded = true
        }
    }

    private func settleAll(_ job: SSDDonationJob, dropped: Int) {
        for block in job.blocks { onBlockSettled(block.tag16) }
        stats.add(donationsDropped: dropped)
    }

    private func settleDroppedOnClose(_ job: SSDDonationJob) {
        queuedBytesLock.withLock {
            queuedJobs = max(0, queuedJobs - 1)
            queuedBytes = max(0, queuedBytes - job.totalBytes)
        }
        settleAll(job, dropped: job.blocks.count)
        job.onOutcome(.cacheClosed)
    }

    private func isENOSPC(_ error: Error) -> Bool {
        // Surface shape: SSDBlockStoreError.ioFailure(wrapping CocoaError /
        // POSIXError ENOSPC). String probe keeps this dependency-free.
        String(describing: error).contains("No space left on device")
    }
}
