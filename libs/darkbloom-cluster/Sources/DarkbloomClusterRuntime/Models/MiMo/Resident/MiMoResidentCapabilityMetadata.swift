import DarkbloomClusterProtocol
import Foundation

/// Pure metadata from the same registered specification, profile and Plan
/// constructors live admission uses. No checkpoint payload or GPU is read. The
/// binary hash is a caller binding. Nothing here proves loaded code, physical
/// readiness, available memory or numerical qualification.
public enum MiMoResidentCapabilityMetadata {
    public static func describe(configuration: Data, manifest: Data,
                                runtimeBinarySHA256: String) throws -> ClusterRuntimeCapability {
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count),
              qwenStageWireIsSHA256(runtimeBinarySHA256),
              let spec = try? MiMoRegisteredSpecification.specification(configuration: configuration),
              sha256(manifest) == spec.manifestSHA256 else {
            throw ProbeError("Capability metadata requires the exact registered MiMo configuration and manifest")
        }
        let profile = try spec.profile()
        let partitions = try spec.supportedCuts.map { cut -> ClusterRuntimePartition in
            let plan = try MiMoLayerStagePlan(configuration: configuration, cut: cut)
            return ClusterRuntimePartition(planSHA256: plan.fingerprint, stages: plan.stages.map {
                ClusterRuntimeStage(rank: $0.index, sourceLayerStart: $0.sourceRange.lowerBound,
                    sourceLayerEnd: $0.sourceRange.upperBound, stagePlanSHA256: $0.fingerprint,
                    constructionConfigurationSHA256: sha256($0.constructionConfiguration))
            })
        }
        // The required source contract, not a claim about this process.
        let arithmetic = try MiMoArithmeticEnvironment.admit(MiMoArithmeticEnvironment.requiredValues)
        let adapter = ClusterRuntimeAdapter.mimoV26LayerStage
        return try ClusterRuntimeCapability(runtimeBinarySHA256: runtimeBinarySHA256,
            adapterID: adapter.rawValue, adapterVersion: adapter.version, runtimeModelID: spec.model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            manifestSHA256: spec.manifestSHA256,
            profile: .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens),
            profileFingerprint: profile.fingerprint, partitions: partitions,
            arithmeticPolicyID: MiMoArithmeticEnvironment.contract,
            arithmeticPolicySHA256: sha256(try canonicalJSONData(arithmetic)),
            maxLifetimeSeconds: Int(MiMoRegisteredSpecification.maximumLifetimeNanoseconds / 1_000_000_000),
            maxRequests: MiMoRegisteredSpecification.maximumRequests,
            supportedPrefillSchedules: spec.supportedPrefillSchedules,
            supportedGenerationModes: spec.supportedGenerationModes)
    }
}
