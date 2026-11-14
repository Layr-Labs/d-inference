import Foundation

extension EngineV2Bridge {
    /// Capacity refusal of a Mac whose serving concurrency is full; thrown
    /// before any stream exists (503 locally, retriable capacity upstream).
    static let serviceAllowanceExhausted = "token_budget_exhausted: whole-Mac service allowance exhausted"
    /// Capacity refusal of a request whose wait for the idle calibration
    /// probe's retirement reached its bound (`IdleCalibrationCoordinator`).
    static let idleCalibrationRetirementOverdue =
        "token_budget_exhausted: the idle calibration probe did not retire"

    func retainDeadlinePostureMonitoring() {
        guard deadlineProfile != nil || nativeTransactionID != nil,
            deadlinePostureMonitoring == nil else { return }
        deadlinePostureMonitoring = DeadlinePostureMonitor.shared.acquire()
    }

    var currentPerformanceProfile: ServingPerformanceProfile? {
        currentPerformanceProfile(allowExpansion: ServingPerformanceProfiles.postureAllowsExpansion)
    }

    func currentPerformanceProfile(allowExpansion: Bool) -> ServingPerformanceProfile? {
        allowExpansion ? performanceProfile : nil
    }

    var currentDeadlineProfile: DeadlinePerformanceProfile? {
        guard let profile = currentDeadlineProfile(allowQualifiedPosture: ServingPerformanceProfiles.postureAllowsExpansion),
            serviceBudget?.deadlineEligibleForAdvertisement(profile.applicability) == true else { return nil }
        return profile
    }

    func currentDeadlineProfile(allowQualifiedPosture: Bool) -> DeadlinePerformanceProfile? {
        allowQualifiedPosture ? deadlineProfile : nil
    }

    var effectiveServingConcurrency: Int {
        effectiveServingConcurrency(allowExpansion: ServingPerformanceProfiles.postureAllowsExpansion)
    }

    /// Reviewed profiles and any width above the unqualified width (the
    /// automatic M5 paged default) need nominal power and thermal posture;
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
        let expansionAllowed = allowExpansion ?? ServingPerformanceProfiles.postureAllowsExpansion
        let effectiveProfile = currentPerformanceProfile(allowExpansion: expansionAllowed)
        let effectiveDeadlineProfile = currentDeadlineProfile(allowQualifiedPosture: expansionAllowed)
        // A suspended submission already owns its allowance. Count its ID once
        // even while terminal handling also retains it in the active map.
        let pendingOnlyCount = pendingSubmissionIDs.count(where: { active[$0] == nil })
        if usesMemoryLimitedConcurrency, !takesStoppedRowPlace {
            let occupiedConcurrency = max(activeRequestCount(), active.count + pendingOnlyCount)
            if occupiedConcurrency >= effectiveServingConcurrency(allowExpansion: expansionAllowed) {
                return false
            }
        }
        // The same once-per-ID count: a local stream holding its head
        // (`holdHeadUntilAdmitted`) is in both sets until its submit returns.
        if hasPostureGatedWidth, !expansionAllowed, !takesStoppedRowPlace,
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
        cancelledRowsAwaitingRelease.remove(requestID)
        serviceBudget?.release(ownerID: serviceOwnerPrefix + ":" + requestID)
    }

    /// For a capacity refusal that a cancelled row's release would admit. A
    /// row whose client went away keeps its slot, its whole-Mac share and its
    /// KV until the engine drops it at its next step and its pump releases
    /// them (`EngineV2Bridge+Events`); work that arrives meanwhile on a full
    /// Mac was refused for a slot already being freed. Waits for one such
    /// row's release, at most `CancelledRowAdmissionWait.bound`: false when
    /// none is draining, the switch is off, or the bound passes first. The
    /// caller then asks again, so nothing is admitted before an actual release.
    func waitForCancelledRowRelease() async -> Bool {
        guard waitsForCancelledRows else { return false }
        // Only rows that still hold something; a stale entry is never waited on.
        cancelledRowsAwaitingRelease = cancelledRowsAwaitingRelease.filter {
            active[$0] != nil || pendingSubmissionIDs.contains($0) || pumpTasks[$0] != nil
        }
        guard let row = cancelledRowsAwaitingRelease.first else { return false }
        return await waitForRowRelease(requestId: row, within: CancelledRowAdmissionWait.bound)
    }
}

/// Whether a capacity refusal first waits for a cancelled row's release
/// (`EngineV2Bridge.waitForCancelledRowRelease`). On by default for every
/// model: it only delays a refusal while a cancelled row is retiring, and
/// admits nothing before the release.
///
/// `DARKBLOOM_CANCELLED_ROW_ADMISSION_WAIT`: `0`, `off` or `false` refuses at
/// once, as before.
enum CancelledRowAdmissionWait {
    static let environmentKey = "DARKBLOOM_CANCELLED_ROW_ADMISSION_WAIT"
    /// A decode step at full width and the pump's cleanup usually take well
    /// under a second (Muse Glimmer at 8 rows: about 50 ms a step); past this
    /// the row may be wedged, and the request is refused.
    static let bound: Duration = .seconds(2)
    static let current = enabled(environment: ProcessInfo.processInfo.environment)

    static func enabled(environment: [String: String]) -> Bool {
        let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !["0", "off", "false"].contains(raw ?? "")
    }
}
