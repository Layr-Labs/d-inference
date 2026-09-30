import Foundation
import MLXLMCommon

extension SSDHybridCheckpointStore {
    // Up to four 4 MiB crypto buffers plus bounded manifest/JSON work. The
    // engine's import scratch and active destination are charged separately.
    static let ioScratchBytes = CBv2CompleteCheckpointManifest.maximumProviderScratchBytes

    struct ReadCandidate {
        let position: Int
        let tag: Data
        let fileBytes: Int
    }

    private func candidate(hashes: [Data], scope: String, nativeHashes: [Int: Data]? = nil,
                           beforePosition: Int? = nil) -> ReadCandidate? {
        guard !isClosed, index.count > 0 else { return nil }
        let now = config.nowSeconds()
        let (fileCap, overflow) = config.maxReadBytes.addingReportingOverflow(1 << 20)
        guard !overflow else { return nil }
        let candidates: [(Int, Data)] = nativeHashes.map { $0.sorted { $0.key < $1.key }.map { ($0.key, $0.value) } }
            ?? hashes.enumerated().map { (($0.offset + 1) * PrefixCachePolicy.blockSize, $0.element) }
        for (position, hash) in candidates.reversed() {
            if let beforePosition, position >= beforePosition { continue }
            guard position >= config.minEffectiveTokens else { break }
            let tag = lookupKeys.checkpointTag(chainHash: hash, cacheSalt: scope)
            guard let size = index.freshFileBytes(
                tag16: Data(tag.prefix(16)), now: now, ttlSeconds: config.ttlSeconds),
                size <= fileCap,
                SSDPrefixCachePolicy.estimatedStageMillis(bytes: size) <= config.maxStageMillis
            else { continue }
            return ReadCandidate(position: position, tag: tag, fileBytes: size)
        }
        return nil
    }

    func stage(
        requestID: CBv2RequestID, request: CBv2Request,
        reserveReadScratch: @Sendable () throws -> CBv2CompleteCheckpointIOLease,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> CBv2CompleteCheckpointImportPlan
    ) async -> SSDPrefixCacheStageResult {
        guard config.backendLayout != CBv2CompleteCheckpointManifest.diffusionBlockLayout else {
            return .init(disposition: .skippedPolicy, stageMs: 0, chainHashes: [], blockSize: PrefixCachePolicy.blockSize)
        }
        return await stageTransfer(requestID: requestID, request: request, reserveReadScratch: reserveReadScratch,
            makeImportPlan: { .autoregressive(try makeImportPlan($0)) })
    }

    func stageNativeBlock(
        requestID: CBv2RequestID, request: CBv2Request,
        reserveReadScratch: @Sendable () throws -> CBv2CompleteCheckpointIOLease,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> CBv2NativeBlockCheckpointImportPlan
    ) async -> SSDPrefixCacheStageResult {
        let boundNativeMedia = request.hybridPrefixIdentity != nil && request.multimodal.map {
            !$0.spans.isEmpty && $0.attention == .bidirectionalSpans
                && $0.positionState == nil && $0.deepstackEmbeddings == nil
        } == true
        guard config.backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout,
            (config.nativePrefillChunkSize ?? 0) > 0,
            request.positionState == nil,
            (request.multimodal == nil && request.hybridPrefixIdentity == nil) || boundNativeMedia,
            let scope = request.cacheSalt, !scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            scope.utf8.count <= 4096 else {
            return .init(disposition: .skippedPolicy, stageMs: 0, chainHashes: [], blockSize: PrefixCachePolicy.blockSize)
        }
        guard kvBudget != nil else {
            return .init(disposition: .skippedCapacity, stageMs: 0, chainHashes: [], blockSize: PrefixCachePolicy.blockSize)
        }
        return await stageTransfer(requestID: requestID, request: request, reserveReadScratch: reserveReadScratch,
            makeImportPlan: { .nativeBlock(try makeImportPlan($0)) })
    }

