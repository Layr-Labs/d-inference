import DarkbloomClusterProtocol
import Foundation

/// One definition for the currently admitted resident adapter and its metadata.
/// Describing these limits does not allocate a model or admit a request.
enum QwenResidentAdapterDefinition {
    static let profileID = "registered_qwen35_9b_greedy_generation_v1"
    static let supportedCuts = [4, 8, 12, 16]
    static let supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]

    /// What the pair advertises and a reservation is held to. Prompt, output
    /// and context follow from the protocol and the model's declared context,
    /// not from a table (`QwenResidentContextLimits`).
    static func profile(specification: QwenDenseRegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        try profile(specification: specification, limits: QwenResidentContextLimits(specification: specification))
    }

    /// The request every LOAD gate and the memory plan charge
    /// (`QwenResidentContextLimits(memoryOf:)`): the profile itself, except
    /// for a row that serves its native context, whose memory plan keeps the
    /// standard request. Same identifier; a different fingerprint only there.
    static func memoryProfile(specification: QwenDenseRegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        try profile(specification: specification, limits: QwenResidentContextLimits(memoryOf: specification))
    }

    private static func profile(specification: QwenDenseRegisteredSpecification,
                                limits: QwenResidentContextLimits) throws -> QwenLayerStageGenerationProfile {
        // The model's own closed row names its profile; the 9B row is `Self.profileID`.
        let profileID = try QwenResidentModelDefinition(model: specification.model).profileID
        let vocabularySize = specification.model == .nemotron35Lightning
            ? NemotronRegisteredLightning.vocabularySize : 248_320
        return try .init(identifier: profileID, vocabularySize: vocabularySize,
            hiddenSize: specification.hidden, activationDType: specification.model.pack.activationDType,
            maximumPromptTokens: limits.maximumPromptTokens, maximumChunkTokens: limits.maximumChunkTokens,
            maximumOutputTokens: limits.maximumOutputTokens, maximumContextTokens: limits.maximumContextTokens)
    }
}
