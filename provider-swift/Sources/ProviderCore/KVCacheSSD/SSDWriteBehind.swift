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
        /// How `diskBudgetBytes` moves as bytes land, used only to tell an
        /// in-flight speculative checkpoint elsewhere to give way. nil means
        /// the budget does not move with writes.
        var diskBudgetBasis: (@Sendable () -> SSDDiskBudgetBasis)? = nil
    }

    let config: Config
    /// This writer's keys on the disk budget's ledger, resolved once.
    private let modelRootKey: String
    private let wholeRootKey: String
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
    /// Upper bound of the stored bytes of the jobs still queued: each
    /// block's file is its plaintext plus at most the megabyte of framing
    /// the read path allows for. A job leaves it when its exact bytes are
    /// recorded on the disk budget's ledger.
    private var queuedStoredBound = 0
    /// The registered store whose index this writer fills. Set once by that
    /// store; nil in tests that drive the writer alone.
    private weak var owner: (any SSDEvictableStore)?
    private var hasOwner = false
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
        self.modelRootKey = SSDDiskBudget.rootKey(config.root)
        self.wholeRootKey = SSDDiskBudget.wholeRootKey(ofModelRoot: config.root)
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
            await self.consume(job)
        }
    }

    func setOwner(_ store: any SSDEvictableStore) {
        queuedBytesLock.withLock { owner = store; hasOwner = true }
    }

    var ownerStore: (any SSDEvictableStore)? { queuedBytesLock.withLock { owner } }

    /// What a speculative checkpoint elsewhere on the budget must leave
    /// room for on account of the jobs queued here.
    var queuedStoredBytes: Int { queuedBytesLock.withLock { max(0, queuedStoredBound) } }

    private static func storedBound(_ job: SSDDonationJob) -> Int {
        let (framing, framingOverflow) = job.blocks.count.multipliedReportingOverflow(by: 1 << 20)
        let (bound, overflow) = job.totalBytes.addingReportingOverflow(framing)
        return framingOverflow || overflow ? Int.max / 4 : bound
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
    /// Job/byte counters enforce both caps before enqueue. The underlying
    /// pipeline also uses bufferingOldest: overflow drops this donation,
    /// whose tags the caller settles, and preserves accepted FIFO work.
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
            queuedStoredBound += Self.storedBound(job)
            return .accepted
        }
        guard admission == .accepted else { return admission }
        guard pipeline.submit(job) else {
            // Pipeline shut down (never a capacity eviction — see above).
            let result: SSDDonationSubmitResult = queuedBytesLock.withLock {
                queuedJobs -= 1
                queuedBytes -= job.totalBytes
                queuedStoredBound -= Self.storedBound(job)
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

    private func consume(_ job: SSDDonationJob) async {
        // These blocks share the box-wide disk budget with the complete-
        // checkpoint stores. The donation's exact stored bytes go on the
        // ledger here, before it leaves the queue's bound, and stay there
        // until each block is indexed or dropped: one record for the blocks
        // still to come, which revokes nothing, and one per block while it is
        // written. A speculative checkpoint in another store is therefore
        // never granted, published into or indexed into room this donation
        // is about to take. Never refused.
        let storedBytes = job.blocks.map {
            (try? SSDBlockStore.streamedFileBytes(for: $0.metadata)) ?? $0.plaintextBytes
        }
        let remainder = diskBudget.registerProven(
            bytes: storedBytes.reduce(0) {
                let (sum, overflow) = $0.addingReportingOverflow($1)
                return overflow ? Int.max / 4 : sum
            },
            keys: [], wholeRootKey: wholeRootKey, basis: nil,
            replacingQueued: {
                self.queuedBytesLock.withLock {
                    self.queuedJobs -= 1
                    self.queuedBytes -= job.totalBytes
                    self.queuedStoredBound -= Self.storedBound(job)
                }
            })
        // Empty jobs represent all-deduped, already-durable donations. For a
        // real job, at least one successful write allows settlement to reprobe
        // a shorter leading contiguous run after all attempts complete.
        var durableWriteSucceeded = job.blocks.isEmpty
        var rateLimited = false
        var diskUnavailable = false
        defer {
            diskBudget.release(remainder, as: .discarded)
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
        // Admit the whole donation above the reserve, not just its first
        // block. Like the hybrid checkpoint writer, account for the pending
        // payload before any I/O. This is not an OS disk-space reservation.
        if let space = config.volumeSpace() {
            let floor = SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: space.capacity)
            if space.free < floor || job.totalBytes > space.free - floor {
                diskUnavailable = true
                settleAll(job, dropped: job.blocks.count)
                return
            }
        }

        for (position, block) in job.blocks.enumerated() {
            var recorded = false
            defer {
                // A block that is skipped leaves the donation's record too.
                if !recorded { diskBudget.dropBlock(from: remainder, bytes: storedBytes[position]) }
                onBlockSettled(block.tag16)
            }
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
            let access = SSDCheckpointFileCoordinator.shared.makeAccess(to: url)
            do {
                try await access.acquire()
            } catch {
                stats.add(donationsDropped: 1)
                continue
            }
            // Scope is this iteration, not the entire donation. Release before
            // the function's deferred TTL/whole-root/budget maintenance runs.
            defer { access.release() }
            guard !Task.isCancelled, !queuedBytesLock.withLock({ closed }) else {
                stats.add(donationsDropped: 1)
                continue
            }
            // The block moves from the donation's record to one of its own,
            // named so the whole-root pass knows its temp file. A speculative
            // checkpoint in flight elsewhere is told to give way if the room
            // is now short: after this block's write-cap charge, so a block
            // that is rate-limited revokes nothing.
            let record = diskBudget.claimBlock(
                from: remainder, bytes: storedBytes[position],
                keys: [SSDDiskBudget.reservationKey(modelRootKey: modelRootKey, tag16Hex: block.tag16Hex)],
                basis: diskBudget.hasSpeculativeReservations
                    ? (config.diskBudgetBasis?() ?? .fixed(config.diskBudgetBytes())) : nil)
            recorded = true
            let fileBytes: Int
            let sidecar = block.metadata.windowKind == nil ? 0 : 1
            do {
                if let writeBlock = config.writeBlock {
                    fileBytes = try writeBlock(block, url)
                } else {
                    fileBytes = try SSDBlockStore.write(
                        to: url, metadata: block.metadata, chunks: block.chunks,
                        kekKey: config.kekKey, strictFsync: config.strictFsync)
                }
            } catch {
                diskBudget.release(record, as: .discarded)
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
            // Index LAST, after the durable rename (spec §3.2 step 7), in one
            // step with the release of the block's record on the ledger.
            let (store, known) = queuedBytesLock.withLock { (owner, hasOwner) }
            _ = diskBudget.commitProven(record, store: store, storeIsKnown: known) {
                index.insert(tag16: block.tag16, fileBytes: fileBytes, lastAccess: now)
                return true
            }
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
            queuedStoredBound = max(0, queuedStoredBound - Self.storedBound(job))
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
