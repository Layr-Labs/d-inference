import CryptoKit
import Foundation
import MLXLMCommon

/// One slot's complete checkpoints for `memory_only` requests, held only in
/// wired RAM (`MemoryOnlyCheckpointPool`). It keeps the SSD tier's lookup and
/// restore semantics: the same scope-salted chain tags, position rules and
/// manifest checks, and the bytes the engine exported are replayed through the
/// engine's own import, as a restore from a file is. It writes no file and
/// never sees an ordinary request: the SSD store forwards only `memory_only`
/// receipts here, and anything else is refused and counted.
final class MemoryOnlyCheckpointTier: @unchecked Sendable {
    struct Config: Sendable {
        let identity: CBv2CompleteCheckpointIdentity
        let backendLayout: String
        let minEffectiveTokens: Int
    }

    /// Segments start on this boundary, so typed copies out of the region
    /// stay aligned.
    static let segmentAlignment = 64
    static let donationQueueCapacity = 4
    /// One segment the engine hands over plus the encoded manifest.
    static let copyScratchBytes = CBv2CompleteCheckpointManifest.maximumSegmentBytes
        + CBv2CompleteCheckpointManifest.maximumEncodedBytes

    let config: Config
    let namespace = UUID()
    private let pool: MemoryOnlyCheckpointPool
    private let kvBudget: GlobalKVCacheBudget?
    private let wire: LockedHostRegion.Wire
    /// A per-process key: RAM tags can't be matched to the SSD tier's file names.
    private let lookupKeys = SSDLookupKeys(kek: SymmetricKey(size: .bits256))
    private let lock = NSLock()
    private var closed = false
    private var stages: [CBv2RequestID: SSDCheckpointStage] = [:]
    private var stageLeases: [CBv2RequestID: SSDCheckpointStageReservation] = [:]
    private let activity = SSDCheckpointActivity()
    private let leaseStats = SSDHybridCheckpointStatsBox()
    private var donations: BoundedSingleConsumerPipeline<Donation>!

    private struct Donation: Sendable {
        let source: CBv2CompleteCheckpointExport
        let tag: Data
        let completion: @Sendable ([Int]) -> Void
    }

    init(
        config: Config, kvBudget: GlobalKVCacheBudget?, pool: MemoryOnlyCheckpointPool = .shared,
        wire: @escaping LockedHostRegion.Wire = { mlock($0, $1) }
    ) {
        self.config = config
        self.kvBudget = kvBudget
        self.pool = pool
        self.wire = wire
        donations = BoundedSingleConsumerPipeline(
            capacity: Self.donationQueueCapacity,
            onDropped: { [pool] in MemoryOnlyCheckpointTier.settleUnstored($0, pool: pool) },
            consume: { [weak self] donation in
                guard let self else {
                    donation.source.close()
                    donation.completion([])
                    return
                }
                self.store(donation)
            })
    }

    var isClosed: Bool { lock.withLock { closed } }

    /// Whether a `memory_only` request should keep its prefix cache for this
    /// tier: with no budget every capture would be refused after its export.
    var isAvailable: Bool { !isClosed && pool.budgetBytes > 0 }

    // MARK: - Donation

    /// Always calls `completion`, with no positions: a RAM entry is not a
    /// durable commit, so the engine publishes no ready evidence for it. The
    /// donor's KV stays owned by the engine until then.
    func donate(
        _ source: CBv2CompleteCheckpointExport, requestID: CBv2RequestID?,
        tokens: [Int], cacheSalt: String?, completion: @escaping @Sendable ([Int]) -> Void
    ) {
        func refuse(_ outcome: MemoryOnlyCheckpointPool.StoreOutcome?, counted: Bool = true) {
            source.close()
            if let outcome { pool.recordStoreRefusal(outcome) } else if counted { pool.recordUnmarkedRefusal() }
            completion([])
        }
        guard MemoryOnlyReceipt.contains(requestID) else { return refuse(nil) }
        let manifest = source.manifest
        let blockSize = PrefixCachePolicy.blockSize
        guard !isClosed, manifest.position >= config.minEffectiveTokens,
            manifest.position.isMultiple(of: blockSize),
            manifest.identity == config.identity, manifest.backendLayout == config.backendLayout,
            manifest.cacheSalt == cacheSalt, manifest.mediaIdentity == nil,
            manifest.position < tokens.count, tokens.starts(with: manifest.prefixTokens)
        else { return refuse(.refusedPolicy) }
        let chain = hashes(tokens: tokens, scope: cacheSalt ?? "", maximumBlocks: manifest.position / blockSize)
        guard chain.count == manifest.position / blockSize, let chainHash = chain.last else {
            return refuse(.refusedPolicy)
        }
        // Too large for the budget: refused before any copy or encode.
        let payloadBytes = manifest.tensors.reduce(0) { $0 + $1.byteCount }
        guard UInt64(payloadBytes) <= pool.budgetBytes else { return refuse(.refusedBudget) }
        let tag = lookupKeys.checkpointTag(chainHash: chainHash, cacheSalt: cacheSalt ?? "")
        guard !pool.holdsDuplicate(namespace: namespace, tag: tag) else { return refuse(nil, counted: false) }
        let donation = Donation(source: source, tag: tag, completion: completion)
        // A full or shut-down queue hands the donation back unsettled.
        if !donations.submit(donation) { Self.settleUnstored(donation, pool: pool) }
    }

