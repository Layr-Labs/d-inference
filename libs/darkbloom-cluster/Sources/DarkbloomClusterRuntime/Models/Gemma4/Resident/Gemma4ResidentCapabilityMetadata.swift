import DarkbloomClusterProtocol
import Foundation

/// Pure metadata from the same registered specification, profile and Plan
/// constructors live admission uses. No checkpoint payload or GPU is read. The
/// binary hash is a caller binding. Nothing here proves loaded code, physical
/// readiness, available memory or numerical qualification.
public enum Gemma4ResidentCapabilityMetadata {
    /// Whether these configuration bytes belong to a registered Gemma artifact.
    public static func isRegistered(configuration: Data) -> Bool {
        Gemma4RegisteredSpecification.isRegistered(configuration: configuration)
    }

    public static func describe(configuration: Data, manifest: Data,
                                runtimeBinarySHA256: String) throws -> ClusterRuntimeCapability {
        guard qwenStageWireIsSHA256(runtimeBinarySHA256),
              let spec = try? Gemma4RegisteredSpecification.registered(configuration: configuration,
                                                                      manifest: manifest) else {
            throw ProbeError("Capability metadata requires a registered Gemma configuration and its own manifest")
        }
        let profile = try Gemma4ResidentAdapterDefinition.profile(specification: spec)
        let partitions = try Gemma4ResidentAdapterDefinition.supportedCuts.map { cut -> ClusterRuntimePartition in
            let plan = try Gemma4LayerStagePlanning.plan(specification: spec, configuration: configuration, cut: cut)
            return ClusterRuntimePartition(planSHA256: plan.fingerprint, stages: plan.stages.map {
                ClusterRuntimeStage(rank: $0.index, sourceLayerStart: $0.sourceRange.lowerBound,
                    sourceLayerEnd: $0.sourceRange.upperBound, stagePlanSHA256: $0.fingerprint,
                    constructionConfigurationSHA256: sha256($0.constructionConfiguration))
            })
        }
        // The required source contract, not a claim about this process's environment.
        let arithmetic = try Gemma4ArithmeticEnvironment.admit(Gemma4ArithmeticEnvironment.requiredValues)
        let adapter = ClusterRuntimeAdapter.gemma4LayerStage
        return try ClusterRuntimeCapability(runtimeBinarySHA256: runtimeBinarySHA256,
            adapterID: adapter.rawValue, adapterVersion: adapter.version, runtimeModelID: spec.model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            manifestSHA256: spec.manifestSHA256,
            profile: .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens),
            profileFingerprint: profile.fingerprint, partitions: partitions,
            arithmeticPolicyID: Gemma4ArithmeticEnvironment.contract,
            arithmeticPolicySHA256: sha256(try canonicalJSONData(arithmetic)),
            maxLifetimeSeconds: Int(Gemma4ResidentAdapterDefinition.maximumLifetimeNanoseconds / 1_000_000_000),
            maxRequests: Gemma4ResidentAdapterDefinition.maximumRequests,
            supportedPrefillSchedules: Gemma4ResidentAdapterDefinition.supportedPrefillSchedules,
            supportedGenerationModes: Gemma4ResidentAdapterDefinition.supportedGenerationModes)
    }
}
