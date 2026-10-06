// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLMCommon

/// Durable complete checkpoints. Idle state is an opaque index; imported
/// tensors exist only while a matching request owns a charged stage ticket.
public final class SSDHybridCheckpointStore: CBv2NativeCompletePrefixCache, CBv2NativeBlockPrefixCache, @unchecked Sendable {
    struct Config: Sendable {
        let modelId: String
        let identity: CBv2CompleteCheckpointIdentity
        var backendLayout = CBv2CompleteCheckpointManifest.layout
        var nativePrefillChunkSize: Int? = nil
        let root: URL
        let dedicatedRoot: URL
        let epochStore: SSDCacheEpochStore?
        let maxReadBytes: Int
        let maxStageMillis: Int
        let minEffectiveTokens: Int
        let ttlSeconds: Int64
        let strictFsync: Bool
        let nowSeconds: @Sendable () -> Int64
        let diskBudgetBytes: @Sendable () -> Int
        let maintainWholeRoot: @Sendable () -> Void
        // Monotonic, stage-local deadline clock. Default preserves first-attempt
        // timing; injected clocks keep retry boundary tests deterministic.
        var stageNow: @Sendable () -> ContinuousClock.Instant = { .now }
        /// How `diskBudgetBytes` moves as bytes land, for speculative
        /// admission. nil means the budget does not move with writes.
        var diskBudgetBasis: (@Sendable () -> SSDDiskBudgetBasis)? = nil
    }

    public let identity: CBv2CompleteCheckpointIdentity
    let usesEphemeralKey: Bool
    let config: Config
    let kekKey: SymmetricKey
    let lookupKeys: SSDLookupKeys
    let kvBudget: GlobalKVCacheBudget?
    let diskBudget: SSDDiskBudget
    /// This store's keys on the disk budget's ledger, resolved once.
    let modelRootKey: String
    let wholeRootKey: String
    let rateLimiter: SSDWriteRateLimiter
    let writeDemand: SSDCheckpointDemand
    /// Coordinator demand hints for in-flight receipts; see
    /// `SSDHybridCheckpointStore+DemandAdmission.swift`.
    let donationDemandHints = SSDCheckpointDemandHints()
    let donationRecorder: any PrefixCacheDonationRecording
    let index = SSDBlockIndex()
    let lock = NSLock()
    /// Serializes per-file removals (budget eviction, TTL expiry, corrupt
    /// drops, external reconciliation) with each other. Never held while
    /// taking `lock` for anything but a state read; bodies do unlink + index
    /// work only, so it nests safely inside `SSDDiskBudget`'s lock.
    let removalLock = NSLock()
    #if DEBUG
    /// Test-only: runs after a fresh checkpoint file is published and before
    /// it is indexed, to reproduce a maintenance removal in that window.
    var afterPublishBeforeIndexForTesting: (@Sendable () -> Void)?
    /// Test-only: runs once a fresh write holds its disk-budget claim and
    /// before its first byte, to reproduce another writer arriving, or the
    /// budget moving, while the write is in flight. The argument is the
    /// file the write will publish.
    var afterDiskClaimForTesting: (@Sendable (URL) -> Void)?
    /// Test-only: runs in a speculative write before each chunk is handed to
    /// the writer, after the revocation check, with the chunk's index.
    var beforeSpeculativeChunkForTesting: (@Sendable (Int) -> Void)?
    #endif
    let statsBox = SSDHybridCheckpointStatsBox()
    let activity = SSDCheckpointActivity()
    let fileCoordinator = SSDCheckpointFileCoordinator.shared
    let namespace = UUID().uuidString
    var closed = false
    var scanReady = false
    var stages: [CBv2RequestID: SSDCheckpointStage] = [:]
    var stageReservations: [CBv2RequestID: SSDCheckpointStageReservation] = [:]
    var reading: [CBv2RequestID: SSDCheckpointFileCoordinator.Access] = [:]
    var writing: Set<Data> = []
    /// Stored-size bounds of proven jobs that were accepted here and have
    /// not yet recorded their bytes on the disk budget's ledger, by tag. A
    /// speculative write anywhere on the budget must leave them room
    /// (`queuedWriteBytes`).
    var provenWriteBytes: [Data: Int] = [:]
    var readyReceipts: [CBv2RequestID: ReadyReceipt] = [:]
    var authenticatedReceipts: [CBv2RequestID: (epoch: String?, files: [Data: SSDAuthenticatedFileIdentity])] = [:]
    var pipeline: BoundedSingleConsumerPipeline<WriteJob>!

