import Foundation
import MLX
import MLXLLM
import MLXLMCommon

extension CBv2RequestGeometry {
    /// The request-state geometry of one Nemotron stage, from the constructed
    /// stage model. Unlike a Qwen stage, not every block owns state: a
    /// mixture-of-experts block has none, so the attention and Mamba indices
    /// must be exactly the blocks of those kinds in the stage's own block
    /// list, and nothing is required of the rest.
    init(nemotronStage model: NemotronHModel, layerCount: Int, vocabularySize: Int,
         configurationData: Data, maximumTokens: Int) throws {
        guard layerCount > 0, vocabularySize > 0, vocabularySize <= Int(Int32.max), maximumTokens > 0,
              let root = try JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              let names = root["layers_block_type"] as? [String], names.count == layerCount else {
            throw ProbeError("Nemotron request geometry requires the stage's own block list")
        }
        let declaredContext = try qwenPartitionInteger(root, "max_position_embeddings")
        guard maximumTokens <= min(declaredContext, 32_768) else {
            throw ProbeError("CBv2 request exceeds the model's declared context bound")
        }
        let kinds = model.cbv2LayerKinds, recurrent = model.cbv2RecurrentStateSpec
        let caches = model.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) }
        guard !kinds.isEmpty, kinds.count == caches.count,
              let types = (model as? any CBv2CompleteCheckpointKVTypeProviding)?.cbv2CompleteCheckpointKVDTypes,
              types.count == kinds.count, let dtype = types.first,
              [.float16, .bfloat16, .float32].contains(dtype), types.allSatisfy({ $0 == dtype }) else {
            throw ProbeError("cbv2-contiguous requires known, uniform native attention KV dtypes")
        }
        func indices(_ kind: NemotronStageMetadata.BlockKind) -> [Int] {
            names.enumerated().filter { $0.element == kind.rawValue }.map(\.offset)
        }
        guard kinds.compactMap(\.modelLayerIndex) == indices(.attention),
              recurrent.modelLayerIndices.sorted() == indices(.mamba),
              indices(.attention).count + indices(.mamba).count + indices(.moe).count == layerCount else {
            throw ProbeError("Nemotron attention and recurrent indices differ from the stage's block list")
        }
        var capacity = 0
        for (index, kind) in kinds.enumerated() {
            guard case .full = kind.attention, kind.sharesKVWithLayer == nil,
                  !kind.hasSinks, !kind.isBidirectional,
                  kind.kvHeads > 0, kind.queryHeads > 0, kind.headDim > 0,
                  kind.queryHeads % kind.kvHeads == 0,
                  caches[index].kind == kind, caches[index].layerIndex == kind.modelLayerIndex,
                  caches[index].rows.isEmpty, caches[index] is any KVCache else {
                throw ProbeError("Unsupported Nemotron CBv2 attention cache geometry")
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
                throw ProbeError("Unsupported Nemotron recurrent state geometry")
            }
        }
        _ = try recurrent.peakBytesPerRequest()
        self.kinds = kinds; self.caches = caches; self.recurrent = recurrent
        self.kvDType = dtype; self.kvCapacityBytes = capacity; self.layerCount = layerCount
    }
}

/// One frame of a Nemotron stage, through the pinned model's stage seam. The
/// stage session owns the request state, the schedule and every check of what
/// comes back; this is only which entry point a frame takes.
enum NemotronStageForward {
    /// Stage 0: tokens in, every row's residual before `norm_f` out.
    /// Stage 1: stage 0's rows in; a one-element handle for a prompt chunk
    /// that is not the last, otherwise the last position's logits.
    static func run(model: NemotronHModel, stageIndex: Int, tokens: MLXArray, residual: MLXArray?,
                    caches: [any CBv2AttendingLayerCache], evaluation: CBv2RecurrentStateEvaluation,
                    frame: QwenLayerStageFrame) -> MLXArray {
        let rows = caches.map { $0 as! any KVCache }
        if stageIndex == 0 {
            return model.cbv2StageResidual(tokens, inputEmbedding: nil, caches: rows, recurrentState: [evaluation])
        }
        if frame.phase == .prefill {
            return model.cbv2StageLogits(tokens, inputEmbedding: residual!, caches: rows, recurrentState: [evaluation],
                requirement: frame.finalPromptChunk ? .lastPositionLogits : .evaluationOnly)
        }
        // A decode frame is the serving forward's: every position's logits, then the last row.
        return model.cbv2StageLogits(tokens, inputEmbedding: residual!, caches: rows, recurrentState: [evaluation],
            requirement: nil)[0..., -1, 0...]
    }
}
