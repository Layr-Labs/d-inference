import Foundation
import MLXLMCommon

/// Thrown inside a speculative write that gives its disk room back: its
/// reservation was revoked for a proven write, or the room was gone when the
/// finished file was about to be published.
struct SSDSpeculativeWriteYield: Error {}

extension SSDHybridCheckpointStore {
    final class WriteJob: @unchecked Sendable {
        let source: CBv2CompleteCheckpointExport
        private var envelope: SSDHybridCheckpointEnvelope?
        private let hostReservation: ProcessHostBufferReservation?
        private let stats: SSDHybridCheckpointStatsBox
        let tag: Data
        let epoch: String?
        let writeClass: SSDWriteClass
        let authenticatedFile: SSDAuthenticatedFileIdentity?
        private let settlement: PrefixCacheDonationSettlement
        private let lock = NSLock()
        private var completion: (@Sendable ([Int]) -> Void)?

        init(source: CBv2CompleteCheckpointExport, envelope: SSDHybridCheckpointEnvelope,
             tag: Data, epoch: String?, writeClass: SSDWriteClass,
             authenticatedFile: SSDAuthenticatedFileIdentity?,
             settlement: PrefixCacheDonationSettlement,
             hostReservation: ProcessHostBufferReservation?, stats: SSDHybridCheckpointStatsBox,
             completion: @escaping @Sendable ([Int]) -> Void) {
            self.source = source
            self.envelope = envelope
            self.hostReservation = hostReservation
            self.stats = stats
            self.tag = tag
            self.epoch = epoch
            self.writeClass = writeClass
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
        if source.usesProcessMemoryOwner || source.manifest.backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout {
            guard let kvBudget,
                let reservation = kvBudget.reserveHostBuffers(bytes: UInt64(Self.ioScratchBytes))
            else {
                statsBox.update { $0.writeHostCapacityRefusals += 1 }
                source.close()
                settlement.settle(.hostMemoryUnavailable)
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
        guard hasSafeRoot else { return .refused(.unsafeCacheRoot) }
        let manifest = source.manifest
        let nativeMedia = config.backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout
            && manifest.mediaIdentity != nil
        guard manifest.position >= config.minEffectiveTokens else { return .refused(.belowEffectiveTokenFloor) }
        guard manifest.position > 0, nativeMedia || manifest.position % PrefixCachePolicy.blockSize == 0 else {
            return .refused(.noCompleteBlock)
        }
        guard manifest.identity == identity, manifest.backendLayout == config.backendLayout,
            manifest.cacheSalt == cacheSalt,
            (manifest.backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout
                ? manifest.position <= tokens.count : manifest.position < tokens.count),
            tokens.starts(with: manifest.prefixTokens)
        else { return .refused(.incompleteLayerState) }
        let envelope: SSDHybridCheckpointEnvelope
        do {
            envelope = try SSDHybridCheckpointEnvelope(manifest: manifest, maximumPlaintextBytes: config.maxReadBytes)
        } catch SSDHybridCheckpointEnvelope.EncodingError.sizeExceeded {
            return .refused(.stageSizeExceeded)
        } catch {
            return .refused(.incompleteLayerState)
        }
        let digest: Data
        if nativeMedia {
            guard manifest.chunkSize == config.nativePrefillChunkSize,
                let values = try? NativeDiffusionCheckpointKeys.hashes(tokens: manifest.prefixTokens,
                    positions: [manifest.position], promptContractID: identity.promptContractID, scope: cacheSalt ?? ""),
                let value = values[manifest.position] else { return .refused(.incompleteLayerState) }
            digest = value
        } else {
            let chain = hashes(tokens: tokens, scope: cacheSalt ?? "")
            let offset = manifest.position / PrefixCachePolicy.blockSize - 1
            guard chain.indices.contains(offset) else { return .refused(.noCompleteBlock) }
            digest = chain[offset]
        }
        let tag = lookupKeys.checkpointTag(chainHash: digest, cacheSalt: cacheSalt ?? "")
        let short = Data(tag.prefix(16))
        let localRepeat = writeDemand.observe(short, now: config.nowSeconds())
        let offered = offeredWriteClass(requestID: requestID, localRepeat: localRepeat)
        let fresh = !index.contains(tag16: short)
        if fresh {
            // Demand gate first: a fleet-novel checkpoint is skipped before any
            // budget is charged (`SSDHybridCheckpointStore+DemandAdmission`).
            // The tag was recorded above, so a local second sighting qualifies.
            guard let offered else { return .refused(.skippedNovel) }
            // Novel writes use a 90% sub-budget, leaving capacity for known
            // repeat demand, and speculative writes only the headroom above
            // both. Durable duplicates consume no write budget. The writer
            // rechecks after queueing, since this admission is advisory.
            if let refusal = Self.writeRefusal(
                rateLimiter.admission(bytes: envelope.plaintextBytes, writeClass: offered)) {
                return .refused(refusal)
            }
            if offered == .speculative {
                // Disk room, in stored bytes: the file is longer than its
                // plaintext by the header, the metadata and each chunk's
                // framing. Advisory as well; the writer reserves.
                let metadata = envelope.metadata(
                    tag: tag, identity: identity, createdAt: config.nowSeconds(), backendLayout: config.backendLayout)
                guard let storedBytes = try? SSDBlockStore.streamedFileBytes(for: metadata),
                    hasDiskRoomForSpeculativeWrite(storedBytes: storedBytes)
                else { return .refused(.writeSpeculativeLimited) }
            }
        }
        // The job keeps its class, so a duplicate whose durable entry is gone
        // by the time the writer runs is charged as what it is. Only a durable
        // duplicate of a request without demand has no class; it bypasses the
        // gate as before and revalidates as a novel write.
        let writeClass = offered ?? .novel
        let refusal: PrefixCacheDonationOutcome? = lock.withLock {
            guard !closed else { return .cacheClosed }
            guard !writing.contains(short) else { return .alreadyQueued }
            // One write runs while one waits. A speculative write is admitted
            // only while no write is registered here, so it never takes the
            // waiting slot behind a registered write. `writing` is not the
            // writer, though: `settle` clears it before the finished job's
            // completion returns, so a speculative job admitted in that span
            // sits in the pipeline's one buffered slot, and a proven write
            // arriving before the consumer takes it settles `write_queue_full`.
            if writeClass == .speculative {
                guard writing.isEmpty else { return .writeSpeculativeLimited }
            } else {
                guard writing.count < 2 else { return .writeQueueFull }
                // What this job may put on disk, until it records its exact
                // bytes on the ledger: its plaintext plus at most the
                // megabyte of framing the read path allows for. A durable
                // duplicate writes nothing and records nothing.
                if fresh {
                    let (bound, overflow) = envelope.plaintextBytes.addingReportingOverflow(1 << 20)
                    provenWriteBytes[short] = overflow ? Int.max : bound
                }
            }
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
            source: source, envelope: envelope, tag: tag, epoch: epoch, writeClass: writeClass,
            authenticatedFile: alreadyAuthenticated, settlement: settlement,
            hostReservation: hostReservation, stats: statsBox, completion: completion))
    }

    private static func writeRefusal(_ decision: SSDWriteRateLimiter.Decision) -> PrefixCacheDonationOutcome? {
        switch decision {
        case .accepted: nil
        case .rateLimited: .writeRateLimited
        case .priorityLimited: .writePriorityLimited
        case .speculativeLimited: .writeSpeculativeLimited
        }
    }

    private struct WriteResult {
        var positions: [Int] = []
        var outcome: PrefixCacheDonationOutcome = .writeFailed
    }

    func write(_ job: WriteJob) async {
        // Export readSegment can perform device materialization/readback on
        // this background worker, independently of the original request.
        let deviceActivity = kvBudget?.serviceBudget.beginUnboundedActivity()
        defer { deviceActivity?.finish() }
        let started = ContinuousClock.now
        var result = WriteResult()
        let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: Data(job.tag.prefix(16)).hexString)
        let access = fileCoordinator.makeAccess(to: url)
        do {
            try await access.acquire()
            // Early exits also release. performWrite releases before budget
            // maintenance so self-eviction still works and lock order is safe.
            defer { access.release() }
            performWrite(job, access: access, result: &result)
        } catch {
            result.outcome = .cacheClosed
        }
        statsBox.update { $0.writeMilliseconds += Self.milliseconds(since: started) }
        // The helper has dropped metadata, plaintext, ciphertext and returned
        // native Data. finish then drops the queued envelope before host refund.
        settle(job, positions: result.positions, outcome: result.outcome)
    }

