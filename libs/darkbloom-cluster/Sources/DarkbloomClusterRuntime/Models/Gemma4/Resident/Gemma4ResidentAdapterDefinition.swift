import DarkbloomClusterProtocol
import Foundation

/// The closed resident scope of the registered Gemma 4 26B artifacts: what a
/// pair may be loaded at and how a request may be divided. Describing it
/// allocates nothing and admits no request.
enum Gemma4ResidentAdapterDefinition {
    static let maximumLifetimeNanoseconds: UInt64 = 300_000_000_000
    static let maximumRequests = 16
    static let supportedCuts = Gemma4LayerStagePlanning.supportedCuts
    static let supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]
    /// The pipeline only. Handing a sliding layer's window from one rank to the
    /// other is not built, so the phase split is not advertised.
    static let supportedGenerationModes: [ClusterGenerationMode] = [.pipeline]

    static func profileID(_ model: Gemma4RegisteredModel) -> String { model.rawValue + "_greedy_generation_v1" }

    static func profile(specification: Gemma4RegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        try .init(identifier: profileID(specification.model),
            vocabularySize: Gemma4StageGeometry.vocabularySize, hiddenSize: Gemma4StageGeometry.hiddenSize,
            activationDType: "bfloat16", maximumPromptTokens: 8192, maximumChunkTokens: 512,
            maximumOutputTokens: 128, maximumContextTokens: 8320,
            // The final-logit softcap is computed in float32, as in the product.
            logitsDType: "float32")
    }
}
