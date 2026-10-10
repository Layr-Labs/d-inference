import Foundation
import MLX
import MLXLMCommon

extension CBv2RequestGeometry {
    /// A Gemma stage's request state: one attention row per local layer and no
    /// recurrent state. A full-attention layer keeps every committed token; a
    /// sliding layer keeps a ring of its window. Kinds are already keyed by the
    /// stage's own storage index.
    init(gemma4StageKinds kinds: [CBv2LayerKind], kvDType: DType, maximumTokens: Int) throws {
        guard !kinds.isEmpty, kinds.count <= Gemma4StageGeometry.layerCount,
              (1...32_768).contains(maximumTokens), [.float16, .bfloat16, .float32].contains(kvDType),
              kinds.enumerated().allSatisfy({ $0.element.modelLayerIndex == $0.offset }) else {
            throw ProbeError("Gemma stage state requires bounded tokens, a native dtype and local layer indices")
        }
        var capacity = 0
        for kind in kinds {
            let tokens: Int
            switch kind.attention {
            case .full:
                guard kind.kvHeads == Gemma4StageGeometry.fullKVHeads,
                      kind.headDim == Gemma4StageGeometry.fullHeadDimension else {
                    throw ProbeError("Gemma full-attention state geometry differs")
                }
                tokens = maximumTokens
            case .slidingWindow(let window):
                guard window == Gemma4StageGeometry.slidingWindow,
                      kind.kvHeads == Gemma4StageGeometry.slidingKVHeads,
                      kind.headDim == Gemma4StageGeometry.slidingHeadDimension else {
                    throw ProbeError("Gemma sliding-attention state geometry differs")
                }
                // The ring is allocated whole at the first write.
                tokens = window
            }
            guard kind.sharesKVWithLayer == nil, !kind.hasSinks, !kind.isBidirectional,
                  kind.valueHeadDim == kind.headDim, kind.queryHeads == Gemma4StageGeometry.queryHeads else {
                throw ProbeError("Unsupported Gemma attention cache geometry")
            }
            // Keys and values, each `[1, kvHeads, tokens, headDim]`.
            capacity = try QwenLongPrefillCheckedBytes.sum([capacity,
                QwenLongPrefillCheckedBytes.product([2, tokens, kind.kvHeads, kind.headDim, kvDType.size])])
        }
        self.kinds = kinds
        caches = kinds.enumerated().map { CBv2LayerCache(layerIndex: $0.offset, kind: $0.element) }
        recurrent = CBv2RecurrentStateSpec(layers: [])
        self.kvDType = kvDType
        kvCapacityBytes = capacity
        // Every Gemma layer owns attention state.
        layerCount = kinds.count
    }
}
