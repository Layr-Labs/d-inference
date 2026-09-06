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
        isMultimodal: Bool
    ) -> CBv2FirstTokenDeadlineAdmission? {
        guard prefillDeadlineMode == .enforce,
            prefillDeadlineProjectionEnabled,
            !isMultimodal,
            let deadline,
            isolatedPrefillEwmaInitialized
        else {
            return nil
        }

        let prefillRate =
            isolatedPrefillTpsEwma * Self.deadlineProjectionRateHaircut
        let decodeCandidate =
            observedDecodeTpsEwma * Self.deadlineProjectionRateHaircut
        let decodeRate =
            ewmaInitialized && decodeCandidate.isFinite && decodeCandidate > 0
            ? decodeCandidate
            : nil
        guard prefillRate.isFinite, prefillRate > 0 else {
            return nil
        }

        return CBv2FirstTokenDeadlineAdmission(
            deadline: deadline.instant,
            conservativePrefillTokensPerSecond: prefillRate,
            conservativeDecodeTokensPerSecond: decodeRate)
    }

    func isIsolatedPrefillSubmitBoundary(
        currentProviderRequestID: String
    ) -> Bool {
        guard pendingEngineIDs.isEmpty else { return false }
        guard pendingSubmissionIDs.allSatisfy({ $0 == currentProviderRequestID }) else {
            return false
        }
        return active.isEmpty
    }

    /// A later arrival can share a step with an already-prefilling row. Mark
    /// that older sample non-isolated before submitting the newcomer; rows
    /// that already emitted their first token keep their completed prefill
    /// observation.
    func disqualifyOverlappedPrefillSamples() {
        for id in Array(active.keys) {
            guard var state = active[id], state.firstTokenAt == nil else {
                continue
            }
            state.isolatedPrefillSampleEligible = false
            active[id] = state
        }
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
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) {
        guard transfer.claim() else { return }
        let bridge = self
        Task {
            await retirement.wait()
            withExtendedLifetime(stream) {}
            await bridge.completeTransferredPreSubmitRetirement(
                requestID: requestID,
                engineID: engineID,
                sharedKVReserved: sharedKVReserved,
                prefixCacheReceiptID: prefixCacheReceiptID,
                ssdStaged: ssdStaged,
                readyReceiptRegistered: readyReceiptRegistered,
                usageSignal: usageSignal,
                failure: failure)
        }
    }

    private func completeTransferredPreSubmitRetirement(
        requestID: String,
        engineID: CBv2RequestID,
        sharedKVReserved: Bool,
        prefixCacheReceiptID: CBv2RequestID?,
        ssdStaged: Bool,
        readyReceiptRegistered: Bool,
        usageSignal: EngineV2RequestUsageSignal?,
        failure: PrefixCacheLookupFailureClass
    ) async {
        await releasePreSubmitResources(
            requestID: requestID,
            sharedKVReserved: sharedKVReserved,
            prefixCacheReceiptID: prefixCacheReceiptID,
            ssdStaged: ssdStaged,
            readyReceiptRegistered: readyReceiptRegistered,
            usageSignal: usageSignal,
            failure: failure)
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
        profile: RequestProfileBuilder? = nil
    ) async -> Bool {
        guard let total = requestReservationBytes(tokenCount: tokenCount), total > 0 else {
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
