// Deadline checks and ownership of pre-submit reservations.

import Foundation
import MLXLMCommon
import ProviderCoreFoundation

/// One-way handoff flag shared by submit defers and the detached retirement
/// owner. Once claimed, the submit path must leave provider/engine IDs and
/// resource reservations intact for that owner to release exactly once.
final class EngineV2RetirementTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var transferred = false

    func claim() -> Bool {
        lock.withLock {
            guard !transferred else { return false }
            transferred = true
            return true
        }
    }

    var isClaimed: Bool {
        lock.withLock { transferred }
    }
}

extension EngineV2Bridge {
    /// Build the caller-owned policy passed into the engine's atomic
    /// projection. This runs immediately before submission, after every SSD
    /// and shared-KV suspension. The absolute monotonic instant is carried
    /// unchanged; only the engine queue reads "now" for the final verdict.
    func firstTokenDeadlineAdmission(
        deadline: FirstContentDeadline?,
        isMultimodal: Bool,
        requestID: String? = nil, promptTokens: Int = 0, promptWork: PromptWork? = nil
    ) -> CBv2FirstTokenDeadlineAdmission? {
        guard !isMultimodal else { return nil }
        return targetFirstTokenDeadlineAdmission(
            deadline: deadline, requestID: requestID,
            promptTokens: promptTokens, promptWork: promptWork)
    }

    /// Only the opaque SDK seal plus this bridge's real published native
    /// profile can make already-prepared causal media target-projectable.
    /// Raw/other media retain the legacy refusal/bypass policy. The SDK still
    /// revalidates the seal's exact engine, generation, owner and one-shot use.
    func firstTokenDeadlineAdmission(
        deadline: FirstContentDeadline?,
        multimodal: CBv2MultimodalInput?,
        requestID: String? = nil, promptTokens: Int = 0, promptWork: PromptWork? = nil
    ) throws -> CBv2FirstTokenDeadlineAdmission? {
        guard let admission = targetFirstTokenDeadlineAdmission(
            deadline: deadline, requestID: requestID,
            promptTokens: promptTokens, promptWork: promptWork) else { return nil }
        guard let multimodal else { return admission }
        guard multimodal.nativeMediaToken != nil, multimodal.attention == .causal,
              multimodal.positionState == nil, multimodal.deepstackEmbeddings == nil else { return nil }
        // A stale/foreign/missing capability is an actual veto, never a nil
        // fallback to ordinary submission after identifying a native seal.
        _ = try nativeMiMoDecodedMediaBinding()
        return admission
    }

    private func targetFirstTokenDeadlineAdmission(
        deadline: FirstContentDeadline?,
        requestID: String?, promptTokens: Int, promptWork: PromptWork?
    ) -> CBv2FirstTokenDeadlineAdmission? {
        guard prefillDeadlineMode == .enforce,
            prefillDeadlineProjectionEnabled,
            let deadline
        else {
            return nil
        }

        // Use observed phase rates directly. The engine still prices its
        // actual queue/cache work against the original absolute deadline;
        // optional reviewed calibration supplies only measured error bounds.
        let expired = supportsPrefillRecoveryRetirement && isolatedPrefillEvidenceExpired()
        if expired, let requestID, prefillEvidenceRecovery.owner == requestID,
            prefillEvidenceRecovery.evidenceGuard?.isValid == true {
            // One bounded idle exploration uses the existing unmeasured-rate
            // path, retaining absolute expiry, physical capacity and retirement.
            // Never present a fabricated hardware/fleet rate as local evidence.
            return nil
        }
        var prefillRate = isolatedPrefillEwmaInitialized
            && isolatedPrefillTpsEwma.isFinite && isolatedPrefillTpsEwma > 0
            ? isolatedPrefillTpsEwma : nil
        if promptTokens > 0, let shapeRate = performanceMeasurements.freshIsolatedPrefillRate(promptTokens: promptTokens) {
            prefillRate = prefillRate.map { min($0, shapeRate) } ?? shapeRate
        }
        let decodeRate =
            ewmaInitialized && observedDecodeTpsEwma.isFinite && observedDecodeTpsEwma > 0
            ? observedDecodeTpsEwma
            : nil
        let calibration = requestID.flatMap {
            calibratedDeadlinePolicy(requestID: $0, promptTokens: promptTokens, promptWork: promptWork)
        }
        guard prefillRate != nil || calibration != nil else { return nil }

        return CBv2FirstTokenDeadlineAdmission(
            deadline: deadline.instant,
            conservativePrefillTokensPerSecond: prefillRate,
            conservativeDecodeTokensPerSecond: decodeRate,
            calibration: calibration)
    }

