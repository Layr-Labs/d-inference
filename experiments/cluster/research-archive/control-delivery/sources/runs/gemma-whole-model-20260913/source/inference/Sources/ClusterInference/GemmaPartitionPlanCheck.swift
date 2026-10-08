import Foundation

/// Pure configuration/shape checks. No constructor, tensor, GPU, files or
/// collectives are involved; whole-model numerical parity is a separate gate.
func checkGemmaPartitionPlan() throws {
    var accepted = 0
    var rejected = 0
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError("Gemma plan check: " + message) }
        accepted += 1
    }
    func reject(_ name: String, _ body: () throws -> Void) throws {
        do { try body() }
        catch { rejected += 1; return }
        throw ProbeError("Gemma plan check accepted invalid fixture: " + name)
    }
    func data(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    func fixture(bits: Int, mixed: Bool) -> [String: Any] {
        let text: [String: Any] = [
            "model_type": "gemma4_text", "hidden_size": 2816, "num_hidden_layers": 30,
            "intermediate_size": 2112, "num_attention_heads": 16, "num_key_value_heads": 8,
            "num_global_key_value_heads": 2, "head_dim": 256, "global_head_dim": 512,
            "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 0,
            "vocab_size_per_layer_input": 262144, "vocab_size": 262144,
            "use_double_wide_mlp": false, "tie_word_embeddings": true,
            "enable_moe_block": true, "num_experts": 128, "top_k_experts": 8,
            "moe_intermediate_size": 704, "attention_k_eq_v": true,
            "hidden_activation": "gelu_pytorch_tanh", "use_bidirectional_attention": "vision",
            "layer_types": (0..<30).map { ($0 + 1) % 6 == 0 ? "full_attention" : "sliding_attention" },
        ]
        var quantization: [String: Any] = ["bits": bits, "group_size": 64, "mode": "affine"]
        if mixed {
            for layer in 0..<30 {
                for path in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"] {
                    quantization["language_model.model.layers.\(layer)." + path] =
                        ["bits": 8, "group_size": 64, "mode": "affine"]
                }
            }
        }
        return ["model_type": "gemma4", "text_config": text,
                "quantization": quantization, "quantization_config": quantization]
    }
    let prefix = "language_model.model.layers.0."
    for (bits, mixed) in [(8, false), (4, true)] {
        let source = try data(fixture(bits: bits, mixed: mixed))
        let plan = try GemmaPartitionPlan(configuration: source)
        try require(plan.denseIntervals == [0..<1024, 1024..<2112], "dense G64 intervals")
        try require(plan.expertIntervals == [0..<320, 320..<704], "expert G64 intervals")
        try require(plan.expectedSourceShapes.count == 1339, "actual 26B text tensor count")
        try require(plan.normalizationInputPaths.count == 60, "two separate branch reductions per layer")
        try require(plan.expectedSourceShapes["language_model.model.layers.5.self_attn.v_proj.weight"] == nil,
                    "full attention K=V must not allocate V")
        try require(plan.expectedSourceShapes[prefix + "self_attn.v_proj.weight"] != nil,
                    "sliding attention keeps V")
        try require(plan.fingerprint == GemmaPartitionPlan(configuration: source).fingerprint,
                    "deterministic plan fingerprint")
        let localPlans = try (0..<2).map { rank in
            try GemmaPartitionPlan(configuration: plan.constructionConfiguration(rank: rank))
        }
        var bytes = [0, 0]
        var shardedCount = 0
        for name in plan.expectedSourceShapes.keys.sorted() {
            let shape = plan.expectedSourceShapes[name]!
            let selections = try (0..<2).map { try plan.selection(name: name, shape: shape, rank: $0) }
            let scalarBytes = name.hasSuffix(".weight") && shape.count > 1 ? 4 : 2
            for rank in 0..<2 {
                let result = try selections[rank].resultShape(shape)
                try require(result == localPlans[rank].expectedSourceShapes[name], "selected shape matches rank constructor: \(name)")
                bytes[rank] += result.reduce(1, *) * scalarBytes
            }
            if case .axis(let axis0, let ranges0) = selections[0] {
                guard case .axis(let axis1, let ranges1) = selections[1] else {
                    throw ProbeError("Gemma plan check found one-sided partition")
                }
                try require(axis0 == axis1 && ranges0.count == 1 && ranges1.count == 1
                    && ranges0[0].lowerBound == 0 && ranges0[0].upperBound == ranges1[0].lowerBound
                    && ranges1[0].upperBound == shape[axis0], "complete disjoint rank coverage")
                try require(plan.isFeedForwardTensor(name: name), "only FFN tensors are split")
                shardedCount += 1
            } else {
                try require(selections[1] == .all, "replicated tensors agree")
            }
        }
        try require(shardedCount == 540, "actual 26B sharded tensor count")
        try require(bytes == (mixed ? [7_167_602_748, 8_352_688_188] : [13_282_242_620, 15_505_418_300]),
                    "independent metadata audit byte totals, including unequal ownership")
        try require(plan.selection(name: prefix + "router.proj.weight",
            shape: [128, 704], rank: 0) == .all, "router stays globally indexed and replicated")
        try require(!plan.isFeedForwardTensor(name: prefix + "post_feedforward_layernorm_1.weight"),
                    "norms excluded from FFN bytes")
        try reject("wrong packed dense divisor") {
            _ = try plan.selection(name: prefix + "mlp.gate_proj.weight", shape: [2112, 352], rank: 0)
        }
        try reject("ordinary projection bias") {
            _ = try plan.selection(name: prefix + "mlp.down_proj.bias", shape: [2816], rank: 0)
        }
        try reject("raw or fused expert names") {
            _ = try plan.selection(name: prefix + "experts.gate_up_proj", shape: [128, 1408, 2816], rank: 0)
        }
        try reject("invalid rank") { _ = try plan.constructionConfiguration(rank: 2) }
        let record: [String: Any] = ["type": "gemma_partition_plan", "scope": "metadata_only",
            "defaultBits": bits, "mixedDenseRouterW8": mixed, "sourceTensorCount": 1339,
            "shardedTensorCount": shardedCount, "rankTensorBytes": bytes,
            "rankIntermediate": [1024, 1088], "rankExpertIntermediate": [320, 384],
            "partitionPlanSHA256": plan.fingerprint]
        print(String(decoding: try data(record), as: UTF8.self))
    }

    // The same configuration cut must remain valid for double-wide shared-KV
    // layers and replicated per-layer inputs; use a small dense text variant.
    let dense: [String: Any] = [
        "model_type": "gemma4_text", "hidden_size": 128, "num_hidden_layers": 4,
        "intermediate_size": 192, "num_attention_heads": 4, "num_key_value_heads": 2,
        "head_dim": 64, "global_head_dim": 64, "num_kv_shared_layers": 2,
        "hidden_size_per_layer_input": 64, "vocab_size_per_layer_input": 512, "vocab_size": 512,
        "use_double_wide_mlp": true, "tie_word_embeddings": false, "enable_moe_block": false,
        "layer_types": ["sliding_attention", "full_attention", "sliding_attention", "full_attention"],
        "quantization": ["bits": 4, "group_size": 64, "mode": "affine"],
    ]
    let plan = try GemmaPartitionPlan(configuration: data(dense))
    try require(plan.denseIntervals == [0..<64, 64..<192], "odd dense group split")
    try require(plan.normalizationInputPaths == (0..<4).map { "model.layers.\($0).post_feedforward_layernorm" },
                "dense-only reduction before the final FFN norm")
    // Rank0's local base width is one group and cannot itself be split again.
    // Validate construction values directly instead of recursively planning TP.
    for rank in 0..<2 {
        let configuration = try JSONSerialization.jsonObject(with: plan.constructionConfiguration(rank: rank)) as! [String: Any]
        try require(configuration["intermediate_size"] as? Int == [64, 128][rank], "rank-specific base width")
        try require(configuration["num_kv_shared_layers"] as? Int == 2, "KV-sharing configuration preserved")
        try require(configuration["hidden_size_per_layer_input"] as? Int == 64, "PLE configuration preserved")
        try require(configuration["use_double_wide_mlp"] as? Bool == true, "double-wide constructor policy preserved")
    }
    for layer in 0..<4 {
        let width = layer < 2 ? 192 : 384
        let expected = layer < 2 ? [64, 128] : [128, 256]
        for rank in 0..<2 {
            let selection = try plan.selection(name: "model.layers.\(layer).mlp.gate_proj.weight",
                                              shape: [width, 16], rank: rank)
            try require(selection.resultShape([width, 16]) == [expected[rank], 16], "double-wide layer source interval")
        }
        if layer >= 2 {
            try require(plan.expectedSourceShapes["model.layers.\(layer).self_attn.k_proj.weight"] == nil,
                        "shared-KV layers own no K projection")
        }
    }
    try require(plan.selection(name: "model.per_layer_model_projection.weight", shape: [256, 128], rank: 0) == .all,
                "unquantized PLE ScaledLinear stays replicated")
    try require(plan.selection(name: "model.layers.0.per_layer_input_gate.weight", shape: [64, 16], rank: 1) == .all,
                "PLE gating stays replicated")

    func rejectMutation(_ name: String, _ mutate: (inout [String: Any]) -> Void) throws {
        var changed = dense
        mutate(&changed)
        try reject(name) { _ = try GemmaPartitionPlan(configuration: data(changed)) }
    }
    try rejectMutation("partial G64 width") { $0["intermediate_size"] = 160 }
    try rejectMutation("single group has an empty rank") { $0["intermediate_size"] = 64 }
    try rejectMutation("boolean width") { $0["intermediate_size"] = true }
    try rejectMutation("all KV layers shared") { $0["num_kv_shared_layers"] = 4 }
    try rejectMutation("missing shared-KV source type") { $0["layer_types"] = ["sliding_attention", "sliding_attention", "full_attention", "sliding_attention"] }
    try rejectMutation("truncated layer schedule") { $0["layer_types"] = ["full_attention"] }
    try rejectMutation("zero schedule interval before decoder") { $0["sliding_window_pattern"] = 0 }
    try rejectMutation("unsupported activation") { $0["hidden_activation"] = "silu" }
    try rejectMutation("attention bias") { $0["attention_bias"] = true }
    try rejectMutation("global bidirectional attention") { $0["use_bidirectional_attention"] = "all" }
    try rejectMutation("conflicting quantization copies") { $0["quantization_config"] = ["bits": 8, "group_size": 64] }
    try rejectMutation("unsupported packing") { $0["quantization"] = ["bits": 2, "group_size": 64] }
    try rejectMutation("unsupported group size") { $0["quantization"] = ["bits": 4, "group_size": 32] }
    try rejectMutation("skip sharded projection") {
        $0["quantization"] = ["bits": 4, "group_size": 64, "model.layers.0.mlp.gate_proj": false]
    }
    try rejectMutation("ignored true quantization override") {
        $0["quantization"] = ["bits": 4, "group_size": 64, "model.layers.0.mlp.gate_proj": true]
    }
    try rejectMutation("unknown quantization alias") {
        $0["quantization"] = ["bits": 4, "group_size": 64, "language_model.model.layers.0.mlp.gate_proj": ["bits": 8, "group_size": 64]]
    }
    try reject("unsupported full partition") { _ = try GemmaPartitionPlan(configuration: data(dense), kind: .full) }
    var invalidMoE = fixture(bits: 8, mixed: false)
    var text = invalidMoE["text_config"] as! [String: Any]
    text["top_k_experts"] = 129
    invalidMoE["text_config"] = text
    try reject("global top-k exceeds expert count") { _ = try GemmaPartitionPlan(configuration: data(invalidMoE)) }
    print(String(decoding: try data(["type": "gemma_partition_plan_checks", "scope": "metadata_only",
                                    "acceptedChecks": accepted, "rejectedFixtures": rejected]), as: UTF8.self))
}
