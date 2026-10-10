import DarkbloomClusterProtocol
import Foundation

/// One definition for the currently admitted resident adapter and its metadata.
/// Describing these limits does not allocate a model or admit a request.
enum QwenResidentAdapterDefinition {
    static let profileID = "registered_qwen35_9b_greedy_generation_v1"
    static let maximumLifetimeNanoseconds: UInt64 = 300_000_000_000
    static let maximumRequests = 16
    static let supportedCuts = [4, 8, 12, 16]
    static let supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]

    static func profile(specification: QwenDenseRegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        // The model's own closed row names its profile; the 9B row is `Self.profileID`.
        let profileID = try QwenResidentModelDefinition(model: specification.model).profileID
        let vocabularySize = specification.model == .nemotron35Lightning
            ? NemotronRegisteredLightning.vocabularySize : 248_320
        return try .init(identifier: profileID, vocabularySize: vocabularySize,
            hiddenSize: specification.hidden, activationDType: specification.model.pack.activationDType,
            maximumPromptTokens: 8192,
            maximumChunkTokens: 512, maximumOutputTokens: 128, maximumContextTokens: 8320)
    }
}
