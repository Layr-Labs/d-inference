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
    /// Tensor parallel keeps prompt prefixes as the pipeline does, resident and on the owner's SSD tier
    /// (`Gemma4TensorParallelPrefix`); its load agreement binds this (`Gemma4TensorParallelLoadAgreement.prefixCache`).
    static let tensorParallelKeepsPromptPrefixes = true
    /// What each mode keeps (`ClusterServingFeatures`), as this build runs it: both modes keep prompt prefixes resident
    /// and on the owner's SSD tier (the pipeline's stage owner through `QwenStagePrefixCache`, tensor parallel through
    /// `Gemma4TensorParallelPrefix`); tensor parallel adds logprobs. Both serve up to `QwenBatchWire.maximumLanes`
    /// lanes; neither decodes in speculative rounds or takes media.
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

    /// The output limit at the native context: the catalog's `max_output_length`
    /// for every registered Gemma 4 26B row, the `max_tokens` the coordinator
    /// gives a request that omits it, as Qwen3.8 27B's row names its catalog's
    /// (`QwenDenseRegisteredSpecification.nativeOutputTokens`).
    static let nativeOutputTokens = 32_768

    /// The request bounds the pair advertises and holds a request to: the
    /// model's whole declared context (up to 262,143 prompt tokens), as a
    /// single Mac serving it holds a request to its window
    /// (`QwenResidentContextLimits.Ceiling.native`).
    static func contextLimits() throws -> QwenResidentContextLimits {
        try QwenResidentContextLimits(declaredContextTokens: declaredContextTokens,
            ceiling: .native(outputTokens: nativeOutputTokens))
    }

    /// The request every LOAD gate, every quote and the planner size a pair
    /// for: the protocol's standard request cut to the declared context. A
    /// longer request is charged at its own context when a rank reserves it.
    static func memoryContextLimits() throws -> QwenResidentContextLimits {
        try QwenResidentContextLimits(declaredContextTokens: declaredContextTokens)
    }

    static func profile(specification: Gemma4RegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        try profile(specification: specification, limits: contextLimits())
    }

    /// The memory plan's profile (`memoryContextLimits`): the same identifier,
    /// another fingerprint.
    static func memoryProfile(specification: Gemma4RegisteredSpecification) throws -> QwenLayerStageGenerationProfile {
        try profile(specification: specification, limits: memoryContextLimits())
    }

    private static func profile(specification: Gemma4RegisteredSpecification,
                                limits: QwenResidentContextLimits) throws -> QwenLayerStageGenerationProfile {
        try .init(identifier: profileID(specification.model),
            vocabularySize: Gemma4StageGeometry.vocabularySize, hiddenSize: Gemma4StageGeometry.hiddenSize,
            activationDType: "bfloat16", maximumPromptTokens: limits.maximumPromptTokens,
            maximumChunkTokens: limits.maximumChunkTokens, maximumOutputTokens: limits.maximumOutputTokens,
            maximumContextTokens: limits.maximumContextTokens,
            // The final-logit softcap is computed in float32, as in the product.
            logitsDType: "float32")
    }
}
