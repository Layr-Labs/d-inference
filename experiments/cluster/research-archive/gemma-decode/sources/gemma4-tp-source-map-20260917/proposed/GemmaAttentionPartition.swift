import Foundation
import MLXLLM
import MLXLMCommon

/// Prospective metadata helper only; no caller, model allocation or admission.
/// Compose after GemmaPartitionPlan's original-config/quantization validation.
/// Unlike Qwen's gated query projection, Gemma stores exactly Q * D query rows.
struct GemmaAttentionPartition {
    let hidden: Int
    let queryHeads: Int
    let slidingKVHeads: Int
    let fullKVHeads: Int
    let slidingHeadDim: Int
    let fullHeadDim: Int
    let fullKeqV: Bool
    let layerTypes: [String]

    var configurationUpdates: [String: Int] {
        ["num_attention_heads": queryHeads / 2,
         "num_key_value_heads": slidingKVHeads / 2,
         "num_global_key_value_heads": fullKVHeads / 2,
         "head_dim": slidingHeadDim, "global_head_dim": fullHeadDim]
    }

    init(config: Gemma4TextConfiguration) throws {
        let fullKV = config.numGlobalKeyValueHeads ?? config.numKeyValueHeads
        let sizes = [config.hiddenSize, config.numAttentionHeads,
                     config.numKeyValueHeads, fullKV, config.headDim, config.globalHeadDim]
        guard sizes.allSatisfy({ (1...1_048_576).contains($0) }),
              config.hiddenSize.isMultiple(of: 64),
              config.numAttentionHeads.isMultiple(of: 2),
              config.numKeyValueHeads.isMultiple(of: 2), fullKV.isMultiple(of: 2),
              config.numAttentionHeads.isMultiple(of: config.numKeyValueHeads),
              config.numAttentionHeads.isMultiple(of: fullKV),
              (1...4096).contains(config.numHiddenLayers),
              config.layerTypes.count == config.numHiddenLayers,
              config.layerTypes.allSatisfy({ ["sliding_attention", "full_attention"].contains($0) }),
              config.numKvSharedLayers == 0 else {
            throw ProbeError("Gemma head TP requires whole two-rank GQA groups and non-shared layer caches")
        }
        for dimension in [config.headDim, config.globalHeadDim] {
            let query = try Self.width(config.numAttentionHeads, dimension)
            guard (query / 2).isMultiple(of: 64) else {
                throw ProbeError("Gemma o_proj rank inputs must cover complete G64 groups")
            }
        }
        _ = try Self.width(config.numKeyValueHeads, config.headDim)
        _ = try Self.width(fullKV, config.globalHeadDim)
        hidden = config.hiddenSize; queryHeads = config.numAttentionHeads
        slidingKVHeads = config.numKeyValueHeads; fullKVHeads = fullKV
        slidingHeadDim = config.headDim; fullHeadDim = config.globalHeadDim
        fullKeqV = config.attentionKeqV; layerTypes = config.layerTypes
    }

    func selection(layer: Int, relativeName: String, shape: [Int], rank: Int,
                   quantization: BaseConfiguration.Quantization?) throws -> TensorSelection {
        guard layerTypes.indices.contains(layer), (0..<2).contains(rank) else {
            throw ProbeError("Invalid Gemma attention layer or rank")
        }
        let full = layerTypes[layer] == "full_attention"
        let dimension = full ? fullHeadDim : slidingHeadDim
        if ["q_norm.weight", "k_norm.weight"].contains(relativeName) {
            guard shape == [dimension], quantization == nil else {
                throw ProbeError("Gemma attention norm is an unquantized, replicated per-head vector")
            }
            return .all
        }
        let parts = relativeName.split(separator: ".").map(String.init)
        guard parts.count == 2, ["q_proj", "k_proj", "v_proj", "o_proj"].contains(parts[0]),
              ["weight", "scales", "biases"].contains(parts[1]),
              !(full && fullKeqV && parts[0] == "v_proj"),
              let policy = quantization, policy.mode == .affine,
              [4, 8].contains(policy.bits), policy.groupSize == 64 else {
            throw ProbeError("Unsupported Gemma attention tensor or affine W4/W8 G64 policy")
        }
        let packing = parts[1] == "weight" ? 32 / policy.bits : 64
        let queryWidth = try Self.width(queryHeads, dimension)
        let kvWidth = try Self.width(full ? fullKVHeads : slidingKVHeads, dimension)
        let output = parts[0] == "o_proj"
        let rows = output ? hidden : (parts[0] == "q_proj" ? queryWidth : kvWidth)
        let columns = (output ? queryWidth : hidden) / packing
        let axis = output ? 1 : 0
        guard shape == [rows, columns], shape[axis].isMultiple(of: 2) else {
            throw ProbeError("Gemma attention packed source shape differs from the original full geometry")
        }
        let half = shape[axis] / 2
        return .axis(axis, [(rank * half)..<((rank + 1) * half)])
    }

    private static func width(_ heads: Int, _ dimension: Int) throws -> Int {
        let product = heads.multipliedReportingOverflow(by: dimension)
        guard !product.overflow, product.partialValue <= Int(Int32.max) else {
            throw ProbeError("Gemma attention projection width overflow")
        }
        return product.partialValue
    }
}
