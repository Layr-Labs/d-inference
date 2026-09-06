import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    // Up to four 4 MiB crypto buffers plus bounded manifest/JSON work. The
    // engine's import scratch and active destination are charged separately.
    static let ioScratchBytes = CBv2CompleteCheckpointManifest.maximumProviderScratchBytes

    private enum ReadControl: Error { case manifestRead, capacity, policy }
    private struct Candidate {
        let position: Int
        let tag: Data
        let fileBytes: Int
    }

    private func candidate(hashes: [Data], scope: String) -> Candidate? {
        guard !isClosed, index.count > 0 else { return nil }
        let now = config.nowSeconds()
        let (fileCap, overflow) = config.maxReadBytes.addingReportingOverflow(1 << 20)
        guard !overflow else { return nil }
        for offset in hashes.indices.reversed() {
            let position = (offset + 1) * PrefixCachePolicy.blockSize
            guard position >= config.minEffectiveTokens else { break }
            let tag = lookupKeys.checkpointTag(chainHash: hashes[offset], cacheSalt: scope)
            guard let size = index.freshFileBytes(
                tag16: Data(tag.prefix(16)), now: now, ttlSeconds: config.ttlSeconds),
                size <= fileCap,
                SSDPrefixCachePolicy.estimatedStageMillis(bytes: size) <= config.maxStageMillis
            else { continue }
            return Candidate(position: position, tag: tag, fileBytes: size)
        }
        return nil
    }

    func stage(
        requestID: CBv2RequestID, request: CBv2Request,
        reserveReadScratch: @Sendable () throws -> CBv2CompleteCheckpointIOLease,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> CBv2CompleteCheckpointImportPlan
    ) async -> SSDPrefixCacheStageResult {
        let started = ContinuousClock.now
        let scope = request.cacheSalt ?? ""
        let chain = hashes(tokens: request.promptTokens, scope: scope)
        func result(_ disposition: SSDPrefixCacheStageDisposition, deviceBytes: Int = 0) -> SSDPrefixCacheStageResult {
            let elapsed = Self.milliseconds(since: started)
            statsBox.update { $0.stageMilliseconds += elapsed }
            return .init(disposition: disposition, stageMs: elapsed, chainHashes: chain,
                         blockSize: PrefixCachePolicy.blockSize, deviceBytes: deviceBytes)
        }
        guard !Task.isCancelled, request.prefixCacheEnabled, request.multimodal == nil, request.positionState == nil else {
            return result(.skippedPolicy)
        }
        guard let candidate = candidate(hashes: chain, scope: scope), hasSafeRoot else {
            statsBox.update { $0.misses += 1 }
            return result(.missAbsent)
        }
        let readScratch: CBv2CompleteCheckpointIOLease
        do { readScratch = try reserveReadScratch() }
        catch is CancellationError { return result(.skippedPolicy) }
        catch { return result(.skippedCapacity) }
        defer { readScratch.close() }
        // A process-bound native lease deliberately charges no provider IO.
        // Refuse missing host authority before authenticating even the manifest.
        guard !readScratch.usesProcessMemoryOwner || kvBudget != nil else {
            return result(.skippedCapacity)
        }
        let generation = UUID()
        let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: Data(candidate.tag.prefix(16)).hexString)
        let access = fileCoordinator.makeAccess(to: url)
        let accepted = lock.withLock {
            guard !closed, !destructiveChange, reading[requestID] == nil, stages[requestID] == nil else { return false }
            reading[requestID] = access
            activity.begin()
            return true
        }
        guard accepted else { return result(.skippedPolicy) }
        defer {
            lock.withLock { if reading[requestID] === access { reading.removeValue(forKey: requestID) } }
            access.release()
            readScratch.close()
            activity.end()
        }
        let epoch = config.epochStore?.current
        let reservationKey = "ssd-complete:\(namespace):\(generation.uuidString)"
        if let kvBudget, !(await kvBudget.reserveBytes(requestID: reservationKey, bytes: UInt64(Self.ioScratchBytes))) {
            return result(.skippedCapacity)
        }
        let lease = SSDCheckpointStageReservation(key: reservationKey, bytes: Self.ioScratchBytes,
            budget: kvBudget, activity: activity, stats: statsBox, holdsIO: true)
        var transferred = false
        defer {
            lease.finishIO()
            if !transferred { lease.release() }
        }
        let check: () throws -> Void = {
            guard !Task.isCancelled, self.epochMatches(epoch), self.lock.withLock({
                !self.closed && !self.destructiveChange && self.reading[requestID] === access
            }) else { throw CancellationError() }
        }
        let countRead: (Int) -> Void = { count in self.statsBox.update { $0.bytesRead += count; $0.stageReadBytes += count } }
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
                return result(.missAbsent)
            }
            let loaded = try await readCheckpoint(
                candidate: candidate, request: request, url: url, lease: lease,
                readScratch: readScratch, check: check, countRead: countRead,
                validate: validate, makeImportPlan: makeImportPlan)
            let staged = loaded.staged
            lease.finishIO()
            if loaded.usesProcessMemoryOwner {
                lease.release()
                await lease.waitForRefund()
            } else if !(await lease.resize(to: loaded.destinationBytes)) {
                staged.close()
                return result(.skippedCapacity)
            }
            let installed = lock.withLock {
                guard !Task.isCancelled, !closed, !destructiveChange, reading[requestID] === access,
                    epochMatches(epoch) else { return false }
                stages[requestID] = staged
                if !loaded.usesProcessMemoryOwner { stageReservations[requestID] = lease }
                authenticatedReceipts[requestID] = (epoch, [Data(candidate.tag.prefix(16)): loaded.file])
                return true
            }
            guard installed else { staged.close(); return result(.skippedPolicy) }
            transferred = true
            index.touch(tags16: [Data(candidate.tag.prefix(16))], now: config.nowSeconds())
            statsBox.update { $0.stages += 1 }
            return result(.staged(matchedTokens: candidate.position, expectedPrefillTokensSaved: candidate.position,
                                  shortenedByCorruption: false), deviceBytes: loaded.destinationBytes)
        } catch ReadControl.capacity {
            return result(.skippedCapacity)
        } catch ReadControl.policy {
            return result(.skippedPolicy)
        } catch is CancellationError {
            return result(.skippedPolicy)
        } catch is SSDAuthenticatedFileChange {
            // Fail cold without deleting good ciphertext or rotating its epoch.
            return result(.skippedPolicy)
        } catch CBv2CompleteCheckpointError.allocationFailed {
            return result(.skippedCapacity)
        } catch {
            removeCorrupt(Data(candidate.tag.prefix(16)))
            return result(.missCorrupt)
        }
    }

    private struct LoadedCheckpoint {
        let staged: CBv2StagedCompleteCheckpoint
        let file: SSDAuthenticatedFileIdentity
        let destinationBytes: Int
        let usesProcessMemoryOwner: Bool
    }

    /// Contains every manifest/decrypt/segment buffer. Successful return and
    /// error unwind both drain these aliases before the caller releases host C.
    private func readCheckpoint(
        candidate: Candidate, request: CBv2Request, url: URL,
        lease: SSDCheckpointStageReservation, readScratch: CBv2CompleteCheckpointIOLease,
        check: () throws -> Void, countRead: (Int) -> Void,
        validate: (SSDBlockMetadata) throws -> Void,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> CBv2CompleteCheckpointImportPlan
    ) async throws -> LoadedCheckpoint {
        var importer: CBv2CompleteCheckpointImport?
        defer { importer?.close() }
        // Authenticate just the encrypted manifest before asking the engine
        // for an allocation-free import plan. Reopen and reauthenticate the
        // whole file after reserving the exact native destination.
        var manifest: CBv2CompleteCheckpointManifest?
        statsBox.update { $0.filesRead += 1 }
        do {
            try SSDBlockStore.readStreaming(
                from: url, kekKey: kekKey,
                maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                maximumPlaintextBytes: config.maxReadBytes,
                maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60,
                checkCancellation: check, onBytesRead: countRead,
                validateMetadata: validate, consumeChunk: { index, data in
                    guard index == 0 else { throw CBv2CompleteCheckpointError.invalidManifest }
                    manifest = try SSDHybridCheckpointEnvelope.decodeManifest(data)
                    throw ReadControl.manifestRead
                })
        } catch ReadControl.manifestRead { }
        guard let manifest, manifest.position == candidate.position, manifest.identity == identity,
            manifest.backendLayout == config.backendLayout,
            manifest.cacheSalt == request.cacheSalt, request.promptTokens.starts(with: manifest.prefixTokens)
        else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        let envelope = try SSDHybridCheckpointEnvelope(manifest: manifest, maximumPlaintextBytes: config.maxReadBytes)
        let plan: CBv2CompleteCheckpointImportPlan
        do { plan = try makeImportPlan(manifest) }
        catch CBv2CompleteCheckpointError.allocationFailed { throw ReadControl.capacity }
        catch { throw ReadControl.policy }
        let usesProcessMemoryOwner = plan.usesProcessMemoryOwner
        guard !usesProcessMemoryOwner || kvBudget != nil else { throw ReadControl.capacity }
        if !usesProcessMemoryOwner {
            let (destinationAndScratch, overflow1) = plan.nativeDestinationBytes.addingReportingOverflow(plan.scratchBytes)
            let (peak, overflow2) = destinationAndScratch.addingReportingOverflow(Self.ioScratchBytes)
            guard !overflow1, !overflow2, await lease.resize(to: peak) else { throw ReadControl.capacity }
        }
        try check()
        do {
            // Native destination retirement cannot refund provider buffers
            // still alive on this read stack. Shared mode owns them here.
            importer = try plan.allocate(onRelease: {
                if !usesProcessMemoryOwner { lease.release() }
            })
        } catch { throw ReadControl.capacity }
        // The native import now owns its destination/scratch. Provider I/O
        // remains charged until this entire helper has returned.
        readScratch.close()
        guard let filling = importer else { throw CBv2CompleteCheckpointError.allocationFailed }
        // Persist sliding recency before taking the authenticated file
        // snapshot. A later timestamp/content change invalidates dedupe.
        SSDBlockStore.setAttributesIfSafe([.modificationDate: Date(timeIntervalSince1970: Double(config.nowSeconds()))],
                                        at: url, under: config.root)
        var authenticatedFile: SSDAuthenticatedFileIdentity?
        statsBox.update { $0.filesRead += 1 }
        try SSDBlockStore.readStreaming(
            from: url, kekKey: kekKey,
            maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
            maximumPlaintextBytes: config.maxReadBytes,
            maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60, requireEOF: true,
            checkCancellation: check, onBytesRead: countRead,
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
        return LoadedCheckpoint(
            // The plan is an allocator upper bound. Only the completed stage
            // knows the evaluated allocation footprint retained by this hit.
            staged: staged, file: authenticatedFile, destinationBytes: staged.nativeDestinationBytes,
            usesProcessMemoryOwner: plan.usesProcessMemoryOwner)
    }
}
