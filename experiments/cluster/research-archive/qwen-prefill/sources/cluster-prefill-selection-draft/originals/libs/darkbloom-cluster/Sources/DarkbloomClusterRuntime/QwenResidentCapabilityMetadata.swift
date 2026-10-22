import DarkbloomClusterProtocol
import Foundation

/// Pure metadata from the same registered specification, profile and Plan
/// constructors used by live admission. No checkpoint payload or GPU is read.
/// The binary hash is a caller binding; the worker command verifies its installed
/// executable bytes before calling this function. Neither proves loaded code,
/// libraries, physical readiness, available memory or numerical qualification.
public enum QwenResidentCapabilityMetadata {
    public static func describe(configuration: Data, manifest: Data,
                                runtimeBinarySHA256: String) throws -> ClusterRuntimeCapability {
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count),
              qwenStageWireIsSHA256(runtimeBinarySHA256),
              let spec = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen35NineB }),
              sha256(configuration) == spec.configurationSHA256, sha256(manifest) == spec.manifestSHA256 else {
            throw ProbeError("Capability metadata requires the exact registered 9B configuration and manifest")
        }
        let profile = try QwenResidentAdapterDefinition.profile(specification: spec)
        let partitions = try QwenResidentAdapterDefinition.supportedCuts.map { cut -> ClusterRuntimePartition in
            let plan = try QwenLayerStagePlan(configuration: configuration,
                ranges: [0..<cut, cut..<spec.layers], activeMTP: false)
            return ClusterRuntimePartition(planSHA256: plan.fingerprint, stages: plan.stages.map {
                ClusterRuntimeStage(rank: $0.index, sourceLayerStart: $0.sourceRange.lowerBound,
                    sourceLayerEnd: $0.sourceRange.upperBound, stagePlanSHA256: $0.fingerprint,
                    constructionConfigurationSHA256: sha256($0.constructionConfiguration))
            })
        }
        // Describe the required source contract. This is not a claim that the
        // current process environment or an installed native library was admitted.
        let arithmetic = try QwenLongPrefillArithmeticEnvironment.admit(QwenLongPrefillArithmeticEnvironment.requiredValues)
        let adapter = ClusterRuntimeAdapter.qwen35Dense
        return try ClusterRuntimeCapability(runtimeBinarySHA256: runtimeBinarySHA256,
            adapterID: adapter.rawValue, adapterVersion: adapter.version, runtimeModelID: spec.model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            manifestSHA256: spec.manifestSHA256,
            profile: .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens),
            profileFingerprint: profile.fingerprint, partitions: partitions,
            arithmeticPolicyID: QwenLongPrefillArithmeticEnvironment.contract,
            arithmeticPolicySHA256: sha256(try canonicalJSONData(arithmetic)),
            maxLifetimeSeconds: Int(QwenResidentAdapterDefinition.maximumLifetimeNanoseconds / 1_000_000_000),
            maxRequests: QwenResidentAdapterDefinition.maximumRequests)
    }
}