    /// Move post-commit cancellation cleanup out of the cancelling task. The
    /// retained IDs block provider- and engine-ID reuse while the background
    /// owner holds every pre-submit reservation through actual engine
    /// retirement. A permanent engine wedge therefore retains capacity (safe)
    /// without synchronously deadlocking cancellation.
    func transferPreSubmitRetirement(
        _ transfer: EngineV2RetirementTransfer,
        requestID: String,
        engineID: CBv2RequestID,
        stream: AsyncStream<CBv2Event>,
        retirement: CBv2RequestRetirement,
        prefillReceipt: EnginePrefillReceipt,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) {
        guard transfer.claim() else { return }
        prefillReceipt.retainUntilRetirement()
        let bridge = self
        let nativeTaskID = tracksNativeShutdown ? UUID() : nil
        let task = Task {
            // Admission can commit and generate tokens before submit resumes.
            // No active row or client pump exists on this path, so this owner
            // reconciles work without publishing output or billable usage.
            let completion = await Self.transferredGenerationWork(in: stream)
            await retirement.wait()
            prefillReceipt.endAfterRetirement()
            withExtendedLifetime(stream) {}
            await bridge.completeTransferredPreSubmitRetirement(
                requestID: requestID,
                engineID: engineID,
                completion: completion,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                prefillReceipt: prefillReceipt,
                usageSignal: usageSignal,
                failure: failure)
            if let nativeTaskID { await bridge.clearNativeTransferredRetirement(nativeTaskID) }
        }
        if let nativeTaskID {
            nativeTransferredRetirementTasks[nativeTaskID] = task
            if nativeShutdownClosed { nativeShutdownTasks.append(task) }
        }
    }

    private func clearNativeTransferredRetirement(_ id: UUID) {
        nativeTransferredRetirementTasks.removeValue(forKey: id)
    }

    private func completeTransferredPreSubmitRetirement(
        requestID: String,
        engineID: CBv2RequestID,
        completion: Int,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        prefillReceipt: EnginePrefillReceipt,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) async {
        consumePrefillReceipt(id: requestID, receipt: prefillReceipt)
        recordGenerationWork(completion: completion, requestID: requestID)
        await releasePreSubmitResources(
            requestID: requestID,
            sharedKVReserved: sharedKVReserved,
            prefixCacheReceiptID: prefixCacheReceiptID,
            ssdStaged: ssdStaged,
            readyReceiptRegistered: readyReceiptRegistered,
            usageSignal: usageSignal,
            failure: failure)
        releaseServiceAllowance(requestID: requestID)
        pendingSubmissionIDs.remove(requestID)
        pendingCancellationIDs.remove(requestID)
        pendingProfiles.removeValue(forKey: requestID)
        pendingEngineIDs.remove(engineID)
        if active[requestID] == nil, idMap[requestID] == engineID {
            idMap.removeValue(forKey: requestID)
        }
    }

    /// Enforce absolute expiry independently from projection mode and balance
    /// every resource acquired before this boundary.
    func checkFirstContentDeadline(
        _ deadline: FirstContentDeadline?,
        requestID: String,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?
    ) async throws {
        if pendingCancellationIDs.contains(requestID) {
            pendingProfiles[requestID]?.observeDeadlineDecision(.cancelled, deadline: deadline)
            // Refused before the engine ever sees the row: nothing was
            // generated after the cancel, so the profile records an explicit
            // `tokens_after_cancel = 0` (baseline seeded by `latchPendingCancel`).
            recordCancelledBeforeGeneration(pendingProfiles[requestID])
            await releasePreSubmitResources(
                requestID: requestID,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .policy)
            throw CancellationError()
        }
        do {
            try deadline?.check()
        } catch let failure as PreContentDeadlineFailure {
            pendingProfiles[requestID]?.observeDeadlineDecision(
                .expiredBeforeSubmit, deadline: deadline)
            await releasePreSubmitResources(
                requestID: requestID,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: .capacity)
            throw failure
        }
    }