    private func performWrite(_ job: WriteJob, access: SSDCheckpointFileCoordinator.Access,
                              result: inout WriteResult) {
        guard let envelope = job.readEnvelope() else { result.outcome = .cacheClosed; return }
        let short = Data(job.tag.prefix(16))
        let url = SSDBlockStore.fileURL(root: config.root, tag16Hex: short.hexString)
        guard !isClosed, !Task.isCancelled else { result.outcome = .cacheClosed; return }
        guard hasSafeRoot else { result.outcome = .unsafeCacheRoot; return }
        guard epochMatches(job.epoch) else { result.outcome = .cacheEpochChanged; return }
        let metadata = envelope.metadata(
            tag: job.tag, identity: identity, createdAt: config.nowSeconds(), backendLayout: config.backendLayout)
        var authenticatingExistingFile = false
        // A fresh write's claim on the box-wide disk budget, for the file's
        // complete stored size. Released exactly once, here, on every exit:
        // the bytes are counted somewhere from before the first byte until
        // the file is indexed or gone.
        var reservation: SSDDiskReservation?
        var disposition = SSDDiskReservation.Disposition.discarded
        defer { if let reservation { diskBudget.release(reservation, as: disposition) } }
        do {
            let alreadyDurable = index.contains(tag16: short)
            if alreadyDurable, job.authenticatedFile?.matches(url: url) == true {
                // This submission already authenticated all bytes during its
                // stage. Identity and epoch remain unchanged; no second read.
            } else if alreadyDurable {
                authenticatingExistingFile = true
                // A ready receipt must never rely on an advisory index entry.
                // Reauthenticate changed timestamps too: another legitimate
                // hit may have updated sliding recency since this stage.
                try validateDurableCheckpoint(job, at: url)
            } else {
                if let space = SSDPrefixCache.volumeSpace(at: config.root) {
                    let floor = SSDPrefixCachePolicy.lowDiskFloorBytes(volumeCapacityBytes: space.capacity)
                    guard space.free >= floor, space.free - floor >= envelope.plaintextBytes else {
                        result.outcome = .diskSpaceInsufficient; return
                    }
                }
                let speculative = job.writeClass == .speculative
                let keys = [reservationKey(short)]
                // What is on the volume once chunk `i` is written; a
                // speculative write reports it so no enforcement evicts for
                // bytes that are nobody's entry yet.
                var landedThrough: [Int] = []
                if speculative {
                    // A speculative write withdraws its own file when it
                    // loses its room, so it never replaces a file that is
                    // already at its path: that one may be indexed by a
                    // successor on this root, or be an equal checkpoint.
                    guard SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) != .regular else {
                        result.outcome = .writeSpeculativeLimited; return
                    }
                    let storedBytes = try SSDBlockStore.streamedFileBytes(for: metadata)
                    // Binding, and before the charge: room is reserved for the
                    // whole file or the write is declined with nothing spent.
                    guard let granted = diskBudget.reserveSpeculative(
                        bytes: storedBytes, keys: keys, wholeRootKey: wholeRootKey, basis: diskBudgetBasis())
                    else { result.outcome = .writeSpeculativeLimited; return }
                    reservation = granted
                    var landed = storedBytes - metadata.chunkPlaintextSizes.reduce(0) {
                        $0 + $1 + SSDBlockStore.streamedChunkFramingBytes
                    }
                    // The header and the metadata go out before the first chunk.
                    granted.noteLanded(upTo: landed)
                    landedThrough = metadata.chunkPlaintextSizes.map {
                        landed += $0 + SSDBlockStore.streamedChunkFramingBytes
                        return landed
                    }
                }
                if let refusal = Self.writeRefusal(
                    rateLimiter.consume(bytes: envelope.plaintextBytes, writeClass: job.writeClass)) {
                    result.outcome = refusal; return
                }
                // A proven write is never refused room. It records its bytes
                // so that no speculative write is granted the same room, and
                // asks the volume for its budget only when a speculative
                // write is in flight to be told to give way.
                // Its exact bytes replace the bound recorded when it was
                // accepted, in one step, so it is never counted twice.
                let claim = try reservation ?? diskBudget.registerProven(
                    bytes: SSDBlockStore.streamedFileBytes(for: metadata), keys: keys,
                    wholeRootKey: wholeRootKey,
                    basis: diskBudget.hasSpeculativeReservations ? diskBudgetBasis() : nil,
                    replacingQueued: { self.lock.withLock { _ = self.provenWriteBytes.removeValue(forKey: short) } })
                reservation = claim
                #if DEBUG
                afterDiskClaimForTesting?(url)
                #endif
                let written = try SSDBlockStore.writeStreaming(
                    to: url, metadata: metadata, kekKey: kekKey,
                    maximumChunkBytes: CBv2CompleteCheckpointManifest.maximumSegmentBytes,
                    strictFsync: config.strictFsync,
                    beforePublish: speculative
                        ? { try self.checkSpeculativePublish(job, claim, fileBytes: $0) } : nil,
                    chunk: { index in
                        try self.checkWrite(job)
                        if speculative {
                            if claim.isRevoked { throw SSDSpeculativeWriteYield() }
                            #if DEBUG
                            self.beforeSpeculativeChunkForTesting?(index)
                            #endif
                            claim.noteLanded(upTo: landedThrough[index])
                        }
                        if index == 0 { return envelope.manifestBytes }
                        let segment = envelope.segments[index - 1]
                        self.statsBox.update { $0.maximumSegmentBytes = max($0.maximumSegmentBytes, segment.bytes) }
                        return try job.source.readSegment(
                            tensorIndex: segment.tensor, byteOffset: segment.offset, maximumBytes: segment.bytes)
                    })
                lock.withLock { beforeWriteIndexForTesting }?(url, false)
                guard !isClosed else {
                    disposition = abandonPublishedFile(url, speculative: speculative)
                    result.outcome = .cacheClosed; return
                }
                guard epochMatches(job.epoch) else {
                    disposition = abandonPublishedFile(url, speculative: speculative)
                    result.outcome = .cacheEpochChanged; return
                }
                #if DEBUG
                afterPublishBeforeIndexForTesting?()
                #endif
                // Publish-to-index is atomic with respect to removals: every
                // unlink (budget eviction, TTL sweep, corrupt drop, whole-root
                // maintenance) holds `removalLock`, so the file is either still
                // present here and indexed before any later removal can
                // reconcile it, or already gone and never advertised.
                let insert = {
                    self.removalLock.withLock {
                        guard SSDBlockStore.indexedBlockFileStatus(at: url, under: self.config.root) == .regular else {
                            return false
                        }
                        // A speculative file is not indexed into a store
                        // that closed or changed epoch since the guards
                        // above; it is withdrawn below instead.
                        if speculative, self.isClosed || !self.epochMatches(job.epoch) { return false }
                        self.index.insert(tag16: short, fileBytes: written, lastAccess: self.config.nowSeconds())
                        return true
                    }
                }
                if speculative {
                    // Indexed only while the room it was granted still
                    // holds, in one step with the release of its claim, so
                    // the enforcement below has nothing to evict for it.
                    guard diskBudget.commitSpeculative(
                        claim, fileBytes: written, basis: { self.diskBudgetBasis() }, insert: insert)
                    else {
                        let published = SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) == .regular
                        disposition = abandonPublishedFile(url, speculative: true)
                        if isClosed {
                            result.outcome = .cacheClosed
                        } else if !epochMatches(job.epoch) {
                            result.outcome = .cacheEpochChanged
                        } else if published {
                            result.outcome = .writeSpeculativeLimited
                            statsBox.update { $0.speculativeWritesYielded += 1 }
                        } else {
                            result.outcome = .cacheEntryEvicted
                        }
                        return
                    }
                } else {
                    // One step with the release of its record. A store that
                    // closed meanwhile keeps the file as before; its bytes
                    // are then counted as unowned.
                    guard diskBudget.commitProven(claim, store: self, insert: insert) else {
                        result.outcome = .cacheEntryEvicted; return
                    }
                }
                statsBox.update { $0.filesWritten += 1; $0.bytesWritten += written }
            }
            if alreadyDurable { lock.withLock { beforeWriteIndexForTesting }?(url, true) }
            // The durable file and its index entry now form one committed
            // entry. Retirement may remove both, including this new victim.
            access.release()
            config.maintainWholeRoot()
            _ = diskBudget.enforce(basis: { self.diskBudgetBasis() })
            let durable = index.contains(tag16: short)
                && SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) == .regular
            if !isClosed, epochMatches(job.epoch), durable {
                result.positions = [job.source.manifest.position]
                result.outcome = alreadyDurable ? .alreadyDurable : .donated
            } else if isClosed {
                result.outcome = .cacheClosed
            } else if !durable {
                // Routine retirement can remove this endpoint without changing
                // the identity of other checkpoints. Never publish the victim.
                result.outcome = .cacheEntryEvicted
            } else if !epochMatches(job.epoch) {
                result.outcome = .cacheEpochChanged
            } else {
                // A concurrent state transition may have settled between the
                // reads above. Never manufacture READY from the failed gate.
                result.outcome = .writeFailed
            }
        } catch {
            if isClosed {
                result.outcome = .cacheClosed
            } else if !epochMatches(job.epoch) {
                result.outcome = .cacheEpochChanged
            } else if authenticatingExistingFile && !(error is CancellationError) {
                // An advertised file failed reauthentication. Revoke its
                // evidence before removal, exactly as the lookup path does.
                result.outcome = .existingCacheUnreadable
                removeCorrupt(short)
            } else if error is SSDSpeculativeWriteYield {
                // The temp file is gone and nothing was published. The write
                // budget charged before the first byte is not refunded.
                result.outcome = .writeSpeculativeLimited
                statsBox.update { $0.speculativeWritesYielded += 1 }
            } else if Task.isCancelled || error is CancellationError {
                result.outcome = .cacheClosed
            } else {
                result.outcome = Self.freshWriteFailureOutcome(error)
                // Atomic creation did not publish an index entry or receipt.
                // Do not call removeCorrupt: there is no advertised file to
                // revoke or index entry to drop, and a transient write
                // failure is not corruption. A later donation may retry
                // after the condition clears.
            }
        }
    }

    /// Runs while a speculative write's finished file is still a temp file:
    /// a throw removes it, so a write that lost its room, or whose store
    /// closed or changed epoch, never appears under its final name.
    private func checkSpeculativePublish(
        _ job: WriteJob, _ claim: SSDDiskReservation, fileBytes: Int
    ) throws {
        try checkWrite(job)
        guard diskBudget.mayPublishSpeculative(claim, fileBytes: fileBytes, basis: { self.diskBudgetBasis() })
        else { throw SSDSpeculativeWriteYield() }
    }

    /// A fresh write's file was published and will not be indexed. A
    /// speculative file is removed: this writer still holds its lease, so no
    /// index, scan or retirement has it. A proven file stays where it is, as
    /// before, and is counted as bytes no index owns.
    private func abandonPublishedFile(_ url: URL, speculative: Bool) -> SSDDiskReservation.Disposition {
        guard speculative else { return .abandonedOnDisk }
        let gone = removalLock.withLock {
            _ = SSDBlockStore.removeItemIfSafe(at: url, under: config.root)
            return SSDBlockStore.indexedBlockFileStatus(at: url, under: config.root) != .regular
        }
        return gone ? .discarded : .abandonedOnDisk
    }

    func settle(_ job: WriteJob, positions: [Int], outcome: PrefixCacheDonationOutcome = .cacheClosed) {
        lock.withLock {
            let short = Data(job.tag.prefix(16))
            writing.remove(short)
            provenWriteBytes.removeValue(forKey: short)
        }
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
