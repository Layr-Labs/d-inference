import Foundation

extension EngineV2Bridge {
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

    func effectiveServingConcurrency(allowExpansion: Bool) -> Int {
        let configured = performanceProfile != nil && !allowExpansion
            ? unqualifiedMaxConcurrentRequests : maxConcurrentRequests
        return memoryLimitedConcurrency(configured: configured)
    }

    func acquireServiceAllowance(requestID: String, serviceReservationID: String? = nil,
        serviceReservation: ServiceReservationLifetime? = nil,
        promptTokens: Int? = nil, maxOutputTokens: Int? = nil,
        qualifiedTextWork: Bool = true,
        allowExpansion: Bool? = nil) -> Bool {
        let effectiveProfile = currentPerformanceProfile(
            allowExpansion: allowExpansion ?? ServingPerformanceProfiles.postureAllowsExpansion)
        let effectiveDeadlineProfile = currentDeadlineProfile(
            allowQualifiedPosture: allowExpansion ?? ServingPerformanceProfiles.postureAllowsExpansion)
        if tracksNativeShutdown,
            activeRequestCount() >= effectiveServingConcurrency(
                allowExpansion: allowExpansion ?? ServingPerformanceProfiles.postureAllowsExpansion)
        {
            return false
        }
        if performanceProfile != nil && effectiveProfile == nil,
            active.count + pendingSubmissionIDs.count >= unqualifiedMaxConcurrentRequests {
            return false
        }
        return serviceBudget?.acquire(
            ownerID: serviceOwnerPrefix + ":" + requestID,
            concurrency: effectiveProfile?.wholeMacConcurrency
                ?? ServingPerformanceProfiles.legacyWholeMacConcurrency,
            serviceReservationID: serviceReservationID,
            serviceReservation: serviceReservation,
            work: promptTokens.flatMap { prompt in maxOutputTokens.map { output in
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
            } }, deadlineApplicability: effectiveDeadlineProfile?.applicability) ?? true
    }

    /// Call only at refused pre-submit cleanup or completed engine retirement.
    /// The stream's terminal alone does not prove device resources retired.
    func releaseServiceAllowance(requestID: String) {
        if nativeMediaBootstrapRequestID == requestID {
            if nativeMediaBootstrapLearned { nextNativeMediaBootstrapAt = nil }
            nativeMediaBootstrapRequestID = nil
            nativeMediaBootstrapLearned = false
        }
        serviceBudget?.release(ownerID: serviceOwnerPrefix + ":" + requestID)
    }
}