    /// Balance every provider-owned resource acquired before engine
    /// submission. Engine-owned prefix/KV state is released atomically by the
    /// deadline API before it returns a rejection.
    func releasePreSubmitResources(
        requestID: String,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) async {
        if sharedKVReserved {
            await kvBudget?.release(requestID: requestID)
        }
        if let prefixCacheReceiptID {
            residentPrefixCacheEvidence?.discard(receiptID: prefixCacheReceiptID)
            if ssdStaged {
                await abandonPrefixStaging(requestID: prefixCacheReceiptID)
            }
            if readyReceiptRegistered {
                discardPrefixReadyReceipt(requestID: prefixCacheReceiptID)
            }
        }
        usageSignal?.finalizeLookup(
            failure: failure,
            fallbackTier: prefixCacheFallbackTier)
    }

    func reserveSharedRequestBytes(
        budget: GlobalKVCacheBudget, requestID: String, tokenCount: Int,
        nativeBytes: Int? = nil,
        profile: RequestProfileBuilder? = nil
    ) async -> Bool {
        guard let total = nativeBytes ?? requestReservationBytes(tokenCount: tokenCount), total > 0 else {
            return false
        }
        // Profiler `kv_reserve_us`: the shared-budget actor hop (accumulates
        // across the SSD-abandon retry).
        let reserveStart = SuspendingClock.now
        let reserved = await budget.reserveBytes(requestID: requestID, bytes: UInt64(total))
        profile?.markDuration(.kvReserve, start: reserveStart)
        return reserved
    }

    func requestReservationBytes(tokenCount: Int) -> Int? {
        guard tokenCount >= 0 else { return nil }
        let targetRate = max(0, kvBytesPerToken - auxiliaryBytesPerToken)
        let (targetBytes, targetOverflow) = targetRate.multipliedReportingOverflow(
            by: tokenCount)
        let (paddedTokens, paddingOverflow) = tokenCount.addingReportingOverflow(
            auxiliaryTokenAllocationPadding)
        guard !targetOverflow, !paddingOverflow else { return nil }
        let auxiliaryTokens: Int
        if auxiliaryBytesPerToken == 0 || paddedTokens == 0 {
            auxiliaryTokens = 0
        } else {
            let (bumped, bumpOverflow) = paddedTokens.addingReportingOverflow(
                auxiliaryTokenGranularity - 1)
            guard !bumpOverflow else { return nil }
            auxiliaryTokens = (bumped / auxiliaryTokenGranularity)
                * auxiliaryTokenGranularity
        }
        let (auxiliaryBytes, auxiliaryOverflow) = auxiliaryBytesPerToken
            .multipliedReportingOverflow(by: auxiliaryTokens)
        guard !auxiliaryOverflow else { return nil }
        let (variableBytes, variableOverflow) = targetBytes.addingReportingOverflow(
            auxiliaryBytes)
        let (total, totalOverflow) = variableBytes.addingReportingOverflow(fixedRequestBytes)
        return variableOverflow || totalOverflow ? nil : total
    }

    func maximumRequestOverheadBytes() -> Int? {
        let (extraAuxiliaryTokens, tokenOverflow) = (auxiliaryTokenGranularity - 1)
            .addingReportingOverflow(auxiliaryTokenAllocationPadding)
        guard !tokenOverflow else { return nil }
        let (auxiliaryOverhead, auxiliaryOverflow) = auxiliaryBytesPerToken
            .multipliedReportingOverflow(by: max(0, extraAuxiliaryTokens))
        let (total, totalOverflow) = fixedRequestBytes.addingReportingOverflow(
            auxiliaryOverhead)
        return auxiliaryOverflow || totalOverflow ? nil : total
    }
}
