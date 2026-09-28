import CoreFoundation
import Foundation

/// Qwen's routed and sigmoid-gated shared branches share one output reduction.
/// Expert IDs, router scores, the shared gate and all normalization stay global.
/// This plan addresses the canonical fused SwitchGLU layout after sanitization;
/// checkpoint readers must map split source gate/up tensors to that layout.
/// The loader independently validates every projection's affine W4/G64 policy.
struct QwenMoEPartition {
    let hidden: Int
    let experts: Int
    let topK: Int
    let intermediate: Int
    let sharedIntermediate: Int
    private let expertPlans: [ExpertPartitionPlan]

    var configurationUpdates: [String: Int] {
        ["moe_intermediate_size": intermediate / 2,
         "shared_expert_intermediate_size": sharedIntermediate / 2]
    }

    init(text: [String: Any]) throws {
        let hidden = try qwenPartitionInteger(text, "hidden_size")
        let experts = try qwenPartitionInteger(text, "num_experts")
        let topK = try qwenPartitionInteger(text, "num_experts_per_tok")
        let intermediate = try qwenPartitionInteger(text, "moe_intermediate_size")
        let sharedIntermediate = try qwenPartitionInteger(text, "shared_expert_intermediate_size")
        guard hidden % 64 == 0, intermediate % 128 == 0,
            sharedIntermediate % 128 == 0, topK <= experts else {
            throw ProbeError("Qwen MoE requires legal global routing and whole W4/G64 groups on both ranks")
        }
        if let activation = text["hidden_act"] {
            guard activation as? String == "silu" else { throw ProbeError("Qwen MoE requires SiLU") }
        }
        if text["decoder_sparse_step"] != nil {
            guard try qwenPartitionInteger(text, "decoder_sparse_step") == 1 else {
                throw ProbeError("Mixed dense/sparse Qwen layer schedules are not qualified")
            }
        }
        if let denseLayers = text["mlp_only_layers"] {
            guard let indices = denseLayers as? [Any], indices.isEmpty else {
                throw ProbeError("Qwen MoE requires an all-sparse FFN layer schedule")
            }
        }
        if let normalization = text["norm_topk_prob"] {
            guard let number = normalization as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw ProbeError("Qwen MoE norm_topk_prob must be a Boolean")
            }
        }
        // Both ranks retain every expert; only the expert's inner width changes.
        let width = intermediate / 2
        expertPlans = try (0..<2).map { rank in
            try ExpertPartitionPlan(inputDims: hidden, intermediateDims: intermediate,
                numExperts: experts, interval: (rank * width)..<((rank + 1) * width),
                activation: .silu, fusedGateUp: true,
                projectionBits: ["gate_up_proj": 4, "down_proj": 4])
        }
        self.hidden = hidden; self.experts = experts; self.topK = topK
        self.intermediate = intermediate; self.sharedIntermediate = sharedIntermediate
    }

    func selection(relativeName: String, shape: [Int], rank: Int) throws -> TensorSelection {
        guard (0..<2).contains(rank) else { throw ProbeError("Invalid Qwen MoE partition rank") }
        let parts = relativeName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, !parts.contains("") else {
            throw ProbeError("Unknown Qwen MoE tensor: \(relativeName)")
        }
        if parts[0] == "switch_mlp" {
            guard parts.count == 3 else { throw ProbeError("Unknown routed expert tensor: \(relativeName)") }
            return try expertPlans[rank].selection(name: parts.dropFirst().joined(separator: "."), shape: shape)
        }
        let parameter = parts.last!
        guard ["weight", "scales", "biases"].contains(parameter) else {
            throw ProbeError("Unsupported Qwen MoE parameter or ordinary bias: \(relativeName)")
        }
        let packing = parameter == "weight" ? 8 : 64
        if parts.count == 2, ["gate", "shared_expert_gate"].contains(parts[0]) {
            let rows = parts[0] == "gate" ? experts : 1
            guard shape == [rows, hidden / packing] else {
                throw ProbeError("Replicated Qwen MoE gate W4/G64 shape mismatch: \(relativeName)")
            }
            return .all
        }
        guard parts.count == 3, parts[0] == "shared_expert" else {
            throw ProbeError("Unknown Qwen MoE tensor: \(relativeName)")
        }
        let expected: [Int], axis: Int
        switch parts[1] {
        case "gate_proj", "up_proj": expected = [sharedIntermediate, hidden / packing]; axis = 0
        case "down_proj": expected = [hidden, sharedIntermediate / packing]; axis = 1
        default: throw ProbeError("Unknown Qwen shared-expert projection: \(relativeName)")
        }
        guard shape == expected else {
            throw ProbeError("Qwen shared-expert W4/G64 shape mismatch: \(relativeName)")
        }
        let width = shape[axis] / 2
        return .axis(axis, [(rank * width)..<((rank + 1) * width)])
    }
}

/// JSON booleans bridge to Int through NSNumber; never accept them as geometry.
func qwenPartitionInteger(_ text: [String: Any], _ key: String, allowZero: Bool = false) throws -> Int {
    guard let value = text[key] as? Int, value >= (allowZero ? 0 : 1), value <= 1_048_576,
        let number = text[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
        throw ProbeError("Qwen partition requires an explicit \(allowZero ? "nonnegative" : "positive") integer \(key)")
    }
    return value
}
