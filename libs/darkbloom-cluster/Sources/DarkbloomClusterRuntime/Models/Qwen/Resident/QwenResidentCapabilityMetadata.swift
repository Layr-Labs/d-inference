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
        // The configuration bytes select the registered model; its manifest pin
        // must then match. Nothing outside the closed catalog is described.
        guard (1...1_048_576).contains(configuration.count), (1...4_194_304).contains(manifest.count),
              qwenStageWireIsSHA256(runtimeBinarySHA256),
              let definition = try? QwenResidentModelDefinition(configuration: configuration),
              case let spec = definition.specification,
              sha256(configuration) == spec.configurationSHA256, sha256(manifest) == spec.manifestSHA256 else {
            throw ProbeError("Capability metadata requires the exact registered 9B, 27B, a registered 35B A3B, Bonsai 2 27B or Nemotron 3.5 Lightning configuration and manifest")
        }
        let profile = try QwenResidentAdapterDefinition.profile(specification: spec)
        let partitions = try definition.supportedCuts.map { cut -> ClusterRuntimePartition in
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
        let arithmetic = try definition.arithmetic.admit(definition.arithmetic.requiredValues)
        let adapter = definition.adapter
        return try ClusterRuntimeCapability(runtimeBinarySHA256: runtimeBinarySHA256,
            adapterID: adapter.rawValue, adapterVersion: adapter.version, runtimeModelID: spec.model.rawValue,
            artifactSHA256: spec.artifactSHA256, configurationSHA256: spec.configurationSHA256,
            manifestSHA256: spec.manifestSHA256,
            profile: .init(id: profile.identifier, vocabularySize: profile.vocabularySize,
                maximumPromptTokens: profile.maximumPromptTokens, maximumOutputTokens: profile.maximumOutputTokens,
                maximumChunkTokens: profile.maximumChunkTokens, maximumContextTokens: profile.maximumContextTokens),
            profileFingerprint: profile.fingerprint, partitions: partitions,
            arithmeticPolicyID: definition.arithmetic.contract,
            arithmeticPolicySHA256: sha256(try canonicalJSONData(arithmetic)),
            maxLifetimeSeconds: Int(QwenResidentAdapterDefinition.maximumLifetimeNanoseconds / 1_000_000_000),
            maxRequests: QwenResidentAdapterDefinition.maximumRequests,
            supportedPrefillSchedules: definition.supportedPrefillSchedules,
            supportedGenerationModes: definition.supportedGenerationModes)
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
        /// The artifact's pinned manifest, and the exact environment the
        /// model's arithmetic contract requires of each rank.
        public let manifestSHA256: String
        public let requiredArithmeticEnvironment: [String: String]

        init(_ definition: QwenResidentModelDefinition) {
            manifestSHA256 = definition.specification.manifestSHA256
            requiredArithmeticEnvironment = definition.arithmetic.requiredValues
            runtimeModelID = definition.specification.model.rawValue; profileID = definition.profileID
            layerCount = definition.specification.layers; supportedCuts = definition.supportedCuts
            supportedPrefillSchedules = definition.supportedPrefillSchedules
            supportedGenerationModes = definition.supportedGenerationModes
        }
    }

    /// Every registered resident model, in the closed catalog's order.
    public static var registeredModels: [RegisteredModel] {
        QwenRegisteredDenseModel.allCases.compactMap { try? QwenResidentModelDefinition(model: $0) }.map(RegisteredModel.init)
    }

    /// One line per registered model and the cuts it may be loaded at, for a
    /// tool's usage text: read from the catalog, so it cannot fall behind it.
    public static var registeredCutsUsage: String {
        registeredModels.map { "\($0.runtimeModelID): " + $0.supportedCuts.map(String.init).joined(separator: "|") }
            .joined(separator: "\n")
    }

    /// Nil for every ID that is not a registered resident model.
    public static func registeredModel(runtimeModelID: String) -> RegisteredModel? {
        (try? QwenResidentModelDefinition(runtimeModelID: runtimeModelID)).map(RegisteredModel.init)
    }

    /// The registered model an artifact's `config.json` bytes belong to.
    public static func registeredModel(configuration: Data) throws -> RegisteredModel {
        guard let definition = try? QwenResidentModelDefinition(configuration: configuration) else {
            throw ProbeError("The configuration is not a registered resident model's")
        }
        return .init(definition)
    }
}
