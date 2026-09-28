import Foundation

extension EngineV2Bridge {
    var currentPerformanceProfile: ServingPerformanceProfile? {
        ServingPerformanceProfiles.postureAllowsExpansion ? performanceProfile : nil
    }

    var effectiveServingConcurrency: Int {
        performanceProfile != nil && !ServingPerformanceProfiles.postureAllowsExpansion
            ? unqualifiedMaxConcurrentRequests : maxConcurrentRequests
    }

    func acquireServiceAllowance(requestID: String) -> Bool {
        let effectiveProfile = currentPerformanceProfile
        if performanceProfile != nil && effectiveProfile == nil,
            active.count + pendingSubmissionIDs.count >= unqualifiedMaxConcurrentRequests {
            return false
        }
        return serviceBudget?.acquire(
            ownerID: serviceOwnerPrefix + ":" + requestID,
            concurrency: effectiveProfile?.wholeMacConcurrency
                ?? ServingPerformanceProfiles.legacyWholeMacConcurrency) ?? true
    }

    /// Call only at refused pre-submit cleanup or completed engine retirement.
    /// The stream's terminal alone does not prove device resources retired.
    func releaseServiceAllowance(requestID: String) {
        serviceBudget?.release(ownerID: serviceOwnerPrefix + ":" + requestID)
    }
}
