import MLXLMCommon
import MLXVLM

/// Converts an already admitted/fenced SDK result without evaluating tensors.
/// The loaded recurrent adapter must independently support causal embeddings.
/// No prefix identity is created and no generic model-support policy is changed.
enum NemotronSuperVisionSubmission {
    static func make(_ prepared: NemotronSuperVisionPreparation.Prepared)
        -> EngineV2VisionPrefill.PreparedSubmission {
        .init(promptTokens: prepared.prompt.map(Int.init),
            spans: prepared.ranges.map {
                CBv2ImageSpan(tokenOffset: $0.lowerBound, length: $0.count)
            }, embeddings: prepared.features,
            attention: .causal, positionState: nil, mediaKind: .image)
    }
}