    /// Settles a donation the queue did not store.
    private static func settleUnstored(_ donation: Donation, pool: MemoryOnlyCheckpointPool) {
        donation.source.close()
        pool.recordStoreRefusal(.refusedBusy)
        donation.completion([])
    }

    /// Copies the export into one wired region: the encoded manifest first,
    /// then each segment, zeroing the engine's transient copy of it.
    private func store(_ donation: Donation) {
        defer {
            donation.source.close()
            donation.completion([])
        }
        guard !isClosed else { return pool.recordStoreRefusal(.refusedPolicy) }
        // An earlier donation of this prefix, queued ahead of this one, is held now.
        guard !pool.holdsDuplicate(namespace: namespace, tag: donation.tag) else { return }
        // In shared process mode the provider owns the engine's segment copies,
        // as the SSD writer does.
        var copyBuffers: ProcessHostBufferReservation?
        if donation.source.usesProcessMemoryOwner {
            copyBuffers = kvBudget?.reserveHostBuffers(bytes: UInt64(Self.copyScratchBytes))
            guard copyBuffers != nil else { return pool.recordStoreRefusal(.refusedHeadroom) }
        }
        defer { copyBuffers?.closeAfterDroppingBuffers() }
        let manifest = donation.source.manifest
        var encoded: Data
        do {
            _ = try manifest.validateStructure()
            encoded = try JSONEncoder().encode(manifest)
        } catch { return pool.recordStoreRefusal(.refusedPolicy) }
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        guard encoded.count <= CBv2CompleteCheckpointManifest.maximumEncodedBytes,
            let layout = Self.layout(manifest: manifest, manifestBytes: encoded.count)
        else { return pool.recordStoreRefusal(.refusedPolicy) }
        guard let admission = pool.admit(bytes: layout.bytes, ledger: kvBudget) else { return }
        guard let region = LockedHostRegion(bytes: layout.bytes, wire: wire) else {
            return admission.cancel(outcome: .refusedLock)
        }
        do {
            try region.write(encoded, at: 0)
            for segment in layout.segments {
                var bytes = try donation.source.readSegment(
                    tensorIndex: segment.tensor, byteOffset: segment.offset, maximumBytes: segment.bytes)
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                guard bytes.count == segment.bytes else { throw CBv2CompleteCheckpointError.invalidSegment }
                try region.write(bytes, at: segment.regionOffset)
            }
        } catch {
            region.release()
            return admission.cancel(outcome: .refusedPolicy)
        }
        guard !isClosed else {
            region.release()
            return admission.cancel(outcome: .refusedPolicy)
        }
        let entry = MemoryOnlyCheckpointPool.Entry(
            region: region, admission: admission, manifestBytes: encoded.count, segments: layout.segments,
            createdAt: pool.now)
        guard admission.commit(key: .init(namespace: namespace, tag: donation.tag), entry: entry) else { return }
        // A close that raced the commit has already released the namespace.
        if isClosed { pool.releaseAll(namespace: namespace, reason: .unload) }
    }

    private static func layout(manifest: CBv2CompleteCheckpointManifest, manifestBytes: Int)
        -> (bytes: Int, segments: [MemoryOnlyCheckpointPool.Segment])?
    {
        func aligned(_ offset: Int) -> Int {
            (offset + segmentAlignment - 1) / segmentAlignment * segmentAlignment
        }
        var segments: [MemoryOnlyCheckpointPool.Segment] = []
        var end = manifestBytes
        for (index, tensor) in manifest.tensors.enumerated() {
            var offset = 0
            while offset < tensor.byteCount {
                let count = min(CBv2CompleteCheckpointManifest.maximumSegmentBytes, tensor.byteCount - offset)
                let start = aligned(end)
                segments.append(.init(tensor: index, offset: offset, regionOffset: start, bytes: count))
                let (next, overflow) = start.addingReportingOverflow(count)
                guard !overflow else { return nil }
                end = next
                offset += count
            }
        }
        return (end, segments)
    }

    // MARK: - Restore

