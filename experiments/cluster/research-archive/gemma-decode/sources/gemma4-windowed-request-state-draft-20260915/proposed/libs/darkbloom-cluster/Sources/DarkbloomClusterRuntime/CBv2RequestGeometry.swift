import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Local model-derived geometry. Compact attention storage indices are not
/// transformer layer indices; the model's newCacheV2 preserves that mapping.
struct CBv2RequestGeometry {
    let kinds: [CBv2LayerKind]
    let caches: [any CBv2AttendingLayerCache]
    let recurrent: CBv2RecurrentStateSpec
    let kvDType: DType
    let kvCapacityBytes: Int
    // Construction-only optional path; legacy Qwen initializers retain nil.
    var attentionLayout: LayerAttentionStateLayout? = nil


    init(model: any LanguageModel, family: InferenceModelFamily, feedForwardKind: String,
         layerCount: Int, vocabularySize: Int, configurationData: Data, maximumTokens: Int) throws {
        guard family == .qwen35, feedForwardKind == "dense",
              layerCount > 0, vocabularySize > 0,
              vocabularySize <= Int(Int32.max), maximumTokens > 0,
              model is any CBv2RecurrentLanguageModelPrefillForwardable,
              model is any CBv2PositionedRecurrentLanguageModelForwardable else {
            throw ProbeError("cbv2-contiguous requires a dense Qwen recurrent/prefill model")
        }
        guard let root = try JSONSerialization.jsonObject(with: configurationData) as? [String: Any] else {
            throw ProbeError("CBv2 model configuration must be an object")
        }
        let text = root["text_config"] as? [String: Any] ?? root
        let declaredContext = try qwenPartitionInteger(text, "max_position_embeddings")
        guard maximumTokens <= min(declaredContext, 32_768) else {
            throw ProbeError("CBv2 request exceeds the model's declared context bound")
        }
        let kinds: [CBv2LayerKind]
        let caches: [any CBv2AttendingLayerCache]
        let recurrent: CBv2RecurrentStateSpec
        if let model = model as? Qwen35TextModel {
            kinds = model.cbv2LayerKinds; recurrent = model.cbv2RecurrentStateSpec
            caches = model.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) }
        } else if let model = model as? Qwen35Model {
            kinds = model.cbv2LayerKinds; recurrent = model.cbv2RecurrentStateSpec
            caches = model.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) }
        } else {
            throw ProbeError("Unsupported concrete Qwen CBv2 model constructor")
        }
        // The pinned private decoder requires its concrete MLP type. Output
        // Linear subclasses are supported; replacing the whole MLP is not.
        let mlps = model.namedModules().filter { $0.0.hasSuffix(".mlp") }
        guard mlps.count == layerCount,
              mlps.allSatisfy({ String(describing: type(of: $0.1)) == "Qwen3NextMLP" }) else {
            throw ProbeError("cbv2-contiguous requires the pinned dense MLP topology; whole-MLP substitutes are unsupported")
        }
        guard !kinds.isEmpty, kinds.count == caches.count,
              let types = (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
              types.count == kinds.count, let dtype = types.first,
              [.float16, .bfloat16, .float32].contains(dtype), types.allSatisfy({ $0 == dtype }) else {
            throw ProbeError("cbv2-contiguous requires known, uniform native attention KV dtypes")
        }
        let attentionIndices = kinds.compactMap(\.modelLayerIndex)
        let recurrentIndices = recurrent.modelLayerIndices
        guard attentionIndices.count == kinds.count,
              attentionIndices == attentionIndices.sorted(),
              Set(attentionIndices).count == attentionIndices.count,
              Set(recurrentIndices).count == recurrentIndices.count,
              Set(attentionIndices).isDisjoint(with: Set(recurrentIndices)),
              Set(attentionIndices + recurrentIndices) == Set(0..<layerCount) else {
            throw ProbeError("Qwen compact attention and recurrent indices do not cover the model exactly")
        }
        var capacity = 0
        for (index, kind) in kinds.enumerated() {
            guard case .full = kind.attention, kind.sharesKVWithLayer == nil,
                  !kind.hasSinks, !kind.isBidirectional,
                  kind.kvHeads > 0, kind.queryHeads > 0, kind.headDim > 0,
                  kind.queryHeads % kind.kvHeads == 0,
                  caches[index].kind == kind, caches[index].layerIndex == attentionIndices[index],
                  caches[index].rows.isEmpty, caches[index] is any KVCache else {
                throw ProbeError("Unsupported Qwen CBv2 attention cache geometry")
            }
            var bytes = maximumTokens
            for factor in [kind.kvHeads, kind.headDim, dtype.size, 2] {
                let product = bytes.multipliedReportingOverflow(by: factor)
                guard !product.overflow else { throw ProbeError("CBv2 attention byte count overflow") }
                bytes = product.partialValue
            }
            let sum = capacity.addingReportingOverflow(bytes)
            guard !sum.overflow else { throw ProbeError("CBv2 attention capacity overflow") }
            capacity = sum.partialValue
        }
        for layer in recurrent.layers {
            guard layer.convShape.count == 3, layer.convShape[0] == 1,
                  layer.convShape[1] >= 0, layer.convShape[2] > 0,
                  layer.ssmShape.count == 4, layer.ssmShape[0] == 1,
                  layer.ssmShape.allSatisfy({ $0 > 0 }), layer.ssmDType == .float32,
                  [.float16, .bfloat16, .float32].contains(layer.convDType) else {
                throw ProbeError("Unsupported Qwen recurrent state geometry")
            }
        }
        _ = try recurrent.peakBytesPerRequest()
        self.kinds = kinds; self.caches = caches; self.recurrent = recurrent
        self.kvDType = dtype; self.kvCapacityBytes = capacity
    }
}
