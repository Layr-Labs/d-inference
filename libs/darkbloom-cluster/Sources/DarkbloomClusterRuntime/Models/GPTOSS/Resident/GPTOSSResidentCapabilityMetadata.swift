import DarkbloomClusterProtocol
import Foundation

/// Pure metadata from the same registered specification, profile and Plan
/// constructors live admission uses. No checkpoint payload or GPU is read.
/// The binary hash is a caller binding; neither it nor this record proves
/// loaded code, physical readiness, available memory or numerical qualification.
public enum GPTOSSResidentCapabilityMetadata {
    static let adapter = ClusterRuntimeAdapter.gptossLayerStage

    public static func handles(configuration: Data) -> Bool {
        GPTOSSRegisteredSpecification.handles(configuration: configuration)
    }
    public static func handles(runtimeModelID: String) -> Bool {
        GPTOSSRegisteredSpecification.handles(runtimeModelID: runtimeModelID)
    }

    public static func describe(configuration: Data, manifest: Data,
                                runtimeBinarySHA256: String) throws -> ClusterRuntimeCapability {
        // The configuration bytes select the registered model; its manifest pin
        // must then match. Nothing outside the closed catalog is described.
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count),
              qwenStageWireIsSHA256(runtimeBinarySHA256),
              let spec = try? GPTOSSRegisteredSpecification.specification(configuration: configuration),
              sha256(manifest) == spec.manifestSHA256 else {
            throw ProbeError("Capability metadata requires the exact registered GPT-OSS configuration and manifest")
        }
        try spec.requireManifest(manifest, configuration: configuration)
        let profile = try spec.profile()
        let partitions = try spec.supportedCuts.map { cut -> ClusterRuntimePartition in
            let plan = try GPTOSSLayerStagePlan(configuration: configuration, cut: cut)
            return ClusterRuntimePartition(planSHA256: plan.fingerprint, stages: plan.stages.map {
                ClusterRuntimeStage(rank: $0.index, sourceLayerStart: $0.sourceRange.lowerBound,
                    sourceLayerEnd: $0.sourceRange.upperBound, stagePlanSHA256: $0.fingerprint,
                    constructionConfigurationSHA256: sha256($0.constructionConfiguration))
            })
        }
        // The required source contract, not a claim about this process's environment.
        let arithmetic = try GPTOSSArithmeticEnvironment.admit(GPTOSSArithmeticEnvironment.requiredValues)
        return try ClusterRuntimeCapability(runtimeBinarySHA256: runtimeBinarySHA256,
            adapterID: adapter.rawValue, adapterVersion: adapter.version, runtimeModelID: spec.model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            manifestSHA256: spec.manifestSHA256,
            profile: .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens),
            profileFingerprint: profile.fingerprint, partitions: partitions,
            arithmeticPolicyID: GPTOSSArithmeticEnvironment.contract,
            arithmeticPolicySHA256: sha256(try canonicalJSONData(arithmetic)),
            maxLifetimeSeconds: Int(GPTOSSRegisteredSpecification.maximumLifetimeNanoseconds / 1_000_000_000),
            maxRequests: GPTOSSRegisteredSpecification.maximumRequests,
            supportedPrefillSchedules: spec.supportedPrefillSchedules,
            supportedGenerationModes: spec.supportedGenerationModes)
    }

    /// What a launcher or qualification tool may ask for before any load: the
    /// closed resident scope of one registered model. Not a capability record.
    public struct RegisteredModel: Equatable, Sendable {
        public let runtimeModelID: String
        public let profileID: String
        public let layerCount: Int
        public let supportedCuts: [Int]
        public let supportedPrefillSchedules: [ClusterPrefillSchedule]
        public let supportedGenerationModes: [ClusterGenerationMode]
        public let maximumLifetimeSeconds: Int
        public let configurationSHA256: String
        public let manifestSHA256: String

        init(_ spec: GPTOSSRegisteredSpecification) {
            runtimeModelID = spec.model.rawValue; profileID = spec.profileID; layerCount = spec.layers
            supportedCuts = spec.supportedCuts; supportedPrefillSchedules = spec.supportedPrefillSchedules
            supportedGenerationModes = spec.supportedGenerationModes
            maximumLifetimeSeconds = Int(GPTOSSRegisteredSpecification.maximumLifetimeNanoseconds / 1_000_000_000)
            configurationSHA256 = spec.configurationSHA256; manifestSHA256 = spec.manifestSHA256
        }
    }

    public static var registeredModels: [RegisteredModel] { GPTOSSRegisteredSpecification.all.map(RegisteredModel.init) }

    /// One line per registered GPT-OSS model and the cuts it may be loaded at,
    /// in the same form as the Qwen catalog's, for a tool's usage text.
    public static var registeredCutsUsage: String {
        registeredModels.map { "\($0.runtimeModelID): " + $0.supportedCuts.map(String.init).joined(separator: "|") }
            .joined(separator: "\n")
    }

    /// Nil for every ID that is not a registered GPT-OSS resident model.
    public static func registeredModel(runtimeModelID: String) -> RegisteredModel? {
        (try? GPTOSSRegisteredSpecification.specification(runtimeModelID: runtimeModelID)).map(RegisteredModel.init)
    }

    /// The registered model an artifact's `config.json` bytes belong to.
    public static func registeredModel(configuration: Data) throws -> RegisteredModel {
        guard let spec = try? GPTOSSRegisteredSpecification.specification(configuration: configuration) else {
            throw ProbeError("The configuration is not a registered GPT-OSS resident model's")
        }
        return .init(spec)
    }
}
