import DarkbloomClusterProtocol
import Foundation

/// One definition for the currently admitted resident adapter and its metadata.
/// Describing these limits does not allocate a model or admit a request.
enum QwenResidentAdapterDefinition {
    static let profileID = QwenResidentModelDefinition.nineBProfileID
    static let maximumLifetimeNanoseconds: UInt64 = 300_000_000_000
    static let maximumRequests = 16
    static let supportedCuts = QwenResidentModelDefinition.nineBCuts
    static let supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]

    static func profile(specification: QwenDenseRegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        guard specification.model == .qwen35NineB else { throw ProbeError("Unsupported resident model") }
        return try profile(definition: QwenResidentModelDefinition(model: specification.model))
    }

    static func profile(definition: QwenResidentModelDefinition) throws -> QwenLayerStageGenerationProfile {
        return try .init(identifier: definition.profileID, vocabularySize: 248_320,
            hiddenSize: definition.specification.hidden, activationDType: "bfloat16", maximumPromptTokens: 8192,
            maximumChunkTokens: 512, maximumOutputTokens: 128, maximumContextTokens: 8320)
    }
}
