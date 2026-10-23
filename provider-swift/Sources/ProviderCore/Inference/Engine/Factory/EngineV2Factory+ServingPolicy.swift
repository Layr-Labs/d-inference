import Foundation
import MLXLMCommon

extension EngineV2Factory {
    private static let profileHardware = try? HardwareDetector.detect()
    /// One sysctl. Full detection also runs system_profiler, which serving
    /// construction defers until a reviewed catalog actually needs it.
    static let servingChipIdentity: (family: ChipFamily, tier: ChipTier)? =
        (try? sysctlString("machdep.cpu.brand_string")).map { parseChipIdentity($0) }

    /// Shared by generic and native-owned backends after the backend is resolved.
    /// Benchmark construction retains its requested width; serving qualification
    /// remains bound to the actual artifact, hardware, context and MTP posture.
    static func productionServingPolicy(
        model: (any LanguageModel)?, modelID: String?, modelArtifactSHA256: String?,
        constructionPurpose: ConstructionPurpose, automaticallySelectConcurrency: Bool,
        performanceQualificationAllowed: Bool, backend: EngineV2KVBackendKind,
        maxContextLength: Int?, maxConcurrentRequests: Int, environment: [String: String],
        mtpPerformanceConfiguration: ServingMTPConfiguration? = nil,
        chipIdentity: (family: ChipFamily, tier: ChipTier)? = servingChipIdentity
    ) -> (scheduler: CBv2SchedulerConfig, performanceProfile: ServingPerformanceProfile?) {
        let profile = constructionPurpose == .serving && performanceQualificationAllowed
            ? ServingPerformanceProfiles.resolve(
                modelID: modelID ?? "", artifactSHA256: modelArtifactSHA256,
                kvBackend: backend.rawValue, contextTokens: maxContextLength,
                hardware: ServingPerformanceProfiles.reviewed.isEmpty ? nil : Self.profileHardware,
                environment: environment, mtp: mtpPerformanceConfiguration) : nil
        let automaticWidth = profile?.maxConcurrency ?? ServingPerformanceProfiles.automaticConcurrency(
            configured: maxConcurrentRequests, modelID: modelID, backend: backend,
            chipIdentity: chipIdentity)
        let concurrency = constructionPurpose == .benchmark ? max(1, maxConcurrentRequests)
            : ServingPerformanceProfiles.concurrency(
                configured: UInt64(max(1, automaticallySelectConcurrency
                    ? automaticWidth : maxConcurrentRequests)),
                profile: profile)
        return (productionSchedulerConfig(
            maxConcurrentRequests: concurrency, model: model, modelID: modelID,
            performanceProfile: profile, environment: environment), profile)
    }
}
