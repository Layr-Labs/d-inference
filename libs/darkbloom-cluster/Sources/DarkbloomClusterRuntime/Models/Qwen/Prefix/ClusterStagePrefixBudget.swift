import Foundation

/// A resident MiMo or GLM stage's prefix cache budget at load: half of the
/// admissible room left beside the largest admitted request's charge, at most
/// the cache's ceiling (`QwenStagePrefixCache.budget`), from one sample of the
/// host, as the dense runtime derives it.
enum ClusterStagePrefixBudget {
    static func roomBytes(chargeBytes: Int) throws -> Int {
        let sum = QwenLongPrefillCheckedBytes.sum
        let os = try QwenDenseStageLoadResources.observeOS()
        let native = QwenDenseStageLoadResources.observeNative()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try sum([chargeBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        let allocator = try sum([native.activeBytes, native.cacheBytes, chargeBytes,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        let decision = try QwenDenseStageLoadPolicy.decide(os, requiredBytes: free,
            purpose: "Resident stage prefix budget", now: DispatchTime.now().uptimeNanoseconds)
        return max(0, min(decision.admissibleBytes - decision.requiredBytes, native.allocatorLimitBytes - allocator))
    }
}
