import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore: SSDEvictableStore, DurablePrefixCacheEvidenceSource {
    var evictionRoot: URL { config.root }
    var ownsEvictionRoot: Bool {
        lock.withLock { !closed }
            && (config.epochStore == nil || config.epochStore?.current != nil)
    }
    var diskBytesOnDisk: Int { index.totalBytes }
    var queuedWriteBytes: Int {
        lock.withLock {
            provenWriteBytes.values.reduce(0) {
                let (sum, overflow) = $0.addingReportingOverflow($1)
                return overflow ? Int.max : sum
            }
        }
    }
    func oldestEntryAccess() -> Int64? { index.oldest()?.lastAccess }

    func evictOldestEntry() -> Int {
        for entry in index.oldestEntries() {
            let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: entry.tag16.hexString)
            let freed = retireIndexedEntries([url]).indexedBytesFreed
            if freed > 0 {
                statsBox.update { $0.evictions += 1 }
                return freed
            }
        }
        return 0
    }

    func retireOwnedEntries(_ urls: [URL]) -> Set<String> {
        retireIndexedEntries(urls).removed
    }

    private func retireIndexedEntries(_ urls: [URL]) -> SSDOwnedEntryRetirement.Result {
        let result: SSDOwnedEntryRetirement.Result? = removalLock.withLock {
            guard hasSafeRoot, ownsEvictionRoot else { return nil }
            return SSDOwnedEntryRetirement.remove(
                urls: urls, root: config.root, index: index, epochStore: config.epochStore)
        }
        guard let result else { return .init() }
        if result.externalChange { reconcileExternalRemovals() }
        return result
    }

    func reconcileExternalRemovals() {
        let removed = index.allTags().filter {
            let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: $0.hexString)
            return SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) != .regular
        }
        guard !removed.isEmpty else { return }
        performIndexReconciliation { removed.forEach { _ = self.index.remove(tag16: $0) } }
    }

    /// Forget one entry whose file a reader found already gone. Index-only,
    /// and rechecked under the removal lock so a checkpoint rewritten at the
    /// same tag since the failed read keeps its entry.
    func forgetMissing(_ tag: Data) {
        performIndexReconciliation {
            let url = SSDBlockStore.fileURL(root: self.config.root, tag16Hex: tag.hexString)
            guard SSDBlockStore.indexedBlockFileStatus(at: url, under: self.config.root) != .regular
            else { return }
            _ = self.index.remove(tag16: tag)
        }
    }

    func performExternalDestructiveChange(_ body: () -> Void) -> Bool {
        // Whole-root callers do not know this store's index. Reconcile before
        // the removal barrier lifts so a reader queued on a removed file sees
        // its index entry gone at the post-acquire recheck.
        let completed: Void? = performIndexedRemoval {
            body()
            self.dropIndexEntriesWithoutFiles()
        }
        return completed != nil
    }

    /// Per-file removal: unlink plus index/accounting update, serialized
    /// with other removals. The cache epoch is untouched and the capability
    /// stays advertised. Every other checkpoint remains reusable and the
    /// coordinator forgets the removed one through an ordinary lookup miss
    /// (`miss_invalidation`); a stale holder costs one cold serve, never a
    /// fence.
    ///
    /// Refused once closed, or once a different-binding successor has taken
    /// the root (its rebuild publishes a new epoch, so `current` is nil
    /// here). A same-binding successor republishes the same epoch, so an
    /// instance it supersedes is stopped only by `close()`. The check is
    /// also not atomic with a successor's rebuild, which runs under the epoch
    /// store's record lock rather than this one: a body that already passed
    /// can unlink during that wipe, which the wipe tolerates
    /// (`SSDCacheEpochStore.removeStaleBlock`).
    private func performIndexedRemoval<T>(_ body: () -> T) -> T? {
        removalLock.withLock {
            guard ownsEvictionRoot else { return nil }
            return body()
        }
    }

    /// Index-only reconciliation touches no files, so it runs even after
    /// this store lost its epoch: a disowned but still registered store must
    /// stop reporting bytes that a successor's wipe already removed, or the
    /// box-wide budget over-evicts healthy stores until it closes.
    private func performIndexReconciliation(_ body: () -> Void) {
        removalLock.withLock(body)
    }

    private func dropIndexEntriesWithoutFiles() {
        for tag in index.allTags() {
            let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: tag.hexString)
            if SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) != .regular {
                _ = index.remove(tag16: tag)
            }
        }
    }

    func removeCorrupt(_ tag: Data) {
        _ = performIndexedRemoval {
            let url = SSDBlockStore.fileURL(root: self.config.root, tag16Hex: tag.hexString)
            _ = SSDBlockStore.removeItemIfSafe(at: url, under: self.config.root)
            _ = self.index.remove(tag16: tag)
        }
        statsBox.update { $0.corruptDropped += 1 }
    }

    func scanOnDisk() {
        guard hasSafeRoot else { return }
        SSDBlockStore.sweepStaleTempFiles(under: config.root)
        let manager = FileManager.default
        guard let fanouts = try? manager.contentsOfDirectory(
            at: config.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return }
        let now = config.nowSeconds()
        for fanout in fanouts where SSDBlockStore.isLowerHex(fanout.lastPathComponent, count: 2) {
            guard SSDBlockStore.isRealDirectory(fanout), SSDBlockStore.pathResolvesToItself(fanout),
                let files = try? manager.contentsOfDirectory(
                    at: fanout, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles])
            else { index.removeAll(); return }
            for file in files where file.pathExtension == SSDBlockStore.fileExtension {
                if isClosed { return }
                // Scan inserts must obey the same file/index commit boundary.
                guard let access = fileCoordinator.tryAcquire(to: file) else { continue }
                defer { access.release() }
                guard SSDBlockStore.isSafeBlockURL(file, modelRoot: config.root),
                    let tag = SSDPrefixCache.hexDecode(file.deletingPathExtension().lastPathComponent)
                else { index.removeAll(); return }
                guard let metadata = try? SSDBlockStore.readMetadataOnly(
                    from: file, maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60),
                    metadata.weightHash == identity.modelAggregateHash,
                    metadata.layoutEpoch == SSDHybridCheckpointEnvelope.layoutEpoch(
                        identity: identity, backendLayout: config.backendLayout),
                    metadata.blockSize == PrefixCachePolicy.blockSize,
                    metadata.lookupTag.hasPrefix(tag.hexString),
                    let attributes = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                    let size = attributes.fileSize, let date = attributes.contentModificationDate,
                    now - Int64(date.timeIntervalSince1970) < config.ttlSeconds
                else { removeCorrupt(tag); continue }
                index.insert(tag16: tag, fileBytes: size, lastAccess: Int64(date.timeIntervalSince1970))
            }
        }
        lock.withLock { if !closed { scanReady = true } }
    }

    func prefixCacheV2Capability() -> PrefixCacheV2Capability? {
        lock.withLock { capabilityLocked() }
    }

    private func capabilityLocked() -> PrefixCacheV2Capability? {
        guard !closed, scanReady, let epoch = config.epochStore?.current else { return nil }
        return PrefixCacheV2Capability(
            modelId: config.modelId, modelAggregateHash: identity.modelAggregateHash,
            promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: UInt32(PrefixCachePolicy.blockSize), cacheEpoch: epoch, enabled: true, ready: true,
            readyBoundaryMode: PrefixCacheV2Capability.checkpointBoundaryMode)
    }

    func prefixCacheAdvertisement(base: PrefixCacheModelStatus)
        -> (capability: PrefixCacheV2Capability?, status: PrefixCacheModelStatus) {
        lock.withLock {
            let ready = !closed && scanReady
                && (config.epochStore == nil || config.epochStore?.current != nil)
            return (capabilityLocked(), PrefixCacheModelStatus(
                modelId: base.modelId, backend: base.backend, replayStrategy: base.replayStrategy,
                state: closed ? .error : (ready ? .ready : .pending),
                reason: closed ? .cacheInitFailed : (ready ? .ready : .scanPending)))
        }
    }

    func takeNextPrefixCacheV2Sequence(expectedEpoch: String) -> UInt64? {
        lock.withLock {
            guard !closed else { return nil }
            return config.epochStore?.takeNextSequence(expectedEpoch: expectedEpoch)
        }
    }

    func registerReadyReceipt(
        requestID: CBv2RequestID, promptTokens: [Int], cacheScope: String,
        callback: @escaping @Sendable (PrefixCacheReadyResult) -> Void
    ) {
        let chain = hashes(tokens: promptTokens, scope: cacheScope)
        let tags = chain.map { lookupKeys.checkpointTag(chainHash: $0, cacheSalt: cacheScope) }
        let proof = ReadyReceipt(hashes: chain, tags: tags, epoch: config.epochStore?.current, callback: callback)
        lock.withLock { if !closed { readyReceipts[requestID] = proof } }
    }

    func discardReadyReceipt(requestID: CBv2RequestID) {
        lock.withLock {
            readyReceipts.removeValue(forKey: requestID)
            authenticatedReceipts.removeValue(forKey: requestID)
        }
    }

    func markReadyReceiptTerminal(requestID: CBv2RequestID) {
        // Complete-checkpoint publication finishes before the engine terminal.
        discardReadyReceipt(requestID: requestID)
    }

    /// Called by the engine's handler after durable commit AND donor release.
    func publishReady(requestID: CBv2RequestID, positions: [Int]) {
        let delivery = lock.withLock { () -> (ReadyReceipt, PrefixCacheReadyResult)? in
            guard !closed, let proof = readyReceipts[requestID],
                epochMatches(proof.epoch) else { return nil }
            var anchors = proof.anchors
            var maximumFileBytes = 0
            for position in positions where position > 0 && position % PrefixCachePolicy.blockSize == 0 {
                let offset = position / PrefixCachePolicy.blockSize - 1
                guard proof.hashes.indices.contains(offset) else { continue }
                let tag = Data(proof.tags[offset].prefix(16))
                let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: tag.hexString)
                guard SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) == .regular,
                    let size = index.fileBytes(tags16: [tag][...])?.first
                else { continue }
                maximumFileBytes = max(maximumFileBytes, size)
                let anchor = PrefixCacheAnchor(chainHash: proof.hashes[offset].hexString, tokenCount: UInt64(position))
                if !anchors.contains(anchor) { anchors.append(anchor) }
            }
            guard anchors != proof.anchors, let latest = anchors.max(by: { $0.tokenCount < $1.tokenCount }) else { return nil }
            proof.anchors = anchors.sorted { $0.tokenCount < $1.tokenCount }
            return (proof, PrefixCacheReadyResult(
                readyTokens: Int(latest.tokenCount), requiredRecomputeTokens: 0,
                expectedPrefillTokensSaved: Int(latest.tokenCount), tier: .ssd,
                stageMs: SSDPrefixCachePolicy.estimatedStageMillisDouble(bytes: maximumFileBytes),
                finalAnchor: latest, readyAnchors: proof.anchors))
        }
        if let delivery { delivery.0.callback(delivery.1) }
    }
}
