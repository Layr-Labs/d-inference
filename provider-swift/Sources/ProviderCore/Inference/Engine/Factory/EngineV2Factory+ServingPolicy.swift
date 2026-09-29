import Foundation
import MLXLMCommon

extension EngineV2Factory {
    private static let profileHardware = try? HardwareDetector.detect()

    /// Shared by generic and native-owned backends after the backend is resolved.
    /// Benchmark construction retains its requested width; serving qualification
    /// remains bound to the actual artifact, hardware, context and MTP posture.
    static func productionServingPolicy(
        model: (any LanguageModel)?, modelID: String?, modelArtifactSHA256: String?,
        constructionPurpose: ConstructionPurpose, automaticallySelectConcurrency: Bool,
        performanceQualificationAllowed: Bool, backend: EngineV2KVBackendKind,
        maxContextLength: Int?, maxConcurrentRequests: Int, environment: [String: String],
        mtpPerformanceConfiguration: ServingMTPConfiguration? = nil
    ) -> (scheduler: CBv2SchedulerConfig, performanceProfile: ServingPerformanceProfile?) {
        let profile = constructionPurpose == .serving && performanceQualificationAllowed
            ? ServingPerformanceProfiles.resolve(
                modelID: modelID ?? "", artifactSHA256: modelArtifactSHA256,
                kvBackend: backend.rawValue, contextTokens: maxContextLength,
                hardware: ServingPerformanceProfiles.reviewed.isEmpty ? nil : Self.profileHardware,
                environment: environment, mtp: mtpPerformanceConfiguration) : nil
        let concurrency = constructionPurpose == .benchmark ? max(1, maxConcurrentRequests)
            : ServingPerformanceProfiles.concurrency(
                configured: UInt64(max(1, automaticallySelectConcurrency
                    ? profile?.maxConcurrency ?? maxConcurrentRequests : maxConcurrentRequests)),
                profile: profile)
        return (productionSchedulerConfig(
            maxConcurrentRequests: concurrency, model: model, modelID: modelID,
            performanceProfile: profile, environment: environment), profile)
    }
}
