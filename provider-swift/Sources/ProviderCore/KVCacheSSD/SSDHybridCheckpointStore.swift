// Copyright © 2026 Eigen Labs.

import CryptoKit
import Foundation
import MLXLMCommon

/// Durable complete checkpoints. Idle state is an opaque index; imported
/// tensors exist only while a matching request owns a charged stage ticket.
public final class SSDHybridCheckpointStore: CBv2CompletePrefixCache, @unchecked Sendable {
    struct Config: Sendable {
        let modelId: String
        let identity: CBv2CompleteCheckpointIdentity
        var backendLayout = CBv2CompleteCheckpointManifest.layout
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
    }

    public let identity: CBv2CompleteCheckpointIdentity
    let usesEphemeralKey: Bool
    let config: Config
    let kekKey: SymmetricKey
    let lookupKeys: SSDLookupKeys
    let kvBudget: GlobalKVCacheBudget?
    let diskBudget: SSDDiskBudget
    let rateLimiter: SSDWriteRateLimiter
    let donationRecorder: any PrefixCacheDonationRecording
    let index = SSDBlockIndex()
    let lock = NSLock()
    let statsBox = SSDHybridCheckpointStatsBox()
    let activity = SSDCheckpointActivity()
    let fileCoordinator = SSDCheckpointFileCoordinator.shared
    let namespace = UUID().uuidString
    var closed = false
    var scanReady = false
    var destructiveChange = false
    var stages: [CBv2RequestID: CBv2StagedCompleteCheckpoint] = [:]
    var stageReservations: [CBv2RequestID: SSDCheckpointStageReservation] = [:]
    var reading: [CBv2RequestID: SSDCheckpointFileCoordinator.Access] = [:]
    var writing: Set<Data> = []
    var readyReceipts: [CBv2RequestID: ReadyReceipt] = [:]
    var authenticatedReceipts: [CBv2RequestID: (epoch: String?, files: [Data: SSDAuthenticatedFileIdentity])] = [:]
    var pipeline: BoundedSingleConsumerPipeline<WriteJob>!

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
         donationRecorder: any PrefixCacheDonationRecording = PrefixCacheDonationTelemetry.shared) {
        self.config = config
        self.identity = config.identity
        self.usesEphemeralKey = usesEphemeralKey
        self.kekKey = kekKey
        self.lookupKeys = SSDLookupKeys(kek: kekKey)
        self.kvBudget = kvBudget
        self.diskBudget = diskBudget
        self.donationRecorder = donationRecorder
        self.rateLimiter = SSDWriteRateLimiter(capBytesPerDay: maxWriteBytesPerDay)
        self.pipeline = BoundedSingleConsumerPipeline(
            capacity: 1,
            onDropped: { [weak self] job in self?.settle(job, positions: []) ?? job.finish([]) },
            consume: { [weak self] job in self?.write(job) ?? job.finish([]) })
        diskBudget.register(self)
    }

    public func takeStaged(
        requestID: CBv2RequestID, tokens: [Int], cacheSalt: String?, maximumSequenceLength: Int
    ) -> CBv2StagedCompleteCheckpoint? {
        let staged = lock.withLock {
            stageReservations.removeValue(forKey: requestID)
            return stages.removeValue(forKey: requestID)
        }
        guard let staged else { return nil }
        guard !isClosed, staged.manifest.identity == identity,
            staged.manifest.cacheSalt == cacheSalt,
            staged.maximumSequenceLength == maximumSequenceLength,
            staged.manifest.position < tokens.count,
            tokens.starts(with: staged.manifest.prefixTokens)
        else { staged.close(); return nil }
        statsBox.update { $0.stageConsumptions += 1; $0.consumedPrefixTokens += staged.manifest.position }
        return staged
    }

    public func acceptsCheckpoint(position: Int, packedBytes: Int) -> Bool {
        guard !isClosed, position >= config.minEffectiveTokens,
            position.isMultiple(of: PrefixCachePolicy.blockSize), packedBytes > 0
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
        access?.cancel()
        staged?.close()
    }

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
        let retiring = lock.withLock { () -> (stages: [CBv2StagedCompleteCheckpoint], reads: [SSDCheckpointFileCoordinator.Access])? in
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
        for access in retiring.reads { access.cancel() }
        pipeline.shutdown()
        for stage in retiring.stages { stage.close() }
        diskBudget.deregister(self)
    }

    func closeAndWait() async {
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
        return hasher.chainHashes(tokens: tokens, maxBlocks: hasher.maxLookupBlocks(tokenCount: tokens.count))
    }
}
