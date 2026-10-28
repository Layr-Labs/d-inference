import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    private enum ReadControl: Error { case retryableCapacity, capacity, policy }

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

    // Only scalars escape a failed attempt. Retry authority additionally needs
    // native retirement proof; dropping public handles does not provide it.
    func readAttempt(
        requestID: CBv2RequestID, request: CBv2Request, candidate: ReadCandidate,
        access: SSDCheckpointFileCoordinator.Access, epoch: String?,
        lease: SSDCheckpointStageReservation, readScratch: CBv2CompleteCheckpointIOLease,
        budget: SSDCheckpointReadBudget,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> SSDCheckpointImportPlan
    ) async -> ReadAttemptResult {
        let check: () throws -> Void = {
            guard self.readIsCurrent(requestID: requestID, access: access, epoch: epoch) else {
                throw CancellationError()
            }
            try budget.checkTime()
        }
        let countRead: (Int) -> Void = { count in
            self.statsBox.update { $0.bytesRead += count; $0.stageReadBytes += count }
        }
        // A failure retires the file in use; files built on it never stage again and age out.
        var failing = Data(candidate.tag.prefix(16))
        do {
            try await access.acquire()
            try check()
            guard index.chain(tag16: failing, now: config.nowSeconds(), ttlSeconds: config.ttlSeconds)?.tags
                == candidate.chain else {
                statsBox.update { $0.misses += 1 }
                return .init(.missAbsent)
            }
            let loaded = try await readCheckpoint(
                candidate: candidate, request: request, access: access, lease: lease,
                readScratch: readScratch, budget: budget, check: check, countRead: countRead,
                blame: { failing = $0 }, makeImportPlan: makeImportPlan)
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
                guard !Task.isCancelled, !closed, reading[requestID] === access,
                    epochMatches(epoch) else { return false }
                stages[requestID] = staged
                if !loaded.usesProcessMemoryOwner { stageReservations[requestID] = lease }
                authenticatedReceipts[requestID] = (epoch, [Data(candidate.tag.prefix(16)): loaded.file])
                restoredCheckpoints[requestID] = (loaded.restored, false)
                return true
            }
            guard installed else { staged.close(); return .init(.skippedPolicy) }
            index.touch(tags16: candidate.chain, now: config.nowSeconds())
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
            if SSDBlockStore.isAbsentBlockFailure(error, at: fileURL(failing), under: config.root) {
                forgetMissing(failing)
                statsBox.update { $0.misses += 1 }
                return .init(.missAbsent)
            }
            // Another reader may still be streaming these bytes. The last one
            // to fail, the next writer or maintenance removes them instead.
            whileSoleHolder(of: failing, in: candidate, access: access) { removeCorrupt(failing) }
            return .init(.missCorrupt)
        }
    }

    /// Persisted recency needs only TTL resolution: a file whose mtime is
    /// younger than 1/30 of the TTL (one minute at the 30-minute default)
    /// keeps it, so receipts pinned to its identity survive repeated hits.
    var recencyRefreshSeconds: Int64 { config.ttlSeconds / 30 }

    /// Runs `mutate` only while nothing else holds or awaits the file: the leaf
    /// through a non-blocking upgrade of this read's shared lease, an ancestor
    /// through a free exclusive lease. A busy file is left unchanged.
    private func whileSoleHolder(of tag: Data, in candidate: ReadCandidate,
                                 access: SSDCheckpointFileCoordinator.Access, _ mutate: () -> Void) {
        if tag == candidate.chain.last {
            guard access.tryUpgrade() else { return }
            defer { access.downgrade() }
            mutate()
        } else if let held = fileCoordinator.tryAcquire(to: fileURL(tag)) {
            defer { held.release() }
            mutate()
        }
    }

    /// Recency survives a restart and orders whole-root maintenance by mtime.
    /// A touch also moves ctime, failing a concurrent reader's identity proof
    /// and every receipt pinned to the file, so it needs the file alone and
    /// waits until the mtime is `recencyRefreshSeconds` old. The in-memory
    /// index records every hit regardless.
    private func persistRecency(of candidate: ReadCandidate, access: SSDCheckpointFileCoordinator.Access) {
        let now = config.nowSeconds()
        for tag in candidate.chain where !recencyIsCurrent(at: fileURL(tag), now: now) {
            whileSoleHolder(of: tag, in: candidate, access: access) {
                SSDBlockStore.setAttributesIfSafe([.modificationDate: Date(timeIntervalSince1970: Double(now))],
                                                at: fileURL(tag), under: config.root)
            }
        }
    }

    /// A future or unreadable mtime is not current.
    private func recencyIsCurrent(at url: URL, now: Int64) -> Bool {
        guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        let age = now - Int64(modified.timeIntervalSince1970)
        return age >= 0 && age < recencyRefreshSeconds
    }

    private struct LoadedCheckpoint {
        let staged: SSDCheckpointStage
        let file: SSDAuthenticatedFileIdentity
        let destinationBytes: Int
        let usesProcessMemoryOwner: Bool
        let restored: [SSDHybridCheckpointEnvelope.Parent]
    }

    private func readCheckpoint(
        candidate: ReadCandidate, request: CBv2Request, access: SSDCheckpointFileCoordinator.Access,
        lease: SSDCheckpointStageReservation, readScratch: CBv2CompleteCheckpointIOLease,
        budget: SSDCheckpointReadBudget, check: () throws -> Void, countRead: @escaping (Int) -> Void,
        blame: (Data) -> Void,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> SSDCheckpointImportPlan
    ) async throws -> LoadedCheckpoint {
        var importer: SSDCheckpointImport?
        defer { importer?.close() }
        statsBox.update { $0.filesRead += candidate.chain.count }
        let manifest = try openChain(candidate, tracksIdentity: false, check: check, beforeRead: budget.beforeRead,
                                     countRead: countRead, blame: blame).last!.link.manifest
        guard manifest.position == candidate.position, manifest.identity == identity,
            manifest.backendLayout == config.backendLayout,
            manifest.cacheSalt == request.checkpointCacheSalt, request.promptTokens.starts(with: manifest.prefixTokens)
        else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        let plan: SSDCheckpointImportPlan
        do { plan = try makeImportPlan(manifest) }
        catch CBv2KVError.capacityExhausted { throw ReadControl.retryableCapacity }
        catch CBv2CompleteCheckpointError.allocationFailed { throw ReadControl.capacity }
        catch { throw ReadControl.policy }
        let usesProcessMemoryOwner = plan.usesProcessMemoryOwner
        guard !usesProcessMemoryOwner || kvBudget != nil else { throw ReadControl.capacity }
        if !usesProcessMemoryOwner {
            let (destinationAndScratch, overflow1) = plan.nativeDestinationBytes.addingReportingOverflow(plan.scratchBytes)
            let (peak, overflow2) = destinationAndScratch.addingReportingOverflow(
                Self.ioScratchBytes(files: candidate.chain.count))
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
            // The pinned AR API can queue tracked-native retirement while
            // retaining the charged manifest. It exposes neither a tracking
            // discriminator nor a completion receipt: host refund alone cannot
            // authorize another attempt. Native-block refusal unwinds inline.
            guard case .nativeBlock = plan else { throw ReadControl.capacity }
            throw ReadControl.retryableCapacity
        } catch { throw ReadControl.capacity }
        readScratch.close()
        guard let filling = importer else { throw CBv2CompleteCheckpointError.allocationFailed }
        // Any touch precedes the identity this second open records.
        persistRecency(of: candidate, access: access)
        statsBox.update { $0.filesRead += candidate.chain.count }
        var files = try openChain(candidate, tracksIdentity: true, check: check, beforeRead: budget.beforeRead,
                                  countRead: countRead, blame: blame)
        guard files.last?.link.manifest == manifest else { throw CBv2CompleteCheckpointError.incompatibleCheckpoint }
        let authenticatedFile = try streamChain(&files, check: check, blame: blame) {
            try filling.appendSegment(tensorIndex: $0, byteOffset: $1, data: $2)
        }
        try check()
        guard let authenticatedFile, authenticatedFile.matches(url: fileURL(Data(candidate.tag.prefix(16)))) else {
            throw SSDAuthenticatedFileChange.changedDuringRead
        }
        let staged = try filling.finish()
        importer = nil
        return LoadedCheckpoint(staged: staged, file: authenticatedFile,
            destinationBytes: staged.nativeDestinationBytes, usesProcessMemoryOwner: plan.usesProcessMemoryOwner,
            restored: [files.last!.link, files[0].link])
    }
}
