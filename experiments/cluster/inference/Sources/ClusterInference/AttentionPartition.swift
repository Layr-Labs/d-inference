import Foundation

/// Two-rank full-attention partition for converted dense Qwen3.5-family weights.
/// Quantization policy must independently be validated as affine W4/G64 by the plan.
struct QwenAttentionPartition {
    let hiddenSize: Int
    let queryHeads: Int
    let kvHeads: Int
    let headDim: Int
    let reductionModule = "o_proj"

    var configurationUpdates: [String: Int] {
        // Pin the ORIGINAL dimension: the model otherwise infers a larger dimension
        // from hidden_size / the already-halved query head count.
        ["num_attention_heads": queryHeads / 2, "num_key_value_heads": kvHeads / 2,
         "head_dim": headDim]
    }

    init(text: [String: Any]) throws {
        guard let hidden = text["hidden_size"] as? Int,
            let query = text["num_attention_heads"] as? Int,
            let kv = text["num_key_value_heads"] as? Int,
            hidden > 0, hidden <= Int(Int32.max), hidden % 64 == 0,
            query > 0, query <= Int(Int32.max), query % 2 == 0,
            kv > 0, kv <= Int(Int32.max), kv % 2 == 0, query % kv == 0,
            (text["attention_bias"] as? Bool ?? false) == false
        else { throw ProbeError("Attention TP requires unbiased W4/G64 projections and whole two-rank Q/KV groups") }
        let dimension: Int
        if let explicit = text["head_dim"] as? Int { dimension = explicit }
        else {
            guard hidden % query == 0 else { throw ProbeError("Cannot infer an integral attention head dimension") }
            dimension = hidden / query
        }
        let width = query.multipliedReportingOverflow(by: dimension)
        guard dimension > 0, dimension <= Int(Int32.max), !width.overflow,
            width.partialValue <= Int(Int32.max) / 2,
            (width.partialValue / 2) % 64 == 0
        else { throw ProbeError("Attention output channels must split on complete W4/G64 groups") }
        hiddenSize = hidden; queryHeads = query; kvHeads = kv; headDim = dimension
    }

    func selection(relativeName: String, shape: [Int], rank: Int) throws -> TensorSelection {
        guard (0..<2).contains(rank) else { throw ProbeError("Invalid attention partition rank") }
        if ["q_norm.weight", "k_norm.weight"].contains(relativeName) {
            guard shape == [headDim] else { throw ProbeError("Attention norm must cover one complete head") }
            return .all
        }
        let parts = relativeName.split(separator: ".").map(String.init)
        guard parts.count == 2, ["q_proj", "k_proj", "v_proj", "o_proj"].contains(parts[0]),
            ["weight", "scales", "biases"].contains(parts[1])
        else { throw ProbeError("Unsupported attention tensor: \(relativeName)") }
        let projection = parts[0]
        let packing = parts[1] == "weight" ? 8 : 64
        let rows: Int
        let columns: Int
        let axis: Int
        if projection == "o_proj" {
            rows = hiddenSize; columns = queryHeads * headDim / packing; axis = 1
        } else {
            // q_proj is [head0.query, head0.gate, head1.query, head1.gate, ...].
            // Keeping whole paired heads also preserves the matching GQA groups.
            rows = projection == "q_proj" ? queryHeads * headDim * 2 : kvHeads * headDim
            columns = hiddenSize / packing; axis = 0
        }
        guard shape == [rows, columns] else {
            throw ProbeError("Attention tensor shape does not match affine W4/G64 geometry: \(relativeName)")
        }
        let half = shape[axis] / 2
        guard half > 0, shape[axis] % 2 == 0 else { throw ProbeError("Attention tensor cannot be halved") }
        return .axis(axis, [(rank * half)..<((rank + 1) * half)])
    }
}