    private func stageTransfer(
        requestID: CBv2RequestID, request: CBv2Request,
        reserveReadScratch: @Sendable () throws -> CBv2CompleteCheckpointIOLease,
        makeImportPlan: @Sendable (CBv2CompleteCheckpointManifest) throws -> SSDCheckpointImportPlan
    ) async -> SSDPrefixCacheStageResult {
        let deviceActivity = kvBudget?.serviceBudget.beginUnboundedActivity()
        defer { deviceActivity?.finish() }
        let budget = SSDCheckpointReadBudget(
            maximumBytes: config.maxReadBytes, maximumMillis: config.maxStageMillis,
            started: config.stageNow(), now: config.stageNow)
        let scope = request.checkpointCacheSalt ?? ""
        let chain = hashes(tokens: request.promptTokens, scope: scope)
        func result(_ disposition: SSDPrefixCacheStageDisposition, deviceBytes: Int = 0) -> SSDPrefixCacheStageResult {
            let elapsed = max(0, budget.elapsedMillis)
            statsBox.update { $0.stageMilliseconds += elapsed }
            return .init(disposition: disposition, stageMs: elapsed, chainHashes: chain,
                         blockSize: PrefixCachePolicy.blockSize, deviceBytes: deviceBytes)
        }
        let boundMedia = request.multimodal != nil && request.hybridPrefixIdentity != nil
        guard !Task.isCancelled, request.prefixCacheEnabled,
            (request.multimodal == nil && request.positionState == nil) || boundMedia else {
            return result(.skippedPolicy)
        }
        let nativeHashes: [Int: Data]?
        if config.backendLayout == CBv2CompleteCheckpointManifest.diffusionBlockLayout,
            let media = request.multimodal {
            do {
                guard let chunkSize = config.nativePrefillChunkSize else { return result(.skippedPolicy) }
                let geometry = try DiffusionGemmaPrefillGeometry(promptCount: request.promptTokens.count,
                    chunkSize: chunkSize, spans: media.spans)
                nativeHashes = try NativeDiffusionCheckpointKeys.hashes(tokens: request.promptTokens,
                    positions: geometry.boundaries, promptContractID: identity.promptContractID, scope: scope)
            } catch { return result(.skippedPolicy) }
        } else { nativeHashes = nil }
        guard var selected = candidate(hashes: chain, scope: scope, nativeHashes: nativeHashes), hasSafeRoot else {
            statsBox.update { $0.misses += 1 }
            return result(.missAbsent)
        }
        var readScratch: CBv2CompleteCheckpointIOLease
        do { readScratch = try reserveReadScratch() }
        catch is CancellationError { return result(.skippedPolicy) }
        catch { return result(.skippedCapacity) }
        defer { readScratch.close() }
        // Initial scratch/host authority refusals are not retry signals.
        guard !readScratch.usesProcessMemoryOwner || kvBudget != nil else {
            return result(.skippedCapacity)
        }
        var access = fileCoordinator.makeAccess(to: SSDBlockStore.fileURL(
            root: config.root, tag16Hex: Data(selected.tag.prefix(16)).hexString))
        let accepted = lock.withLock {
            guard !closed, reading[requestID] == nil, stages[requestID] == nil else { return false }
            reading[requestID] = access
            activity.begin()
            return true
        }
        guard accepted else { return result(.skippedPolicy) }
        defer {
            // Retirement callbacks still see this logical registration. Remove
            // only its current access, never a same-ID replacement's entry.
            readScratch.close()
            access.release()
            lock.withLock { if reading[requestID] === access { reading.removeValue(forKey: requestID) } }
            activity.end()
        }
        let epoch = config.epochStore?.current
        var retried = false
        while true {
            if retried {
                guard readIsCurrent(requestID: requestID, access: access, epoch: epoch) else {
                    return result(.skippedPolicy)
                }
                do { try budget.checkTime() } catch { return result(.skippedCapacity) }
            }
            let reservationKey = "ssd-complete:\(namespace):\(UUID().uuidString)"
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
            // The helper owns every manifest/plan/import alias. A failed scalar
            // return means those owners have unwound before any host refund.
            let outcome = await readAttempt(
                requestID: requestID, request: request, candidate: selected,
                access: access, epoch: epoch, lease: lease, readScratch: readScratch,
                budget: budget, makeImportPlan: makeImportPlan)
            if case .staged = outcome.disposition {
                transferred = true
                return result(outcome.disposition, deviceBytes: outcome.deviceBytes)
            }
            guard outcome.retryable else { return result(outcome.disposition) }

            readScratch.close()
            access.release()
            lease.finishIO()
            lease.release()
            await lease.waitForRefund()
            // Keep the old registration throughout unwind/refund. Complete,
            // close, cancellation, epoch drift or replacement wins before retry.
            guard readIsCurrent(requestID: requestID, access: access, epoch: epoch), hasSafeRoot else {
                return result(.skippedPolicy)
            }
            guard !retried,
                let next = candidate(hashes: chain, scope: scope, nativeHashes: nativeHashes,
                                     beforePosition: selected.position),
                budget.beginRetry(estimatedFileBytes: next.fileBytes)
            else { return result(.skippedCapacity) }
            let nextAccess = fileCoordinator.makeAccess(to: SSDBlockStore.fileURL(
                root: config.root, tag16Hex: Data(next.tag.prefix(16)).hexString))
            let advanced = lock.withLock {
                guard !Task.isCancelled, !closed,
                    reading[requestID] === access, epochMatches(epoch) else { return false }
                // Atomic handoff, not remove-and-register. Lifecycle cancellation
                // always finds either the retiring access or the shorter access.
                reading[requestID] = nextAccess
                return true
            }
            guard advanced else { return result(.skippedPolicy) }
            access = nextAccess
            selected = next
            retried = true
            do {
                try budget.checkTime()
                readScratch = try reserveReadScratch()
            } catch is CancellationError { return result(.skippedPolicy) }
              catch { return result(.skippedCapacity) }
            guard !readScratch.usesProcessMemoryOwner || kvBudget != nil else {
                return result(.skippedCapacity)
            }
        }
    }

    func readIsCurrent(requestID: CBv2RequestID, access: SSDCheckpointFileCoordinator.Access,
                       epoch: String?) -> Bool {
        !Task.isCancelled && epochMatches(epoch) && lock.withLock {
            !closed && reading[requestID] === access
        }
    }
}
