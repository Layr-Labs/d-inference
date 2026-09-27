import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    private enum ReadControl: Error { case manifestRead, retryableCapacity, capacity, policy }

    struct ReadAttemptResult {
        let disposition: SSDPrefixCacheStageDisposition
        let deviceBytes: Int
        let retryable: Bool

        init(_ disposition: SSDPrefixCacheStageDisposition, deviceBytes: Int = 0, retryable: Bool = false) {
            self.disposition = disposition
            self.deviceBytes = deviceBytes
            self.retryable = retryable
        }
    }

    // Only scalars escape a failed attempt. Manifest, plan and native import
    // aliases unwind here before stageTransfer retires and awaits host owners.
    func readAttempt(
        requestID: CBv2RequestID, request: CBv2Request, candidate: ReadCandidate,
        access: SSDCheckpointFileCoordinator.Access, epoch: String?,
        lease: SSDCheckpointStageReservation, readScratch: CBv2CompleteCheckpointIOLease,
        budget: SSDCheckpointReadBudget,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> SSDCheckpointImportPlan
    ) async -> ReadAttemptResult {
        let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: Data(candidate.tag.prefix(16)).hexString)
        let check: () throws -> Void = {
            guard self.readIsCurrent(requestID: requestID, access: access, epoch: epoch) else {
                throw CancellationError()
            }
            try budget.checkTime()
        }
        let countRead: (Int) -> Void = { count in
            self.statsBox.update { $0.bytesRead += count; $0.stageReadBytes += count }
        }
        let validate: (SSDBlockMetadata) throws -> Void = { metadata in
            guard metadata.lookupTag == candidate.tag.hexString,
                metadata.weightHash == self.identity.modelAggregateHash,
                metadata.layoutEpoch == SSDHybridCheckpointEnvelope.layoutEpoch(
                    identity: self.identity, backendLayout: self.config.backendLayout),
                metadata.blockSize == PrefixCachePolicy.blockSize,
                (metadata.chunkPlaintextSizes.first ?? Int.max) <= CBv2CompleteCheckpointManifest.maximumEncodedBytes
            else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        }
        do {
            try await access.acquire()
            try check()
            guard index.freshFileBytes(tag16: Data(candidate.tag.prefix(16)), now: config.nowSeconds(),
                                       ttlSeconds: config.ttlSeconds) != nil else {
                statsBox.update { $0.misses += 1 }
                return .init(.missAbsent)
            }
            let loaded = try await readCheckpoint(
                candidate: candidate, request: request, url: url, lease: lease,
                readScratch: readScratch, budget: budget, check: check, countRead: countRead,
                validate: validate, makeImportPlan: makeImportPlan)
            let staged = loaded.staged
            lease.finishIO()
            if loaded.usesProcessMemoryOwner {
                lease.release()
                await lease.waitForRefund()
            } else if !(await lease.resize(to: loaded.destinationBytes)) {
                staged.close()
                // This is after materialization, not the pre-allocation gate.
                return .init(.skippedCapacity)
            }
            do { try check() } catch { staged.close(); throw error }
            let installed = lock.withLock {
                guard !Task.isCancelled, !closed, !destructiveChange, reading[requestID] === access,
                    epochMatches(epoch) else { return false }
                stages[requestID] = staged
                if !loaded.usesProcessMemoryOwner { stageReservations[requestID] = lease }
                authenticatedReceipts[requestID] = (epoch, [Data(candidate.tag.prefix(16)): loaded.file])
                return true
            }
            guard installed else { staged.close(); return .init(.skippedPolicy) }
            index.touch(tags16: [Data(candidate.tag.prefix(16))], now: config.nowSeconds())
            statsBox.update { $0.stages += 1 }
            return .init(.staged(matchedTokens: candidate.position, expectedPrefillTokensSaved: candidate.position,
                                shortenedByCorruption: false), deviceBytes: loaded.destinationBytes)
        } catch ReadControl.retryableCapacity {
            return .init(.skippedCapacity, retryable: true)
        } catch ReadControl.capacity {
            return .init(.skippedCapacity)
        } catch is SSDCheckpointReadBudget.Exhausted {
            return .init(.skippedCapacity)
        } catch ReadControl.policy {
            return .init(.skippedPolicy)
        } catch is CancellationError {
            return .init(.skippedPolicy)
        } catch is SSDAuthenticatedFileChange {
            return .init(.skippedPolicy)
        } catch CBv2CompleteCheckpointError.allocationFailed {
            return .init(.skippedCapacity)
        } catch {
            removeCorrupt(Data(candidate.tag.prefix(16)))
            return .init(.missCorrupt)
        }
    }

    private struct LoadedCheckpoint {
        let staged: SSDCheckpointStage
        let file: SSDAuthenticatedFileIdentity
        let destinationBytes: Int
        let usesProcessMemoryOwner: Bool
    }

    private func readCheckpoint(
        candidate: ReadCandidate, request: CBv2Request, url: URL,
        lease: SSDCheckpointStageReservation, readScratch: CBv2CompleteCheckpointIOLease,
        budget: SSDCheckpointReadBudget, check: () throws -> Void, countRead: (Int) -> Void,
        validate: (SSDBlockMetadata) throws -> Void,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> SSDCheckpointImportPlan
    ) async throws -> LoadedCheckpoint {
        var importer: SSDCheckpointImport?
        defer { importer?.close() }
        var manifest: CBv2CompleteCheckpointManifest?
        statsBox.update { $0.filesRead += 1 }
        do {
            try SSDBlockStore.readStreaming(
                from: url, kekKey: kekKey,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: config.maxReadBytes,
                maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60,
                checkCancellation: check, beforeRead: budget.beforeRead, onBytesRead: countRead,
                validateMetadata: validate, consumeChunk: { index, data in
                    guard index == 0 else { throw CBv2CompleteCheckpointError.invalidManifest }
                    manifest = try SSDHybridCheckpointEnvelope.decodeManifest(data)
                    throw ReadControl.manifestRead
                })
        } catch ReadControl.manifestRead { }
        guard let manifest, manifest.position == candidate.position, manifest.identity == identity,
            manifest.backendLayout == config.backendLayout,
            manifest.cacheSalt == request.checkpointCacheSalt, request.promptTokens.starts(with: manifest.prefixTokens)
        else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        let envelope = try SSDHybridCheckpointEnvelope(manifest: manifest, maximumPlaintextBytes: config.maxReadBytes)
        let plan: SSDCheckpointImportPlan
        do { plan = try makeImportPlan(manifest) }
        catch CBv2KVError.capacityExhausted { throw ReadControl.retryableCapacity }
        catch CBv2CompleteCheckpointError.allocationFailed { throw ReadControl.capacity }
        catch { throw ReadControl.policy }
        let usesProcessMemoryOwner = plan.usesProcessMemoryOwner
        guard !usesProcessMemoryOwner || kvBudget != nil else { throw ReadControl.capacity }
        if !usesProcessMemoryOwner {
            let (destinationAndScratch, overflow1) = plan.nativeDestinationBytes.addingReportingOverflow(plan.scratchBytes)
            let (peak, overflow2) = destinationAndScratch.addingReportingOverflow(Self.ioScratchBytes)
            guard !overflow1, !overflow2 else { throw ReadControl.capacity }
            guard await lease.resize(to: peak) else {
                try check()
                throw ReadControl.retryableCapacity
            }
        }
        try check()
        do {
            importer = try plan.allocate(onRelease: {
                if !usesProcessMemoryOwner { lease.release() }
            })
        } catch CBv2KVError.capacityExhausted {
            // Pinned SDK 6f3d171: both AR and native-block plans throw this
            // typed refusal at Admission/native reservation BEFORE allocating.
            // MLX evaluation/materialization failures have different types and
            // must not inherit retry authority merely from an allocation error.
            throw ReadControl.retryableCapacity
        } catch { throw ReadControl.capacity }
        readScratch.close()
        guard let filling = importer else { throw CBv2CompleteCheckpointError.allocationFailed }
        SSDBlockStore.setAttributesIfSafe([.modificationDate: Date(timeIntervalSince1970: Double(config.nowSeconds()))],
                                        at: url, under: config.root)
        var authenticatedFile: SSDAuthenticatedFileIdentity?
        statsBox.update { $0.filesRead += 1 }
        try SSDBlockStore.readStreaming(
            from: url, kekKey: kekKey,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: config.maxReadBytes,
            maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60, requireEOF: true,
            checkCancellation: check, beforeRead: budget.beforeRead, onBytesRead: countRead,
            onAuthenticatedFile: { authenticatedFile = $0 },
            validateMetadata: { metadata in
                try validate(metadata)
                guard envelope.matches(metadata, tag: candidate.tag, identity: self.identity,
                                      backendLayout: self.config.backendLayout) else {
                    throw CBv2CompleteCheckpointError.incompatibleCheckpoint
                }
            }, consumeChunk: { index, data in
                if index == 0 {
                    guard data == envelope.manifestBytes else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
                } else {
                    let segment = envelope.segments[index - 1]
                    self.statsBox.update { $0.maximumSegmentBytes = max($0.maximumSegmentBytes, data.count) }
                    try filling.appendSegment(tensorIndex: segment.tensor, byteOffset: segment.offset, data: data)
                }
            })
        try check()
        guard let authenticatedFile, authenticatedFile.matches(url: url) else {
            throw SSDAuthenticatedFileChange.changedDuringRead
        }
        let staged = try filling.finish()
        importer = nil
        return LoadedCheckpoint(staged: staged, file: authenticatedFile,
            destinationBytes: staged.nativeDestinationBytes, usesProcessMemoryOwner: plan.usesProcessMemoryOwner)
    }
}
