import Foundation

/// Pure configuration and physical-selection checks: no model construction,
/// weights, GPU work, routing execution or distributed performance claim.
func checkQwenMoEPartitionPlan() throws {
    let text: [String: Any] = [
        "model_type": "qwen3_5_moe_text", "hidden_size": 2048,
        "num_hidden_layers": 40, "full_attention_interval": 4,
        "num_experts": 256, "num_experts_per_tok": 8,
        "moe_intermediate_size": 512, "shared_expert_intermediate_size": 512,
        "hidden_act": "silu", "mlp_only_layers": [Int](),
        "num_attention_heads": 16, "num_key_value_heads": 2, "head_dim": 256,
        "linear_num_key_heads": 16, "linear_num_value_heads": 32,
        "linear_key_head_dim": 128, "linear_value_head_dim": 128,
        "linear_conv_kernel_dim": 4,
        "layer_types": (0..<40).map { ($0 + 1) % 4 == 0 ? "full_attention" : "linear_attention" },
    ]
    func data(_ text: [String: Any], nested: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: nested
            ? ["model_type": "qwen3_5_moe", "text_config": text,
               "quantization": ["group_size": 64, "bits": 4, "mode": "affine"]] : text,
            options: [.sortedKeys])
    }
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ProbeError("Qwen MoE planner check: \(message)") }
    }
    var rejections = 0
    func reject(_ body: () throws -> Void) throws {
        do { try body() } catch { rejections += 1; return }
        throw ProbeError("Qwen MoE planner accepted an invalid contract")
    }

    let configuration = try data(text)
    let plan = try QwenPartitionPlan(configuration: configuration, kind: .ffn)
    let full = try QwenPartitionPlan(configuration: configuration, kind: .full)
    let bare = try QwenPartitionPlan(configuration: data(text, nested: false), kind: .ffn)
    let changedRoot = try JSONSerialization.jsonObject(with: plan.constructionConfiguration) as! [String: Any]
    let changed = changedRoot["text_config"] as! [String: Any]
    try require(plan.isMoE && full.isMoE && bare.isMoE, "sparse family not detected")
    try require(changed["intermediate_size"] == nil, "invented the absent dense width")
    try require(changed["moe_intermediate_size"] as? Int == 256
        && changed["shared_expert_intermediate_size"] as? Int == 256,
        "both branch widths must halve")
    try require(changed["num_experts"] as? Int == 256 && changed["num_experts_per_tok"] as? Int == 8,
        "global routing geometry changed")
    try require(changed["norm_topk_prob"] == nil, "changed the source routing normalization policy")
    let changedFullRoot = try JSONSerialization.jsonObject(with: full.constructionConfiguration) as! [String: Any]
    let changedFull = changedFullRoot["text_config"] as! [String: Any]
    try require(changedFull["num_key_value_heads"] as? Int == 1
        && changedFull["num_attention_heads"] as? Int == 8
        && changedFull["linear_num_key_heads"] as? Int == 8
        && changedFull["linear_num_value_heads"] as? Int == 16
        && changedFull["head_dim"] as? Int == 256, "full plan lost head partition composition")
    try require(plan.fingerprint != full.fingerprint, "full/FFN identity collided")

    // Independent expected physical ranges, including BOTH fused gate/up halves.
    var selections = 0
    for rank in 0..<2 {
        for parameter in ["weight", "scales", "biases"] {
            let packing = parameter == "weight" ? 8 : 64
            let cases: [(String, [Int], TensorSelection)] = [
                ("switch_mlp.gate_up_proj", [256, 1024, 2048 / packing],
                    .axis(1, [(rank * 256)..<((rank + 1) * 256),
                              (512 + rank * 256)..<(512 + (rank + 1) * 256)])),
                ("switch_mlp.down_proj", [256, 2048, 512 / packing],
                    .axis(2, [(rank * 256 / packing)..<((rank + 1) * 256 / packing)])),
                ("shared_expert.gate_proj", [512, 2048 / packing],
                    .axis(0, [(rank * 256)..<((rank + 1) * 256)])),
                ("shared_expert.up_proj", [512, 2048 / packing],
                    .axis(0, [(rank * 256)..<((rank + 1) * 256)])),
                ("shared_expert.down_proj", [2048, 512 / packing],
                    .axis(1, [(rank * 256 / packing)..<((rank + 1) * 256 / packing)])),
                ("gate", [256, 2048 / packing], .all),
                ("shared_expert_gate", [1, 2048 / packing], .all),
            ]
            for (path, shape, expected) in cases {
                let name = "language_model.model.layers.0.mlp.\(path).\(parameter)"
                for candidate in [plan, full, bare] {
                    let selection = try candidate.selection(name: name, shape: shape, rank: rank)
                    try require(selection == expected, "wrong routed/shared selection for \(name)")
                    let selected = try selection.resultShape(shape)
                    try require(selected.reduce(1, *) == shape.reduce(1, *) / (expected == .all ? 1 : 2),
                        "selection has incorrect payload size")
                    if path.hasPrefix("switch_mlp") {
                        try require(selected[0] == 256, "selection renumbered/dropped global experts")
                    }
                    selections += 1
                }
            }
        }
    }
    let gdn = try full.selection(name: "model.layers.0.linear_attn.in_proj_qkv.weight", shape: [8192, 256], rank: 1)
    try require(gdn == .axis(0, [1024..<2048, 3072..<4096, 6144..<8192]), "GDN segment layout changed")
    let attention = try full.selection(name: "model.layers.3.self_attn.o_proj.weight", shape: [2048, 512], rank: 1)
    try require(attention == .axis(1, [256..<512]), "attention output selection changed")

    for (key, value) in [("num_experts", 0 as Any), ("num_experts", true as Any),
                         ("num_experts_per_tok", 257 as Any), ("num_experts_per_tok", 0 as Any),
                         ("moe_intermediate_size", 704 as Any), ("shared_expert_intermediate_size", 64 as Any),
                         ("decoder_sparse_step", 2 as Any), ("mlp_only_layers", [1] as Any),
                         ("norm_topk_prob", 1 as Any), ("hidden_act", "gelu" as Any),
                         ("layer_types", ["full_attention"] as Any)] {
        var invalid = text; invalid[key] = value
        try reject { _ = try QwenPartitionPlan(configuration: data(invalid), kind: .ffn) }
    }
    for key in ["num_experts_per_tok", "moe_intermediate_size", "shared_expert_intermediate_size"] {
        var invalid = text; invalid.removeValue(forKey: key)
        try reject { _ = try QwenPartitionPlan(configuration: data(invalid), kind: .ffn) }
    }
    for (path, shape, rank) in [
        ("switch_mlp.gate_proj.weight", [256, 512, 256], 0),
        ("switch_mlp.gate_up_proj.weight", [128, 1024, 256], 0),
        ("switch_mlp.down_proj.weight", [256, 2048, 128], 0),
        ("switch_mlp.down_proj.scales", [256, 2048, 16], 0),
        ("switch_mlp.down_proj.bias", [256, 2048], 0),
        ("gate.weight", [128, 256], 0), ("shared_expert_gate.weight", [256, 256], 0),
        ("shared_expert.gate_proj.weight", [256, 256], 0),
        ("shared_expert.unknown.weight", [512, 256], 0),
        ("gate.weight", [256, 256], 2),
    ] {
        try reject { _ = try plan.selection(name: "model.layers.0.mlp.\(path)", shape: shape, rank: rank) }
    }

    var dense = text
    for key in ["num_experts", "num_experts_per_tok", "moe_intermediate_size", "shared_expert_intermediate_size"] {
        dense.removeValue(forKey: key)
    }
    dense["model_type"] = "qwen3_5_text"; dense["intermediate_size"] = 512
    let denseData = try data(dense, nested: false)
    let densePlan = try QwenPartitionPlan(configuration: denseData, kind: .ffn)
    try require(!densePlan.isMoE && densePlan.fingerprint != bare.fingerprint, "dense/sparse identity collided")
    let denseSelection = try densePlan.selection(name: "model.layers.0.mlp.down_proj.weight", shape: [2048, 64], rank: 1)
    try require(denseSelection == .axis(1, [32..<64]), "dense FFN selection regressed")
    let denseChanged = try JSONSerialization.jsonObject(with: densePlan.constructionConfiguration) as! [String: Any]
    try require(denseChanged["intermediate_size"] as? Int == 256, "dense construction width regressed")
    for source in [configuration, denseData] {
        for kind in [QwenPartitionKind.ffn, .full] {
            let native = try QwenPartitionPlan(configuration: source, kind: kind)
            let wide = try QwenPartitionPlan(configuration: source, kind: kind,
                                              attentionOutputPrecision: .float32)
            try require(native.fingerprint != wide.fingerprint,
                        "different numerical policies share an execution identity")
            try require(native.constructionConfiguration == wide.constructionConfiguration,
                        "output arithmetic policy changed checkpoint construction geometry")
        }
    }
    for kind in [QwenPartitionKind.ffn, .full] {
        let native = try QwenPartitionPlan(configuration: denseData, kind: kind)
        let wide = try QwenPartitionPlan(configuration: denseData, kind: kind,
                                          ffnOutputPrecision: .float32)
        try require(native.fingerprint != wide.fingerprint,
                    "FFN output precision is missing from the execution identity")
        try require(native.constructionConfiguration == wide.constructionConfiguration,
                    "FFN output precision changed checkpoint geometry")
        for rank in 0..<2 {
            try require(native.selection(name: "model.layers.0.mlp.down_proj.weight", shape: [2048, 64], rank: rank)
                        == wide.selection(name: "model.layers.0.mlp.down_proj.weight", shape: [2048, 64], rank: rank),
                        "FFN output precision changed packed tensor ownership")
        }
        try reject { _ = try QwenPartitionPlan(configuration: configuration, kind: kind,
                                                 ffnOutputPrecision: .float32) }
    }

    struct Result: Encodable {
        let kind = "qwen_moe_partition_plan"
        let metadataOnly = true
        let checkedSelections: Int
        let rejectedInvalidContracts: Int
        let sourceExpertCount = 256
        let sourceExpertWidth = 512
        let localExpertWidth = 256
        let sourceSharedWidth = 512
        let localSharedWidth = 256
        let canonicalFusedGateUp = true
        let densePlanPreserved = true
        let attentionPrecisionBoundIntoIdentity = true
        let ffnOutputPrecisionBoundIntoIdentity = true
        let modelExecutionCompared = false
        let exactCheckpointLoaded = false
    }
    try emitJSON(Result(checkedSelections: selections, rejectedInvalidContracts: rejections))
}
