import Foundation

extension EngineV2Bridge {
    /// Capacity refusal of a Mac whose serving concurrency is full; thrown
    /// before any stream exists (503 locally, retriable capacity upstream).
    static let serviceAllowanceExhausted = "token_budget_exhausted: whole-Mac service allowance exhausted"
    /// Capacity refusal of a request whose wait for the idle calibration
    /// probe's retirement reached its bound (`IdleCalibrationCoordinator`).
    static let idleCalibrationRetirementOverdue =
        "token_budget_exhausted: the idle calibration probe did not retire"
    /// How a contiguous slot's capacity refusal ends when the shared KV budget
    /// can't hold the request's reservation now.
    static let sharedKVNoHeadroom = "but the shared KV budget has no headroom"

    func retainDeadlinePostureMonitoring() {
        guard deadlineProfile != nil || nativeTransactionID != nil,
            deadlinePostureMonitoring == nil else { return }
        deadlinePostureMonitoring = DeadlinePostureMonitor.shared.acquire()
    }

    /// `ServingPerformanceProfiles.postureAllowsExpansion` (nominal, Low Power
    /// Mode off) at the bridge's `servingPosture`.
    var postureAllowsExpansion: Bool {
        let posture = servingPosture()
        return ServingPerformanceProfiles.postureAllowsExpansion(
            lowPowerMode: posture.lowPowerMode, thermalState: posture.thermalState)
    }

    var currentPerformanceProfile: ServingPerformanceProfile? {
        currentPerformanceProfile(allowExpansion: postureAllowsExpansion)
    }

    func currentPerformanceProfile(allowExpansion: Bool) -> ServingPerformanceProfile? {
        allowExpansion ? performanceProfile : nil
    }

    var currentDeadlineProfile: DeadlinePerformanceProfile? {
        guard let profile = currentDeadlineProfile(allowQualifiedPosture: postureAllowsExpansion),
            serviceBudget?.deadlineEligibleForAdvertisement(profile.applicability) == true else { return nil }
        return profile
    }

    func currentDeadlineProfile(allowQualifiedPosture: Bool) -> DeadlinePerformanceProfile? {
        allowQualifiedPosture ? deadlineProfile : nil
    }

    var effectiveServingConcurrency: Int {
        effectiveServingConcurrency(allowExpansion: widthPostureAllowsExpansion)
    }

    /// The posture the width needs: a reviewed profile's width needs nominal
    /// (`postureAllowsExpansion`); the automatic width holds at fair too
    /// (`postureAllowsAutomaticWidth`).
    var widthPostureAllowsExpansion: Bool {
        let posture = servingPosture()
        return performanceProfile == nil
            ? ServingPerformanceProfiles.postureAllowsAutomaticWidth(
                lowPowerMode: posture.lowPowerMode, thermalState: posture.thermalState)
            : ServingPerformanceProfiles.postureAllowsExpansion(
                lowPowerMode: posture.lowPowerMode, thermalState: posture.thermalState)
    }

    /// Reviewed profiles and any width above the unqualified width (the
    /// automatic M5 paged default) need their posture (`widthPostureAllowsExpansion`);
    /// otherwise admission falls back to the unqualified width.
    var hasPostureGatedWidth: Bool {
        performanceProfile != nil || maxConcurrentRequests > unqualifiedMaxConcurrentRequests
    }

    func effectiveServingConcurrency(allowExpansion: Bool) -> Int {
        let configured = hasPostureGatedWidth && !allowExpansion
            ? unqualifiedMaxConcurrentRequests : maxConcurrentRequests
        return memoryLimitedConcurrency(configured: configured)
    }

