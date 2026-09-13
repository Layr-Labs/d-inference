import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore: SSDEvictableStore, DurablePrefixCacheEvidenceSource {
    var evictionRoot: URL { config.root }
    var diskBytesOnDisk: Int { index.totalBytes }
    func oldestEntryAccess() -> Int64? { index.oldest()?.lastAccess }

    func evictOldestEntry() -> Int {
        for entry in index.oldestEntries() {
            var freed = 0
            _ = performExternalDestructiveChange {
                let url = SSDBlockStore.fileURL(root: self.config.root, tag16Hex: entry.tag16.hexString)
                if SSDBlockStore.removeItemIfSafe(at: url, under: self.config.root)
                    || SSDBlockStore.indexedBlockFileStatus(at: url, under: self.config.root) == .missing {
                    freed = self.index.remove(tag16: entry.tag16)
                }
            }
            if freed > 0 {
                statsBox.update { $0.evictions += 1 }
                return freed
            }
        }
        return 0
    }

    func reconcileExternalRemovals() {
        let removed = index.allTags().filter {
            let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: $0.hexString)
            return SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) != .regular
        }
        guard !removed.isEmpty else { return }
        _ = performExternalDestructiveChange { removed.forEach { _ = self.index.remove(tag16: $0) } }
    }

    func performExternalDestructiveChange(_ body: () -> Void) -> Bool {
        let accepted = lock.withLock {
            guard !closed, !destructiveChange else { return false }
            destructiveChange = true
            return true
        }
        guard accepted else { return false }
        defer { lock.withLock { destructiveChange = false } }
        if let epochStore = config.epochStore {
            return epochStore.performOwnedDestructiveChange(body) != nil
        }
        body()
        return true
    }

    func removeCorrupt(_ tag: Data) {
        _ = performExternalDestructiveChange {
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
        guard !closed, scanReady, !destructiveChange, let epoch = config.epochStore?.current else { return nil }
        return PrefixCacheV2Capability(
            modelId: config.modelId, modelAggregateHash: identity.modelAggregateHash,
            promptContractId: identity.promptContractID, blockHashVersion: CBv2BlockHasher.version,
            blockSize: UInt32(PrefixCachePolicy.blockSize), cacheEpoch: epoch, enabled: true, ready: true,
            readyBoundaryMode: PrefixCacheV2Capability.checkpointBoundaryMode)
    }

    func prefixCacheAdvertisement(base: PrefixCacheModelStatus)
        -> (capability: PrefixCacheV2Capability?, status: PrefixCacheModelStatus) {
        lock.withLock {
            let ready = !closed && scanReady && !destructiveChange
                && (config.epochStore == nil || config.epochStore?.current != nil)
            return (capabilityLocked(), PrefixCacheModelStatus(
                modelId: base.modelId, backend: base.backend, replayStrategy: base.replayStrategy,
                state: closed ? .error : (ready ? .ready : .pending),
                reason: closed ? .cacheInitFailed : (ready ? .ready : .scanPending)))
        }
    }

    func takeNextPrefixCacheV2Sequence(expectedEpoch: String) -> UInt64? {
        lock.withLock {
            guard !closed, !destructiveChange else { return nil }
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
            guard !closed, !destructiveChange, let proof = readyReceipts[requestID],
                epochMatches(proof.epoch) else { return nil }
            var anchors = proof.anchors
            var maximumFileBytes = 0
            for position in positions where position > 0 && position % PrefixCachePolicy.blockSize == 0 {
                let offset = position / PrefixCachePolicy.blockSize - 1
                guard proof.hashes.indices.contains(offset),
                    let size = index.fileBytes(tags16: [Data(proof.tags[offset].prefix(16))][...])?.first
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
