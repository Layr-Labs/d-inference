import MLX
import MLXLMCommon
import MLXNN

/// Validate the materialized model independently of the tensor reader. The
/// initial Qwen adapters support the registered affine W4/G64 projection policy.
func validatedQwenFeedForwardScaleTypes(_ model: Module, layers: Int, isMoE: Bool,
                                       requireTwoWaySplit: Bool) throws -> [String] {
    let ffns = model.namedModules().filter { $0.0.hasSuffix(".mlp") }
    guard ffns.count == layers else { throw ProbeError("Unexpected Qwen feed-forward topology") }
    var types = Set<String>()
    for (path, module) in ffns {
        let children = Dictionary(uniqueKeysWithValues: module.namedModules())
        let dense: Module
        if isMoE {
            guard let shared = children["shared_expert"] else { throw ProbeError("Missing Qwen shared expert") }
            dense = shared
        } else { dense = module }
        let weights = try FFNWeights(module: dense, path: path, requireTwoWaySplit: requireTwoWaySplit)
        for projection in [weights.gate, weights.up, weights.down] {
            types.insert(String(describing: projection.scales.dtype))
        }
        if isMoE {
            try validateRoutedQwenFFN(children: children, hidden: weights.gate.shape.1,
                                     requireTwoWaySplit: requireTwoWaySplit, types: &types)
        }
    }
    return types.sorted()
}

private func validateRoutedQwenFFN(children: [String: Module], hidden: Int,
                                 requireTwoWaySplit: Bool, types: inout Set<String>) throws {
    guard let experts = children["switch_mlp"] as? SwitchGLU, experts.hasFusedGateUp else {
        throw ProbeError("Qwen MoE adapter requires already-fused gate/up expert projections")
    }
    let parameters = Dictionary(uniqueKeysWithValues: experts.parameters().flattened())
    guard let down = parameters["down_proj.weight"], down.ndim == 3,
        down.dim(1) == hidden, down.dtype == .uint32 else {
        throw ProbeError("Invalid quantized Qwen expert bank")
    }
    let expertCount = down.dim(0), intermediate = down.dim(2) * 8
    guard intermediate % (requireTwoWaySplit ? 128 : 64) == 0 else {
        throw ProbeError("Qwen expert width cannot be split on complete G64 groups")
    }
    let plan = try ExpertPartitionPlan(inputDims: hidden, intermediateDims: intermediate,
        numExperts: expertCount, interval: 0..<intermediate, activation: .silu,
        fusedGateUp: true, projectionBits: ["gate_up_proj": 4, "down_proj": 4])
    guard Set(parameters.keys) == Set(plan.parameterNames) else {
        throw ProbeError("Unexpected Qwen expert tensors or ordinary expert bias")
    }
    let projections = Dictionary(uniqueKeysWithValues: experts.namedModules())
    for name in ["gate_up_proj", "down_proj"] {
        guard let projection = projections[name] as? QuantizedSwitchLinear,
            projection.mode == .affine, projection.bits == 4, projection.groupSize == 64 else {
            throw ProbeError("Qwen expert projections require affine W4/G64")
        }
    }
    for (name, value) in parameters {
        _ = try plan.selection(name: name, shape: value.shape)
        guard name.hasSuffix(".weight") ? value.dtype == .uint32
            : [.float32, .float16, .bfloat16].contains(value.dtype) else {
            throw ProbeError("Invalid Qwen expert tensor dtype")
        }
        if name.hasSuffix(".scales") { types.insert(String(describing: value.dtype)) }
    }
    for name in ["gate", "shared_expert_gate"] {
        guard let projection = children[name] as? QuantizedLinear,
            projection.mode == .affine, projection.bits == 4, projection.groupSize == 64,
            projection.weight.dtype == .uint32, projection.bias == nil, projection.biases != nil,
            projection.shape.1 == hidden,
            projection.shape.0 == (name == "gate" ? expertCount : 1) else {
            throw ProbeError("Invalid replicated Qwen router/shared gate: \(name)")
        }
        types.insert(String(describing: projection.scales.dtype))
    }
}