    /// `takesStoppedRowPlace`: a loop exit's continuation (`EngineAdmissionPriority` above 0). Its stopped row's
    /// slot was released before it asks, and on a full Mac work waiting for a slot takes it first, so a width check
    /// would refuse the answer of a request already served. It is never refused for width: each continuation may
    /// exceed it by one row until it ends, at most one per stopped row (other work waits meanwhile), and the engine
    /// admits it first. Only the idle prefill-evidence recovery, before its prompt completes, keeps it out
    /// (`WholeMacServiceBudget.acquire(overcommit:)`).
    func acquireServiceAllowance(requestID: String, serviceReservationID: String? = nil,
        serviceReservation: ServiceReservationLifetime? = nil,
        promptTokens: Int? = nil, maxOutputTokens: Int? = nil,
        qualifiedTextWork: Bool = true,
        recoverPrefillEvidence: Bool = false,
        allowExpansion: Bool? = nil,
        takesStoppedRowPlace: Bool = false) -> Bool {
        let expansionAllowed = allowExpansion ?? postureAllowsExpansion
        // An explicit `allowExpansion` decides both; by default the width
        // follows its own posture (fair keeps the automatic width).
        let widthExpansionAllowed = allowExpansion ?? widthPostureAllowsExpansion
        let effectiveProfile = currentPerformanceProfile(allowExpansion: expansionAllowed)
        let effectiveDeadlineProfile = currentDeadlineProfile(allowQualifiedPosture: expansionAllowed)
        // A suspended submission already owns its allowance. Count its ID once
        // even while terminal handling also retains it in the active map.
        let pendingOnlyCount = pendingSubmissionIDs.count(where: { active[$0] == nil })
        if usesMemoryLimitedConcurrency, !takesStoppedRowPlace {
            let occupiedConcurrency = max(activeRequestCount(), active.count + pendingOnlyCount)
            if occupiedConcurrency >= effectiveServingConcurrency(allowExpansion: widthExpansionAllowed) {
                return false
            }
        }
        // The same once-per-ID count: a local request holding its head
        // (`holdHeadUntilAdmitted`) is in both sets until its submit returns.
        if hasPostureGatedWidth, !widthExpansionAllowed, !takesStoppedRowPlace,
            active.count + pendingOnlyCount >= unqualifiedMaxConcurrentRequests {
            return false
        }
        let work: WholeMacServiceBudget.Work? = promptTokens.flatMap { prompt in maxOutputTokens.map { output in
                // Ownership starts before asynchronous submission validation.
                // Another model may observe this lease during that interval;
                // only work within its own profile's full context envelope
                // can provide qualified competing-work evidence. Subtraction
                // also rejects overflowing prompt/output sums without adding.
                let profileID: String?
                if qualifiedTextWork, let profile = effectiveDeadlineProfile, prompt > 0, output >= 0,
                    prompt <= profile.configuredContextTokens,
                    output <= profile.configuredContextTokens - prompt {
                    profileID = profile.id
                } else {
                    profileID = nil
                }
                return .init(modelID: modelId, profileID: profileID,
                    promptTokens: prompt, maxOutputTokens: output,
                    calibratedContextTokensMax: effectiveDeadlineProfile?.calibratedContextTokensMax ?? 0)
            } }
        let ownerID = serviceOwnerPrefix + ":" + requestID
        if recoverPrefillEvidence, let serviceBudget,
            serviceBudget.acquire(ownerID: ownerID, concurrency: 1,
                serviceReservationID: serviceReservationID, serviceReservation: serviceReservation,
                work: work, requiresIdle: true) {
            prefillEvidenceRecovery.acquire(requestID, evidenceGuard: nil,
                servingConcurrency: effectiveProfile?.wholeMacConcurrency
                    ?? ServingPerformanceProfiles.legacyWholeMacConcurrency)
            return true
        }
        // Losing the idle race only withdraws exploration. Ordinary serving
        // keeps its normal allowance and predictive admission on a busy Mac.
        return serviceBudget?.acquire(ownerID: ownerID,
            concurrency: effectiveProfile?.wholeMacConcurrency ?? ServingPerformanceProfiles.legacyWholeMacConcurrency,
            serviceReservationID: serviceReservationID, serviceReservation: serviceReservation,
            work: work, deadlineApplicability: effectiveDeadlineProfile?.applicability,
            overcommit: takesStoppedRowPlace) ?? true
    }

    /// The serving share a text prompt holds while it is rendered and
    /// tokenized, under the owner ID its submission's allowance takes over
    /// (`WholeMacServiceBudget.acquirePreparation`). A full Mac refuses as
    /// capacity, as at submission. Nil: no shared budget, or the owner's
    /// request, which waits for room at submission (`OwnerMemoryWait`).
    func acquirePromptPreparation(requestID: String,
        firstContentDeadline: FirstContentDeadline?) throws -> PromptPreparationShare? {
        guard let serviceBudget, OwnerMemoryWait.current == nil
            || !OwnerMemoryWait.servesOwnerRequest(firstContentDeadline: firstContentDeadline) else { return nil }
        let ownerID = serviceOwnerPrefix + ":" + requestID
        guard serviceBudget.acquirePreparation(ownerID: ownerID,
            concurrency: currentPerformanceProfile?.wholeMacConcurrency
                ?? ServingPerformanceProfiles.legacyWholeMacConcurrency,
            overcommit: EngineAdmissionPriority.current > 0) else {
            throw MultiModelBatchSchedulerEngineError.tokenBudgetExhausted(Self.serviceAllowanceExhausted)
        }
        return PromptPreparationShare(budget: serviceBudget, ownerID: ownerID)
    }

    /// Call only at refused pre-submit cleanup or completed engine retirement.
    /// The stream's terminal alone does not prove device resources retired.
    func releaseServiceAllowance(requestID: String) {
        if let (lifetime, key) = qwenMediaHostResources.removeValue(forKey: requestID) {
            lifetime.nativeDidRetire(key)
        }
        prefillEvidenceRecovery.retire(requestID)
        if nativeMediaLearnedRequestIDs.remove(requestID) != nil {
            nextNativeMediaBootstrapAt = nil
        }
        if nativeMediaBootstrapRequestID == requestID {
            nativeMediaBootstrapRequestID = nil
        }
        serviceBudget?.release(ownerID: serviceOwnerPrefix + ":" + requestID)
    }
}

/// A prompt preparation's serving share (`EngineV2Bridge.acquirePromptPreparation`).
/// `end` drops it unless the submission's allowance already took it over.
struct PromptPreparationShare: Sendable {
    let budget: WholeMacServiceBudget
    let ownerID: String

    func end() { budget.releasePreparation(ownerID: ownerID) }
}
