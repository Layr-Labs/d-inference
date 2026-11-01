import DarkbloomClusterProtocol
import Foundation

/// The closed resident scope of the registered Gemma 4 26B artifacts: what a
/// pair may be loaded at and how a request may be divided. Describing it
/// allocates nothing and admits no request.
enum Gemma4ResidentAdapterDefinition {
    static let supportedCuts = Gemma4LayerStagePlanning.supportedCuts
    static let supportedPrefillSchedules: [ClusterPrefillSchedule] = [.serial, .oneChunkLookahead]
    /// The pipeline, and tensor parallel (`Gemma4TensorParallelResidentRuntime`).
    /// Handing a sliding layer's window from one rank to the other is not
    /// built, so the phase split is not advertised. The planner chooses tensor
    /// parallel only where it predicts it faster than the pipeline
    /// (`Gemma4PlacementFamily.tensorParallelPlan`, `ClusterTensorParallelChoice.fastest`).
    static let supportedGenerationModes: [ClusterGenerationMode] = [.pipeline, .tensorParallel]
    /// Tensor parallel keeps no prompt prefix yet; its load agreement binds this (`Gemma4TensorParallelResidentRuntime`).
    static let tensorParallelKeepsPromptPrefixes = false
    /// What each mode keeps (`ClusterServingFeatures`), as its load runs it: the pipeline's stage owner keeps
    /// prompt prefixes resident and on the owner's SSD tier (`QwenStagePrefixCache`, native KV); tensor parallel
    /// keeps none yet (`tensorParallelKeepsPromptPrefixes`) and adds logprobs. Both serve up to
    /// `QwenBatchWire.maximumLanes` lanes; neither decodes in speculative rounds or takes media.
    static let servingFeatures: [ClusterGenerationMode: ClusterServingFeatures] = [
        .pipeline: .init(promptPrefixReuse: true, ssdPrefixTier: true, speculativeRounds: false,
            maximumLanes: QwenBatchWire.maximumLanes, logprobs: false),
        .tensorParallel: .init(promptPrefixReuse: tensorParallelKeepsPromptPrefixes,
            ssdPrefixTier: tensorParallelKeepsPromptPrefixes, speculativeRounds: false,
            maximumLanes: QwenBatchWire.maximumLanes, logprobs: true),
    ]

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