    // Pauses the real durable writer at the rename/duplicate-validation boundary.
    // Invoked outside store.lock, while the exact-file commit lease is held.
    var beforeWriteIndexForTesting: (@Sendable (URL, Bool) -> Void)?

    final class ReadyReceipt {
        let callback: @Sendable (PrefixCacheReadyResult) -> Void
        let hashes: [Data]
        let tags: [Data]
        let epoch: String?
        var anchors: [PrefixCacheAnchor] = []
        init(hashes: [Data], tags: [Data], epoch: String?,
             callback: @escaping @Sendable (PrefixCacheReadyResult) -> Void) {
            self.hashes = hashes
            self.tags = tags
            self.epoch = epoch
            self.callback = callback
        }
    }

    init(config: Config, kekKey: SymmetricKey, kvBudget: GlobalKVCacheBudget?,
         diskBudget: SSDDiskBudget = .shared, maxWriteBytesPerDay: Int, usesEphemeralKey: Bool = true,
         donationRecorder: any PrefixCacheDonationRecording = PrefixCacheDonationTelemetry.shared,
         writeNowSeconds: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) {
        self.config = config
        self.identity = config.identity
        self.usesEphemeralKey = usesEphemeralKey
        self.kekKey = kekKey
        self.lookupKeys = SSDLookupKeys(kek: kekKey)
        self.kvBudget = kvBudget
        self.diskBudget = diskBudget
        self.modelRootKey = SSDDiskBudget.rootKey(config.root)
        self.wholeRootKey = SSDDiskBudget.rootKey(config.dedicatedRoot)
        self.donationRecorder = donationRecorder
        // A speculative checkpoint is useful for at most one cache lifetime,
        // so speculation may hold back no more budget than the total refills
        // in that time (the novel share, at 90% of that rate, takes a ninth longer).
        self.rateLimiter = SSDWriteRateLimiter(capBytesPerDay: maxWriteBytesPerDay,
            repeatReserveFraction: SSDCheckpointDemand.repeatReserveFraction,
            speculativeHeadroomSeconds: Double(config.ttlSeconds), nowSeconds: writeNowSeconds)
        self.writeDemand = SSDCheckpointDemand(ttlSeconds: config.ttlSeconds)
        self.pipeline = BoundedSingleConsumerPipeline(
            capacity: 1,
            onDropped: { [weak self] job in self?.settle(job, positions: []) ?? job.finish([]) },
            consume: { [weak self] job in
                guard let self else { job.finish([]); return }
                await self.write(job)
            })
        diskBudget.register(self)
    }

    public func takeStaged(
        requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int
    ) -> CBv2StagedCompleteCheckpoint? {
        guard let staged = takeStage(requestID: requestID, tokens: tokens, cacheSalt: cacheSalt,
                                     maximumSequenceLength: maximumSequenceLength, native: false),
            case .autoregressive(let value) = staged else { return nil }
        return value
    }

    public func takeNativeStaged(
        requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int
    ) -> CBv2NativeBlockCheckpoint? {
        guard let staged = takeStage(requestID: requestID, tokens: tokens, cacheSalt: cacheSalt,
                                     maximumSequenceLength: maximumSequenceLength, native: true),
            case .nativeBlock(let value) = staged else { return nil }
        return value
    }

    private func takeStage(
        requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int, native: Bool
    ) -> SSDCheckpointStage? {
        let staged = lock.withLock {
            stageReservations.removeValue(forKey: requestID)
            return stages.removeValue(forKey: requestID)
        }
        guard let staged else { return nil }
        guard !isClosed, staged.isNative == native, staged.manifest.identity == identity,
            staged.manifest.cacheSalt == cacheSalt,
            staged.maximumSequenceLength == maximumSequenceLength,
            native ? staged.manifest.position <= tokens.count : staged.manifest.position < tokens.count,
            tokens.starts(with: staged.manifest.prefixTokens)
        else { staged.close(); return nil }
        statsBox.update { $0.stageConsumptions += 1; $0.consumedPrefixTokens += staged.manifest.position }
        return staged
    }