    /// Stages the deepest held checkpoint of `request`'s prompt for the
    /// engine's `takeStaged`, charging its destination like an SSD stage.
    func stage(
        requestID: CBv2RequestID, request: CBv2Request,
        reserveReadScratch: @Sendable () throws -> CBv2CompleteCheckpointIOLease,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> CBv2CompleteCheckpointImportPlan
    ) async -> SSDPrefixCacheStageResult {
        let started = ContinuousClock.now
        func result(_ disposition: SSDPrefixCacheStageDisposition, deviceBytes: Int = 0) -> SSDPrefixCacheStageResult {
            let elapsed = started.duration(to: .now).components
            return .init(
                disposition: disposition,
                stageMs: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15,
                deviceBytes: deviceBytes, tier: .memory)
        }
        guard MemoryOnlyReceipt.contains(requestID) else {
            pool.recordUnmarkedRefusal()
            return result(.skippedPolicy)
        }
        guard !Task.isCancelled, !isClosed, request.prefixCacheEnabled,
            request.multimodal == nil, request.positionState == nil
        else {
            pool.recordLookup(.skipped)
            return result(.skippedPolicy)
        }
        let scope = request.checkpointCacheSalt ?? ""
        let blockSize = PrefixCachePolicy.blockSize
        let tags = hashes(tokens: request.promptTokens, scope: scope).enumerated().reversed()
            .filter { ($0.offset + 1) * blockSize >= config.minEffectiveTokens }
            .map { lookupKeys.checkpointTag(chainHash: $0.element, cacheSalt: scope) }
        guard let (tag, entry) = pool.lookup(namespace: namespace, tags: tags) else {
            pool.recordLookup(.miss)
            return result(.missAbsent)
        }
        // `closeAndWait` joins a restore still filling an engine import.
        let joined = lock.withLock { () -> Bool in
            guard !closed else { return false }
            activity.begin()
            return true
        }
        guard joined else {
            pool.recordLookup(.skipped)
            return result(.skippedPolicy)
        }
        defer { activity.end() }
        do {
            let (position, deviceBytes) = try await restore(
                entry, requestID: requestID, request: request,
                reserveReadScratch: reserveReadScratch, makeImportPlan: makeImportPlan)
            pool.touch(namespace: namespace, tag: tag)
            pool.recordLookup(.hit, hitTokens: position)
            return result(
                .staged(matchedTokens: position, expectedPrefillTokensSaved: position, shortenedByCorruption: false),
                deviceBytes: deviceBytes)
        } catch RestoreFailure.capacity {
            pool.recordLookup(.skipped)
            return result(.skippedCapacity)
        } catch RestoreFailure.incompatible {
            pool.remove(namespace: namespace, tag: tag)
            pool.recordLookup(.miss)
            return result(.missAbsent)
        } catch is LockedHostRegion.Released {
            pool.recordLookup(.miss)
            return result(.missAbsent)
        } catch {
            pool.recordLookup(.skipped)
            return result(.skippedPolicy)
        }
    }

    private enum RestoreFailure: Error { case capacity, incompatible, policy }

