import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    final class WriteJob: @unchecked Sendable {
        let source: CBv2CompleteCheckpointExport
        private var envelope: SSDHybridCheckpointEnvelope?
        private let hostReservation: ProcessHostBufferReservation?
        private let stats: SSDHybridCheckpointStatsBox
        let tag: Data
        let epoch: String?
        let authenticatedFile: SSDAuthenticatedFileIdentity?
        private let settlement: PrefixCacheDonationSettlement
        private let lock = NSLock()
        private var completion: (@Sendable ([Int]) -> Void)?

        init(source: CBv2CompleteCheckpointExport, envelope: SSDHybridCheckpointEnvelope,
             tag: Data, epoch: String?, authenticatedFile: SSDAuthenticatedFileIdentity?,
             settlement: PrefixCacheDonationSettlement,
             hostReservation: ProcessHostBufferReservation?, stats: SSDHybridCheckpointStatsBox,
             completion: @escaping @Sendable ([Int]) -> Void) {
            self.source = source
            self.envelope = envelope
            self.hostReservation = hostReservation
            self.stats = stats
            self.tag = tag
            self.epoch = epoch
            self.authenticatedFile = authenticatedFile
            self.completion = completion
            self.settlement = settlement
        }

        func readEnvelope() -> SSDHybridCheckpointEnvelope? { lock.withLock { envelope } }

        func finish(_ positions: [Int], outcome: PrefixCacheDonationOutcome = .cacheClosed) {
            let callback = lock.withLock {
                defer { completion = nil; envelope = nil }
                return completion
            }
            guard let callback else { return }
            source.close()
            if let hostReservation {
                hostReservation.closeAfterDroppingBuffers()
                stats.update { $0.writeHostBytesInUse -= Int(hostReservation.bytes) }
            }
            settlement.settle(outcome)
            callback(positions)
        }
    }

    public func donate(
        _ source: CBv2CompleteCheckpointExport, requestID: CBv2RequestID?,
        tokens: [Int], cacheSalt: String?, completion: @escaping @Sendable ([Int]) -> Void
    ) {
        let settlement = PrefixCacheDonationSettlement(recorder: donationRecorder)
        guard !isClosed else {
            source.close()
            settlement.settle(.cacheClosed)
            completion([])
            return
        }
        let hostReservation: ProcessHostBufferReservation?
        if source.usesProcessMemoryOwner {
            guard let kvBudget,
                let reservation = kvBudget.reserveHostBuffers(bytes: UInt64(Self.ioScratchBytes))
            else {
                statsBox.update { $0.writeHostCapacityRefusals += 1 }
                source.close()
                settlement.settle(.writeFailed)
                completion([])
                return
            }
            hostReservation = reservation
            statsBox.update {
                $0.writeHostBytesInUse += Self.ioScratchBytes
                $0.peakWriteHostBytes = max($0.peakWriteHostBytes, $0.writeHostBytesInUse)
            }
        } else {
            hostReservation = nil
        }
        let preparation = prepareWriteJob(
            source, requestID: requestID, tokens: tokens, cacheSalt: cacheSalt,
            hostReservation: hostReservation, settlement: settlement, completion: completion)
        // The preparation helper has dropped temporary encoded/hash buffers.
        // Only an accepted job's envelope may now retain provider-owned Data.
        switch preparation {
        case .refused(let outcome):
            source.close()
            if let hostReservation {
                hostReservation.closeAfterDroppingBuffers()
                statsBox.update { $0.writeHostBytesInUse -= Int(hostReservation.bytes) }
            }
            settlement.settle(outcome)
            completion([])
        case .ready(let job):
            if !pipeline.submit(job) {
                settle(job, positions: [], outcome: isClosed ? .cacheClosed : .writeQueueFull)
            }
        }
    }

    private enum WritePreparation {
        case ready(WriteJob)
        case refused(PrefixCacheDonationOutcome)
    }

    private func prepareWriteJob(
        _ source: CBv2CompleteCheckpointExport, requestID: CBv2RequestID?,
        tokens: [Int], cacheSalt: String?, hostReservation: ProcessHostBufferReservation?,
        settlement: PrefixCacheDonationSettlement,
        completion: @escaping @Sendable ([Int]) -> Void
    ) -> WritePreparation {
        guard !isClosed else { return .refused(.cacheClosed) }
        guard hasSafeRoot else { return .refused(.diskUnavailable) }
        let manifest = source.manifest
        guard manifest.position >= config.minEffectiveTokens else { return .refused(.belowEffectiveTokenFloor) }
        guard manifest.position > 0, manifest.position % PrefixCachePolicy.blockSize == 0 else {
            return .refused(.noCompleteBlock)
        }
        guard manifest.identity == identity, manifest.backendLayout == config.backendLayout,
            manifest.cacheSalt == cacheSalt,
            manifest.position < tokens.count, tokens.starts(with: manifest.prefixTokens)
        else { return .refused(.incompleteLayerState) }
        let envelope: SSDHybridCheckpointEnvelope
        do {
            envelope = try SSDHybridCheckpointEnvelope(manifest: manifest, maximumPlaintextBytes: config.maxReadBytes)
        } catch SSDHybridCheckpointEnvelope.EncodingError.sizeExceeded {
            return .refused(.stageSizeExceeded)
        } catch {
            return .refused(.incompleteLayerState)
        }
        let chain = hashes(tokens: tokens, scope: cacheSalt ?? "")
        let offset = manifest.position / PrefixCachePolicy.blockSize - 1
        guard chain.indices.contains(offset) else { return .refused(.noCompleteBlock) }
        let tag = lookupKeys.checkpointTag(chainHash: chain[offset], cacheSalt: cacheSalt ?? "")
        let short = Data(tag.prefix(16))
        let refusal: PrefixCacheDonationOutcome? = lock.withLock {
            guard !closed else { return .cacheClosed }
            guard !destructiveChange else { return .writeFailed }
            guard !writing.contains(short) else { return .alreadyQueued }
            guard writing.count < 2 else { return .writeQueueFull }
            writing.insert(short)
            return nil
        }
        if let refusal { return .refused(refusal) }
        let epoch = config.epochStore?.current
        let alreadyAuthenticated = lock.withLock { () -> SSDAuthenticatedFileIdentity? in
            guard let requestID, let proof = authenticatedReceipts[requestID], proof.epoch == epoch else { return nil }
            return proof.files[short]
        }
        return .ready(WriteJob(
            source: source, envelope: envelope, tag: tag, epoch: epoch,
            authenticatedFile: alreadyAuthenticated, settlement: settlement,
            hostReservation: hostReservation, stats: statsBox, completion: completion))
    }

    private struct WriteResult {
        var positions: [Int] = []
        var outcome: PrefixCacheDonationOutcome = .writeFailed
    }

    func write(_ job: WriteJob) {
        let started = ContinuousClock.now
        var result = WriteResult()
        performWrite(job, result: &result)
        statsBox.update { $0.writeMilliseconds += Self.milliseconds(since: started) }
        // The helper has dropped metadata, plaintext, ciphertext and returned
        // native Data. finish then drops the queued envelope before host refund.
        settle(job, positions: result.positions, outcome: result.outcome)
    }

    private func performWrite(_ job: WriteJob, result: inout WriteResult) {
        guard let envelope = job.readEnvelope() else { result.outcome = .cacheClosed; return }
        let short = Data(job.tag.prefix(16))
        let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: short.hexString)
        guard !isClosed, !Task.isCancelled else { result.outcome = .cacheClosed; return }
        guard hasSafeRoot else { result.outcome = .diskUnavailable; return }
        guard epochMatches(job.epoch) else { return }
        let metadata = envelope.metadata(
            tag: job.tag, identity: identity, createdAt: config.nowSeconds(), backendLayout: config.backendLayout)
        do {
            let alreadyDurable = index.contains(tag16: short)
            if alreadyDurable, job.authenticatedFile?.matches(url: url) == true {
                // This submission already authenticated all bytes during its
                // stage. Identity and epoch remain unchanged; no second read.
            } else if alreadyDurable {
                // A ready receipt must never rely on an advisory index entry.
                // Reauthenticate changed timestamps too: another legitimate
                // hit may have updated sliding recency since this stage.
                statsBox.update { $0.filesRead += 1 }
                try SSDBlockStore.readStreaming(
                    from: url, kekKey: kekKey,
                    maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                    maximumPlaintextBytes: config.maxReadBytes,
                    maximumMetadataBytes: 1 << 20, maximumWrappedDEKBytes: 60, requireEOF: true,
                    checkCancellation: { try self.checkWrite(job) },
                    onBytesRead: { count in self.statsBox.update { $0.bytesRead += count; $0.donationReadBytes += count } },
                    validateMetadata: {
                        guard envelope.matches($0, tag: job.tag, identity: self.identity, backendLayout: self.config.backendLayout) else {
                            throw CBv2CompleteCheckpointError.incompatibleCheckpoint
                        }
                    }, consumeChunk: { index, bytes in
                        if index == 0, bytes != envelope.manifestBytes {
                            throw CBv2CompleteCheckpointError.incompatibleCheckpoint
                        }
                    })
            } else {
                guard rateLimiter.tryConsume(bytes: envelope.plaintextBytes) else {
                    result.outcome = .writeRateLimited; return
                }
                if let space = SSDPrefixCache.volumeSpace(at: config.root) {
                    let floor = SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: space.capacity)
                    guard space.free >= floor, space.free - floor >= envelope.plaintextBytes else {
                        result.outcome = .diskUnavailable; return
                    }
                }
                let written = try SSDBlockStore.writeStreaming(
                    to: url, metadata: metadata, kekKey: kekKey,
                    maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                    strictFsync: config.strictFsync,
                    chunk: { index in
                        try self.checkWrite(job)
                        if index == 0 { return envelope.manifestBytes }
                        let segment = envelope.segments[index - 1]
                        self.statsBox.update { $0.maximumSegmentBytes = max($0.maximumSegmentBytes, segment.bytes) }
                        return try job.source.readSegment(
                            tensorIndex: segment.tensor, byteOffset: segment.offset, maximumBytes: segment.bytes)
                    })
                guard !isClosed else { result.outcome = .cacheClosed; return }
                guard epochMatches(job.epoch) else { return }
                index.insert(tag16: short, fileBytes: written, lastAccess: config.nowSeconds())
                statsBox.update { $0.filesWritten += 1; $0.bytesWritten += written }
            }
            config.maintainWholeRoot()
            _ = diskBudget.enforce(budgetBytes: config.diskBudgetBytes())
            if !isClosed, epochMatches(job.epoch), index.contains(tag16: short) {
                result.positions = [job.source.manifest.position]
                result.outcome = alreadyDurable ? .alreadyDurable : .donated
            }
        } catch {
            if isClosed || Task.isCancelled { result.outcome = .cacheClosed }
            if !(error is CancellationError), !isClosed { removeCorrupt(short) }
        }
    }

    func settle(_ job: WriteJob, positions: [Int], outcome: PrefixCacheDonationOutcome = .cacheClosed) {
        lock.withLock { _ = writing.remove(Data(job.tag.prefix(16))) }
        if positions.isEmpty { statsBox.update { $0.writesDropped += 1 } }
        // The engine owns the later post-release ready notification. It must
        // first release the donor's backend and checkpoint aliases.
        job.finish(positions, outcome: outcome)
    }

    func checkWrite(_ job: WriteJob) throws {
        guard !isClosed, !Task.isCancelled, epochMatches(job.epoch) else { throw CancellationError() }
    }

    func epochMatches(_ epoch: String?) -> Bool {
        guard let store = config.epochStore else { return true }
        guard let epoch else { return false }
        return store.current == epoch
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
    }
}
