import Foundation

extension EngineV2Bridge {
    var currentPerformanceProfile: ServingPerformanceProfile? {
        currentPerformanceProfile(allowExpansion: ServingPerformanceProfiles.postureAllowsExpansion)
    }

    func currentPerformanceProfile(allowExpansion: Bool) -> ServingPerformanceProfile? {
        allowExpansion ? performanceProfile : nil
    }

    var effectiveServingConcurrency: Int {
        effectiveServingConcurrency(allowExpansion: ServingPerformanceProfiles.postureAllowsExpansion)
    }

    func effectiveServingConcurrency(allowExpansion: Bool) -> Int {
        performanceProfile != nil && !allowExpansion
            ? unqualifiedMaxConcurrentRequests : maxConcurrentRequests
    }

    func acquireServiceAllowance(requestID: String, serviceReservationID: String? = nil,
        allowExpansion: Bool? = nil) -> Bool {
        let effectiveProfile = currentPerformanceProfile(
            allowExpansion: allowExpansion ?? ServingPerformanceProfiles.postureAllowsExpansion)
        if performanceProfile != nil && effectiveProfile == nil,
            active.count + pendingSubmissionIDs.count >= unqualifiedMaxConcurrentRequests {
            return false
        }
        return serviceBudget?.acquire(
            ownerID: serviceOwnerPrefix + ":" + requestID,
            concurrency: effectiveProfile?.wholeMacConcurrency
                ?? ServingPerformanceProfiles.legacyWholeMacConcurrency,
            serviceReservationID: serviceReservationID) ?? true
    }

    /// Call only at refused pre-submit cleanup or completed engine retirement.
    /// The stream's terminal alone does not prove device resources retired.
    func releaseServiceAllowance(requestID: String) {
        serviceBudget?.release(ownerID: serviceOwnerPrefix + ":" + requestID)
    }
}