    /// Engine queue, once per request: a packed range disarmed a recurrent
    /// donor's capture. The position is a token offset only.
    public func recordRecurrentCaptureDisarmed(packedAt position: Int) {
        statsBox.update { $0.recurrentCaptureDisarmedPacked += 1 }
    }

    public func acceptsCheckpoint(position: Int, packedBytes: Int) -> Bool {
        guard !isClosed, position >= config.minEffectiveTokens,
            (config.backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout
                || position.isMultiple(of: PrefixCachePolicy.blockSize)), packedBytes > 0
        else { return false }
        // Reserve the manifest's full bound when deciding which capture to
        // retain. The actual writer applies exact encoded sizes afterward.
        let (payload, overflow) = packedBytes.addingReportingOverflow(CBv2CompleteCheckpointManifest.maximumEncodedBytes)
        guard !overflow, payload <= config.maxReadBytes else { return false }
        let (fileBytes, fileOverflow) = payload.addingReportingOverflow(1 << 20)
        return !fileOverflow && SSDPrefixCachePolicy.estimatedStageMillis(bytes: fileBytes) <= config.maxStageMillis
    }

    func completeStaging(requestID: CBv2RequestID) {
        let (staged, access) = lock.withLock {
            let access = reading.removeValue(forKey: requestID)
            authenticatedReceipts.removeValue(forKey: requestID)
            stageReservations.removeValue(forKey: requestID)
            return (stages.removeValue(forKey: requestID), access)
        }
        // The engine delivers the terminal after complete-checkpoint
        // publication, so the write gate has already consulted this hint.
        donationDemandHints.discard(requestID)
        access?.cancel()
        staged?.close()
    }

    /// Retires a staged read. The request itself continues: the bridge
    /// abandons staging and then retries the same receipt cold, and its
    /// completion still consults the demand hint, so the hint stays until
    /// `completeStaging` (terminal) or an explicit `discardDonationDemand`.
    func abandonStaging(requestID: CBv2RequestID) async {
        let (stage, reservation, access) = lock.withLock {
            let access = reading.removeValue(forKey: requestID)
            authenticatedReceipts.removeValue(forKey: requestID)
            return (stages.removeValue(forKey: requestID), stageReservations.removeValue(forKey: requestID), access)
        }
        access?.cancel()
        stage?.close()
        await reservation?.waitForRefund()
    }

    var isClosed: Bool { lock.withLock { closed } }
    var hasSafeRoot: Bool { SSDBlockStore.isSafeModelRoot(config.root, dedicatedRoot: config.dedicatedRoot) }

    public func close() {
        let retiring = lock.withLock { () -> (stages: [SSDCheckpointStage], reads: [SSDCheckpointFileCoordinator.Access])? in
            guard !closed else { return nil }
            closed = true
            let accesses = Array(reading.values)
            reading.removeAll()
            readyReceipts.removeAll()
            authenticatedReceipts.removeAll()
            let retiring = Array(stages.values)
            stages.removeAll()
            stageReservations.removeAll()
            return (retiring, accesses)
        }
        guard let retiring else { return }
        donationDemandHints.removeAll()
        for access in retiring.reads { access.cancel() }
        pipeline.shutdown()
        for stage in retiring.stages { stage.close() }
        diskBudget.deregister(self)
    }

    public func closeAndWait() async {
        close()
        await pipeline.waitUntilDrained()
        await activity.waitUntilDrained()
    }

    func waitForWritesForTesting() async { await pipeline.waitUntilDrained() }

    public func stats() -> SSDHybridCheckpointStats {
        var result = statsBox.snapshot()
        let usage = index.usageSnapshot()
        result.entries = usage.entries
        result.bytesOnDisk = usage.bytes
        return result
    }

    func hashes(tokens: [Int], scope: String) -> [Data] {
        let hasher = CBv2BlockHasher(blockSize: PrefixCachePolicy.blockSize,
                                    promptContractID: identity.promptContractID, scopeID: scope)
        let maximum = config.backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout
            ? tokens.count / PrefixCachePolicy.blockSize : hasher.maxLookupBlocks(tokenCount: tokens.count)
        return hasher.chainHashes(tokens: tokens, maxBlocks: maximum)
    }
}
