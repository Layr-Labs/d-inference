import DarkbloomClusterProtocol
import Foundation

/// The closed resident scope of the registered Gemma 4 26B artifacts: what a
/// pair may be loaded at and how a request may be divided. Describing it
/// allocates nothing and admits no request.
enum Gemma4ResidentAdapterDefinition {
    static let supportedCuts = Gemma4LayerStagePlanning.supportedCuts
    static let supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]
    /// The pipeline only. Handing a sliding layer's window from one rank to the
    /// other is not built, so the phase split is not advertised.
    static let supportedGenerationModes: [ClusterGenerationMode] = [.pipeline]

    static func profileID(_ model: Gemma4RegisteredModel) -> String { model.rawValue + "_greedy_generation_v1" }

    /// The context the pinned configuration declares (`max_position_embeddings`,
    /// held to this value by `Gemma4StageGeometry.decode`).
    static let declaredContextTokens = 262_144

    /// The request bounds: the protocol's, cut to the declared context, as the
    /// dense Qwen rows derive theirs (`QwenResidentContextLimits`).
    static func contextLimits() throws -> QwenResidentContextLimits {
        try QwenResidentContextLimits(declaredContextTokens: declaredContextTokens)
    }

    static func profile(specification: Gemma4RegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        let limits = try contextLimits()
        return try .init(identifier: profileID(specification.model),
            vocabularySize: Gemma4StageGeometry.vocabularySize, hiddenSize: Gemma4StageGeometry.hiddenSize,
            activationDType: "bfloat16", maximumPromptTokens: limits.maximumPromptTokens,
            maximumChunkTokens: limits.maximumChunkTokens, maximumOutputTokens: limits.maximumOutputTokens,
            maximumContextTokens: limits.maximumContextTokens,
            // The final-logit softcap is computed in float32, as in the product.
            logitsDType: "float32")
    }
}