    private func restore(
        _ entry: MemoryOnlyCheckpointPool.Entry, requestID: CBv2RequestID, request: CBv2Request,
        reserveReadScratch: @Sendable () throws -> CBv2CompleteCheckpointIOLease,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> CBv2CompleteCheckpointImportPlan
    ) async throws -> (position: Int, deviceBytes: Int) {
        // The read scratch covers the manifest's decode, as it does a file's.
        var readScratch: CBv2CompleteCheckpointIOLease
        do { readScratch = try reserveReadScratch() }
        catch is CancellationError { throw RestoreFailure.policy }
        catch { throw RestoreFailure.capacity }
        defer { readScratch.close() }
        guard !readScratch.usesProcessMemoryOwner || kvBudget != nil else { throw RestoreFailure.capacity }
        let manifest: CBv2CompleteCheckpointManifest
        do {
            manifest = try entry.region.withBytes(at: 0, count: entry.manifestBytes) {
                try JSONDecoder().decode(CBv2CompleteCheckpointManifest.self, from: $0)
            }
        } catch let released as LockedHostRegion.Released { throw released }
        catch { throw RestoreFailure.incompatible }
        guard (try? manifest.validateStructure()) != nil,
            manifest.identity == config.identity, manifest.backendLayout == config.backendLayout,
            manifest.cacheSalt == request.checkpointCacheSalt, manifest.position < request.promptTokens.count,
            request.promptTokens.starts(with: manifest.prefixTokens)
        else { throw RestoreFailure.incompatible }
        let plan: CBv2CompleteCheckpointImportPlan
        do { plan = try makeImportPlan(manifest) }
        catch CBv2KVError.capacityExhausted { throw RestoreFailure.capacity }
        catch CBv2CompleteCheckpointError.allocationFailed { throw RestoreFailure.capacity }
        catch { throw RestoreFailure.policy }
        // The engine's process owner charges a native destination itself;
        // otherwise the destination and import scratch are reserved first.
        let ownerCharged = plan.usesProcessMemoryOwner
        guard !ownerCharged || kvBudget != nil else { throw RestoreFailure.capacity }
        var lease: SSDCheckpointStageReservation?
        if !ownerCharged {
            let key = "memory-only-complete:\(namespace):\(UUID().uuidString)"
            let (peak, overflow) = plan.nativeDestinationBytes.addingReportingOverflow(plan.scratchBytes)
            guard !overflow else { throw RestoreFailure.capacity }
            if let kvBudget, !(await kvBudget.reserveBytes(requestID: key, bytes: UInt64(max(1, peak)))) {
                throw RestoreFailure.capacity
            }
            lease = SSDCheckpointStageReservation(
                key: key, bytes: peak, budget: kvBudget, activity: activity, stats: leaseStats, holdsIO: true)
        }
        var installed = false
        defer {
            lease?.finishIO()
            if !installed { lease?.release() }
        }
        var importer: CBv2CompleteCheckpointImport?
        defer { importer?.close() }
        do { importer = try plan.allocate(onRelease: { [lease] in lease?.release() }) }
        catch { throw RestoreFailure.capacity }
        readScratch.close()
        for segment in entry.segments {
            guard !Task.isCancelled, !isClosed else { throw RestoreFailure.policy }
            try entry.region.withBytes(at: segment.regionOffset, count: segment.bytes) {
                try importer!.appendSegment(tensorIndex: segment.tensor, byteOffset: segment.offset, data: $0)
            }
        }
        let staged = try importer!.finish()
        importer = nil
        lease?.finishIO()
        if let lease, !(await lease.resize(to: staged.nativeDestinationBytes)) {
            staged.close()
            throw RestoreFailure.capacity
        }
        let accepted = lock.withLock {
            guard !Task.isCancelled, !closed, stages[requestID] == nil else { return false }
            stages[requestID] = .autoregressive(staged)
            if let lease { stageLeases[requestID] = lease }
            return true
        }
        guard accepted else {
            staged.close()
            throw RestoreFailure.policy
        }
        installed = true
        return (manifest.position, staged.nativeDestinationBytes)
    }

    /// The engine's consumption of a stage, with the SSD tier's checks.
    func takeStaged(
        requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int
    ) -> CBv2StagedCompleteCheckpoint? {
        let staged = lock.withLock {
            stageLeases.removeValue(forKey: requestID)
            return stages.removeValue(forKey: requestID)
        }
        guard let staged else { return nil }
        guard !isClosed, case .autoregressive(let value) = staged,
            value.manifest.identity == config.identity, value.manifest.cacheSalt == cacheSalt,
            value.maximumSequenceLength == maximumSequenceLength,
            value.manifest.position < tokens.count, tokens.starts(with: value.manifest.prefixTokens)
        else {
            staged.close()
            return nil
        }
        return value
    }

    /// Terminal or cold retry: an unconsumed stage is released.
    func completeStaging(requestID: CBv2RequestID) {
        lock.withLock {
            stageLeases.removeValue(forKey: requestID)
            return stages.removeValue(forKey: requestID)
        }?.close()
    }

    func abandonStaging(requestID: CBv2RequestID) async {
        let (stage, lease) = lock.withLock {
            (stages.removeValue(forKey: requestID), stageLeases.removeValue(forKey: requestID))
        }
        stage?.close()
        await lease?.waitForRefund()
    }

    // MARK: - Lifetime

    /// Model unload or slot teardown: every entry of this slot is released.
    func close() {
        let retiring = lock.withLock { () -> [SSDCheckpointStage]? in
            guard !closed else { return nil }
            closed = true
            defer { stages.removeAll(); stageLeases.removeAll() }
            return Array(stages.values)
        }
        guard let retiring else { return }
        donations.shutdown()
        retiring.forEach { $0.close() }
        pool.releaseAll(namespace: namespace, reason: .unload)
    }

    func closeAndWait() async {
        close()
        await donations.waitUntilDrained()
        await activity.waitUntilDrained()
    }

    private func hashes(tokens: [Int], scope: String, maximumBlocks: Int? = nil) -> [Data] {
        let hasher = CBv2BlockHasher(
            blockSize: PrefixCachePolicy.blockSize, promptContractID: config.identity.promptContractID,
            scopeID: scope)
        let maximum = hasher.maxLookupBlocks(tokenCount: tokens.count)
        let bounded = maximumBlocks.map { min(maximum, max(0, $0)) } ?? maximum
        return hasher.chainHashes(tokens: tokens, maxBlocks: bounded)
    }
}
