import MLX
import MLXLMCommon
import MLXVLM

/// Converts an already admitted/fenced SDK result without evaluating tensors.
/// The loaded recurrent adapter must independently support causal embeddings.
/// No prefix identity is created and no generic model-support policy is changed.
enum NemotronSuperVisionSubmission {
    static func make(_ prepared: NemotronSuperVisionPreparation.Prepared)
        -> EngineV2VisionPrefill.PreparedSubmission {
        make(promptTokens: prepared.prompt.map(Int.init), ranges: prepared.ranges,
             features: prepared.features, mediaKind: .image)
    }

    /// One evaluated feature array per placeholder range, in prompt order.
    static func make(promptTokens: [Int], ranges: [Range<Int>], features: [MLXArray],
                     mediaKind: EngineV2MediaKind) -> EngineV2VisionPrefill.PreparedSubmission {
        .init(promptTokens: promptTokens,
            spans: ranges.map {
                CBv2ImageSpan(tokenOffset: $0.lowerBound, length: $0.count)
            }, embeddings: features,
            attention: .causal, positionState: nil, mediaKind: mediaKind)
    }
}
