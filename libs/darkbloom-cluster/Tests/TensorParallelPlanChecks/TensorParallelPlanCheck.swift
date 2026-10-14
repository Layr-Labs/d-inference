import Foundation

// Model-free checks of `QwenTensorParallelPlan`: for every tensor of a dense
// Qwen 3.5-family checkpoint, the ranks' cuts must cover the tensor exactly
// once (rows or quantized input columns) or replicate it, and every cut must
// have the shape the rank's divided configuration constructs. With a model
// directory, the same is checked against the checkpoint's own tensor names and
// shapes (safetensors headers only; no tensor payload is read).

nonisolated(unsafe) var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) {
    if !condition() { failures += 1; print("FAIL: \(message())") }
}
func expectThrows(_ label: String, _ body: () throws -> Void) {
    do { try body(); failures += 1; print("FAIL: expected a refusal: \(label)") } catch {}
}

struct Tensor { let name: String; let shape: [Int]; let dtype: String }

func syntheticConfiguration(hidden: Int, layers: Int, heads: Int, kv: Int, linearK: Int, linearV: Int,
                            intermediate: Int) -> [String: Any] {
    ["model_type": "qwen3_5_text", "hidden_size": hidden, "num_hidden_layers": layers, "full_attention_interval": 4,
     "num_attention_heads": heads, "num_key_value_heads": kv, "head_dim": 256, "linear_num_key_heads": linearK,
     "linear_num_value_heads": linearV, "linear_key_head_dim": 128, "linear_value_head_dim": 128,
     "intermediate_size": intermediate, "vocab_size": 248_320, "tie_word_embeddings": false, "attn_output_gate": true,
     "linear_conv_kernel_dim": 4, "mtp_num_hidden_layers": 1]
}

/// The tensors a 4-bit group-64 checkpoint of this configuration holds.
func syntheticTensors(_ c: [String: Any]) -> [Tensor] {
    let h = c["hidden_size"] as! Int, layers = c["num_hidden_layers"] as! Int
    let hq = c["num_attention_heads"] as! Int, hkv = c["num_key_value_heads"] as! Int, hd = 256
    let lk = c["linear_num_key_heads"] as! Int * 128, lv = c["linear_num_value_heads"] as! Int * 128
    let nv = c["linear_num_value_heads"] as! Int, inter = c["intermediate_size"] as! Int, vocab = 248_320
    func q(_ name: String, _ out: Int, _ input: Int) -> [Tensor] {
        [Tensor(name: name + ".weight", shape: [out, input / 8], dtype: "U32"),
         Tensor(name: name + ".scales", shape: [out, input / 64], dtype: "BF16"),
         Tensor(name: name + ".biases", shape: [out, input / 64], dtype: "BF16")]
    }
    var all: [Tensor] = q("language_model.model.embed_tokens", vocab, h) + q("language_model.lm_head", vocab, h)
    all.append(Tensor(name: "language_model.model.norm.weight", shape: [h], dtype: "BF16"))
    for layer in 0..<layers {
        let p = "language_model.model.layers.\(layer)."
        all += [Tensor(name: p + "input_layernorm.weight", shape: [h], dtype: "BF16"),
                Tensor(name: p + "post_attention_layernorm.weight", shape: [h], dtype: "BF16")]
        all += q(p + "mlp.gate_proj", inter, h) + q(p + "mlp.up_proj", inter, h) + q(p + "mlp.down_proj", h, inter)
        if (layer + 1) % 4 != 0 {
            all += q(p + "linear_attn.in_proj_qkv", 2 * lk + lv, h) + q(p + "linear_attn.in_proj_z", lv, h)
                + q(p + "linear_attn.in_proj_b", nv, h) + q(p + "linear_attn.in_proj_a", nv, h)
                + q(p + "linear_attn.out_proj", h, lv)
            all += [Tensor(name: p + "linear_attn.conv1d.weight", shape: [2 * lk + lv, 4, 1], dtype: "BF16"),
                    Tensor(name: p + "linear_attn.A_log", shape: [nv], dtype: "F32"),
                    Tensor(name: p + "linear_attn.dt_bias", shape: [nv], dtype: "BF16"),
                    Tensor(name: p + "linear_attn.norm.weight", shape: [128], dtype: "F32")]
        } else {
            all += q(p + "self_attn.q_proj", 2 * hq * hd, h) + q(p + "self_attn.k_proj", hkv * hd, h)
                + q(p + "self_attn.v_proj", hkv * hd, h) + q(p + "self_attn.o_proj", h, hq * hd)
            all += [Tensor(name: p + "self_attn.q_norm.weight", shape: [hd], dtype: "BF16"),
                    Tensor(name: p + "self_attn.k_norm.weight", shape: [hd], dtype: "BF16")]
        }
    }
    all += q("mtp.fc", h, 2 * h) + [Tensor(name: "mtp.norm.weight", shape: [h], dtype: "BF16")]
    return all
}

/// The shape of a cut of `tensor`.
func cutShape(_ tensor: Tensor, _ cut: QwenTensorParallelPlan.Cut, _ plan: QwenTensorParallelPlan) -> [Int]? {
    var shape = tensor.shape
    switch cut {
    case .replicate: return shape
    case .rows(let ranges):
        guard ranges.allSatisfy({ $0.lowerBound >= 0 && $0.upperBound <= shape[0] }) else { return nil }
        shape[0] = ranges.reduce(0) { $0 + $1.count }
        return shape
    case .inputColumns(let logical):
        let leaf = tensor.name.split(separator: ".").last!
        let divisor = leaf == "weight" ? 32 / plan.bits : plan.groupSize
        guard shape.count == 2, logical.lowerBound % divisor == 0, logical.upperBound % divisor == 0,
              logical.upperBound / divisor <= shape[1] else { return nil }
        shape[1] = logical.count / divisor
        return shape
    case .expertRows(let range):
        guard shape.count == 3, range.upperBound <= shape[1] else { return nil }
        shape[1] = range.count
        return shape
    case .expertInputColumns(let logical):
        let leaf = tensor.name.split(separator: ".").last!
        let divisor = leaf == "weight" ? 32 / plan.bits : plan.groupSize
        guard shape.count == 3, logical.lowerBound % divisor == 0, logical.upperBound % divisor == 0,
              logical.upperBound / divisor <= shape[2] else { return nil }
        shape[2] = logical.count / divisor
        return shape
    }
}

/// Every element of the tensor covered exactly once across ranks (or replicated by all).
func coverage(_ tensor: Tensor, _ cuts: [QwenTensorParallelPlan.Cut], _ plan: QwenTensorParallelPlan) -> Bool {
    if cuts.allSatisfy({ $0 == .replicate }) { return true }
    if case .rows = cuts[0] {
        var seen = [Int](repeating: 0, count: tensor.shape[0])
        for cut in cuts {
            guard case .rows(let ranges) = cut else { return false }
            for range in ranges { for row in range where row < seen.count { seen[row] += 1 } }
        }
        return seen.allSatisfy { $0 == 1 }
    }
    if case .expertRows = cuts[0] {
        var seen = [Int](repeating: 0, count: tensor.shape[1])
        for cut in cuts {
            guard case .expertRows(let range) = cut else { return false }
            for row in range where row < seen.count { seen[row] += 1 }
        }
        return seen.allSatisfy { $0 == 1 }
    }
    let leaf = tensor.name.split(separator: ".").last!
    let divisor = leaf == "weight" ? 32 / plan.bits : plan.groupSize
    if case .expertInputColumns = cuts[0] {
        var seen = [Int](repeating: 0, count: tensor.shape[2])
        for cut in cuts {
            guard case .expertInputColumns(let logical) = cut else { return false }
            for column in (logical.lowerBound / divisor) ..< (logical.upperBound / divisor) where column < seen.count { seen[column] += 1 }
        }
        return seen.allSatisfy { $0 == 1 }
    }
    var seen = [Int](repeating: 0, count: tensor.shape[1])
    for cut in cuts {
        guard case .inputColumns(let logical) = cut else { return false }
        for column in (logical.lowerBound / divisor) ..< (logical.upperBound / divisor) where column < seen.count { seen[column] += 1 }
    }
    return seen.allSatisfy { $0 == 1 }
}

/// The shape the rank's divided configuration constructs for a tensor.
func constructedShape(_ name: String, _ tensor: Tensor, _ shard: [String: Any], _ plan: QwenTensorParallelPlan,
                      rank: Int) -> [Int]? {
    let h = shard["hidden_size"] as! Int, hq = shard["num_attention_heads"] as! Int, hkv = shard["num_key_value_heads"] as! Int
    let lk = (shard["linear_num_key_heads"] as! Int) * 128, lv = (shard["linear_num_value_heads"] as! Int) * 128
    let nv = shard["linear_num_value_heads"] as! Int
    let inter = (shard["intermediate_size"] ?? shard["moe_intermediate_size"]) as! Int
    let shared = shard["shared_expert_intermediate_size"] as? Int ?? 0
    let experts = shard["num_experts"] as? Int ?? 0
    let vocab = plan.vocabularyRange(rank: rank).count
    let leaf = String(name.split(separator: ".").last!)
    func q(_ out: Int, _ input: Int) -> [Int]? {
        switch leaf {
        case "weight": return [out, input * plan.bits / 32]
        case "scales", "biases": return [out, input / plan.groupSize]
        default: return nil
        }
    }
    func e(_ out: Int, _ input: Int) -> [Int]? { q(out, input).map { [experts] + $0 } }
    let table: [(String, () -> [Int]?)] = [
        (".mlp.switch_mlp.gate_proj.", { e(inter, h) }), (".mlp.switch_mlp.up_proj.", { e(inter, h) }),
        (".mlp.switch_mlp.down_proj.", { e(h, inter) }),
        (".mlp.shared_expert.gate_proj.", { q(shared, h) }), (".mlp.shared_expert.up_proj.", { q(shared, h) }),
        (".mlp.shared_expert.down_proj.", { q(h, shared) }),
        (".self_attn.q_proj.", { q(2 * hq * 256, h) }), (".self_attn.k_proj.", { q(hkv * 256, h) }),
        (".self_attn.v_proj.", { q(hkv * 256, h) }), (".self_attn.o_proj.", { q(h, hq * 256) }),
        (".linear_attn.in_proj_qkv.", { q(2 * lk + lv, h) }), (".linear_attn.in_proj_z.", { q(lv, h) }),
        (".linear_attn.in_proj_b.", { q(nv, h) }), (".linear_attn.in_proj_a.", { q(nv, h) }),
        (".linear_attn.out_proj.", { q(h, lv) }), (".linear_attn.conv1d.weight", { [2 * lk + lv, tensor.shape[1], 1] }),
        (".linear_attn.A_log", { [nv] }), (".linear_attn.dt_bias", { [nv] }),
        (".mlp.gate_proj.", { q(inter, h) }), (".mlp.up_proj.", { q(inter, h) }), (".mlp.down_proj.", { q(h, inter) }),
        ("language_model.lm_head.", { q(vocab, h) }),
    ]
    for (fragment, shape) in table where name.contains(fragment) { return shape() }
    return tensor.shape // replicated tensors keep the checkpoint shape
}

func checkPlan(_ label: String, configuration: [String: Any], tensors: [Tensor], quantization: [String: Any],
               shares: [Int]? = nil) {
    let plan: QwenTensorParallelPlan
    do {
        plan = try QwenTensorParallelPlan(textConfiguration: configuration, quantization: quantization, size: 2, shares: shares)
    } catch {
        failures += 1; print("FAIL: \(label): plan refused: \(error)"); return
    }
    let shards = (0..<2).map { plan.shardTextConfiguration(configuration, rank: $0) }
    var loaded = 0, skipped = 0, rowParallel = Set<String>()
    for tensor in tensors {
        let dispositions = (0..<2).compactMap { try? plan.disposition(key: tensor.name, rank: $0) }
        guard dispositions.count == 2 else { failures += 1; print("FAIL: \(label): no disposition for \(tensor.name)"); continue }
        if dispositions[0] == .skip {
            check(dispositions[1] == .skip, "\(label): \(tensor.name) skipped on one rank only")
            skipped += 1; continue
        }
        let cuts = dispositions.compactMap { d -> QwenTensorParallelPlan.Cut? in if case .load(let c) = d { return c }; return nil }
        check(cuts.count == 2, "\(label): \(tensor.name) loaded on one rank only")
        check(coverage(tensor, cuts, plan), "\(label): \(tensor.name) not covered exactly once")
        for (rank, cut) in cuts.enumerated() {
            let got = cutShape(tensor, cut, plan)
            let want = constructedShape(tensor.name, tensor, shards[rank], plan, rank: rank)
            check(got != nil && got == want, "\(label): \(tensor.name) rank \(rank) cut \(String(describing: got)) != constructed \(String(describing: want))")
            switch cut {
            case .inputColumns, .expertInputColumns: rowParallel.insert(tensor.name.split(separator: ".").dropLast().joined(separator: "."))
            default: break
            }
        }
        loaded += 1
    }
    check(rowParallel == Set(plan.inputColumnModulePaths()), "\(label): input-column modules differ from the plan's list")
    check(plan.rowParallelModulePaths().count == 2 * plan.layerCount, "\(label): two reductions per layer")
    check(plan.reductionsPerForward == 2 * plan.layerCount, "\(label): reductions per forward")
    print("\(label): \(loaded) tensors cut or replicated, \(skipped) skipped, \(rowParallel.count) row-parallel projections")
}

/// A 35B-A3B-shaped routed-expert model: every expert divided by its
/// intermediate channels, the shared expert like a dense MLP, the router and
/// the shared expert's gate replicated; two reductions per layer (the mixer
/// and the whole MLP block).
func syntheticMoEConfiguration() -> [String: Any] {
    var c = syntheticConfiguration(hidden: 2048, layers: 8, heads: 16, kv: 2, linearK: 16, linearV: 32, intermediate: 1)
    c.removeValue(forKey: "intermediate_size")
    c["model_type"] = "qwen3_5_moe_text"; c["num_experts"] = 16; c["num_experts_per_tok"] = 4
    c["moe_intermediate_size"] = 512; c["shared_expert_intermediate_size"] = 512
    return c
}

func syntheticMoETensors(_ c: [String: Any]) -> [Tensor] {
    var dense = c; dense["intermediate_size"] = 512; dense["model_type"] = "qwen3_5_text"
    let experts = c["num_experts"] as! Int, h = c["hidden_size"] as! Int, inter = c["moe_intermediate_size"] as! Int
    func q(_ name: String, _ out: Int, _ input: Int, experts e: Int? = nil) -> [Tensor] {
        let lead = e.map { [$0] } ?? []
        return [Tensor(name: name + ".weight", shape: lead + [out, input / 8], dtype: "U32"),
                Tensor(name: name + ".scales", shape: lead + [out, input / 64], dtype: "BF16"),
                Tensor(name: name + ".biases", shape: lead + [out, input / 64], dtype: "BF16")]
    }
    var all = syntheticTensors(dense).filter { !$0.name.contains(".mlp.") }
    for layer in 0..<(c["num_hidden_layers"] as! Int) {
        let p = "language_model.model.layers.\(layer).mlp."
        all += q(p + "gate", experts, h) + q(p + "shared_expert_gate", 1, h)
            + q(p + "switch_mlp.gate_proj", inter, h, experts: experts) + q(p + "switch_mlp.up_proj", inter, h, experts: experts)
            + q(p + "switch_mlp.down_proj", h, inter, experts: experts)
            + q(p + "shared_expert.gate_proj", inter, h) + q(p + "shared_expert.up_proj", inter, h)
            + q(p + "shared_expert.down_proj", h, inter)
    }
    return all
}

func checkRoutedExperts(quantization: [String: Any]) {
    let c = syntheticMoEConfiguration()
    for shares in [nil, [1, 3], [2, 3]] as [[Int]?] {
        checkPlan("synthetic A3B-shaped \(shares.map { "shares \($0)" } ?? "equal")", configuration: c,
                  tensors: syntheticMoETensors(c), quantization: quantization, shares: shares)
    }
    guard let plan = try? QwenTensorParallelPlan(textConfiguration: c, quantization: quantization, size: 2) else {
        failures += 1; print("FAIL: routed experts: plan refused"); return
    }
    check(plan.routedExperts && plan.expertCount == 16 && plan.intermediatePerRank == [256, 256]
          && plan.sharedExpertIntermediatePerRank == [256, 256], "routed experts: per-rank expert and shared widths")
    check((try? plan.disposition(key: "language_model.model.layers.0.mlp.gate.weight", rank: 1)) == .load(.replicate),
          "routed experts: the router is replicated")
    check((try? plan.disposition(key: "language_model.model.layers.0.mlp.switch_mlp.up_proj.weight", rank: 1)) == .load(.expertRows(256..<512)),
          "routed experts: rank 1 holds every expert's channels 256..<512")
    check(plan.rowParallelModulePaths().contains("language_model.model.layers.0.mlp"), "routed experts: the MLP block is reduced once")
    let s1 = plan.shardTextConfiguration(c, rank: 1)
    check(s1["moe_intermediate_size"] as? Int == 256 && s1["shared_expert_intermediate_size"] as? Int == 256
          && s1["num_key_value_heads"] as? Int == 1 && s1["intermediate_size"] == nil, "routed experts: rank 1 configuration")
    expectThrows("routed experts with dense-MLP layers") { var m = c; m["mlp_only_layers"] = [0]
        _ = try QwenTensorParallelPlan(textConfiguration: m, quantization: quantization, size: 2) }
    print("routed experts: plan covered (equal, 1:3, 2:3), dispositions and refusals checked")
}

/// Weighted shares for unequal Macs: every tensor still covered exactly once
/// with the shapes each rank's own configuration constructs; parts move in
/// whole units (KV heads with their query heads, linear key heads with their
/// value heads, quantization groups of MLP channels); equal weights give the
/// equal plan; refusals when a rank would get no unit of a part.
func checkWeightedShares(c27: [String: Any], c9: [String: Any], quantization: [String: Any]) {
    for shares in [[1, 3], [3, 1], [2, 3], [3, 5], [1, 4], [1, 2]] {
        checkPlan("synthetic 27B shares \(shares)", configuration: c27, tensors: syntheticTensors(c27),
                  quantization: quantization, shares: shares)
        checkPlan("synthetic 9B shares \(shares)", configuration: c9, tensors: syntheticTensors(c9),
                  quantization: quantization, shares: shares)
    }
    guard let equal = try? QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2),
          let ones = try? QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [1, 1]),
          let twos = try? QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [2, 2]),
          let weighted = try? QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [1, 3])
    else { failures += 1; print("FAIL: weighted shares: a plan was refused"); return }
    check(equal == ones, "weighted shares: [1, 1] is the equal plan")
    let keys = syntheticTensors(c27).map(\.name)
    check(keys.allSatisfy { k in (0..<2).allSatisfy { (try? equal.disposition(key: k, rank: $0)) == (try? twos.disposition(key: k, rank: $0)) } },
          "weighted shares: [2, 2] cuts like [1, 1]")
    check(equal.equalShares && !weighted.equalShares, "weighted shares: equalShares")
    // 27B: 4 KV heads -> 1 + 3; 16 linear key heads -> 4 + 12; 17408 channels = 272 groups -> 68 + 204 groups.
    check(weighted.kvHeadsPerRank == [1, 3] && weighted.attentionHeadsPerRank == [6, 18], "27B 1:3 attention heads")
    check(weighted.linearKeyHeadsPerRank == [4, 12] && weighted.linearValueHeadsPerRank == [12, 36], "27B 1:3 linear heads")
    check(weighted.intermediatePerRank == [4352, 13056], "27B 1:3 MLP channels")
    check(weighted.vocabularyRange(rank: 0) == 0..<62_080 && weighted.vocabularyRange(rank: 1) == 62_080..<248_320,
          "27B 1:3 vocabulary rows")
    check(weighted.linearQKVRows(rank: 1) == [512..<2048, 2560..<4096, 5632..<10240], "27B 1:3 rank 1 q/k/v rows")
    let s0 = weighted.shardTextConfiguration(c27, rank: 0)
    check(s0["num_attention_heads"] as? Int == 6 && s0["num_key_value_heads"] as? Int == 1
          && s0["linear_num_key_heads"] as? Int == 4 && s0["linear_num_value_heads"] as? Int == 12
          && s0["intermediate_size"] as? Int == 4352, "27B 1:3 rank 0 configuration")
    // Largest remainder, ties to the lower rank: 3:5 of 4 KV heads = 1.5 / 2.5 -> 2 + 2.
    if let p = try? QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [3, 5]) {
        check(p.kvHeadsPerRank == [2, 2] && p.linearKeyHeadsPerRank == [6, 10] && p.intermediatePerRank == [6528, 10880],
              "27B 3:5 apportioned \(p.kvHeadsPerRank) \(p.linearKeyHeadsPerRank) \(p.intermediatePerRank)")
    }
    expectThrows("a rank without a KV head (1:9 of 4)") {
        _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [1, 9]) }
    expectThrows("a zero share") {
        _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [0, 1]) }
    expectThrows("shares for the wrong rank count") {
        _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [1, 1, 1]) }
    print("weighted shares: 12 plans covered, apportionment and refusals checked")
}

/// Every launch option that changes the collectives must change the first
/// agreement, or two ranks launched differently meet in mismatched all-sums.
func checkLaunchAgreement() {
    let base = QwenTensorParallelLaunch(outputCount: 128, chunkSize: 512, promptTokens: 1024, repeats: 2, warmup: true,
                                        explicitTiming: false, bfloat16Partials: false, hybridPrefillRank: nil)
    check(base.agreement == base.agreement, "launch: the same launch agrees with itself")
    check(base.digest == base.digest, "launch: the same launch has one digest")
    var variants: [(String, QwenTensorParallelLaunch)] = []
    func variant(_ label: String, _ change: (inout QwenTensorParallelLaunch) -> Void) {
        var launch = base
        change(&launch)
        variants.append((label, launch))
    }
    variant("output count") { $0.outputCount = 1024 }
    variant("chunk size") { $0.chunkSize = 256 }
    variant("prompt tokens") { $0.promptTokens = 5120 }
    variant("repeats") { $0.repeats = 3 }
    variant("warmup") { $0.warmup = false }
    variant("explicit timing") { $0.explicitTiming = true }
    variant("bfloat16 partials") { $0.bfloat16Partials = true }
    variant("hybrid, prefill rank 0") { $0.hybridPrefillRank = 0 }
    variant("hybrid, prefill rank 1") { $0.hybridPrefillRank = 1 }
    variant("shares 1:3") { $0.shares = [1, 3] }
    variant("shares 3:1") { $0.shares = [3, 1] }
    for (label, launch) in variants {
        check(launch != base, "launch: \(label) variant equals the base")
        check(launch.agreement != base.agreement, "launch: a rank launched with a different \(label) still agrees")
        check(launch.digest != base.digest, "launch: a rank launched with a different \(label) has the same first-exchange digest")
    }
    check(variants[7].1.agreement != variants[8].1.agreement, "launch: the hybrid prefill ranks agree with each other")
    check(variants[7].1.digest != variants[8].1.digest, "launch: the hybrid prefill ranks share a digest")
    print("launch agreement: \(variants.count) single-option variants checked")
}

/// Names and shapes from safetensors headers (8-byte length + JSON); no payload is read.
func checkpointTensors(_ directory: URL) throws -> [Tensor] {
    let index = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("model.safetensors.index.json"))) as! [String: Any]
    let files = Set((index["weight_map"] as! [String: String]).values)
    var all: [Tensor] = []
    for file in files.sorted() {
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(file))
        defer { try? handle.close() }
        let lengthData = try handle.read(upToCount: 8) ?? Data()
        let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self).littleEndian }
        guard length < 64 << 20 else { throw NSError(domain: "header", code: 1) }
        let header = try JSONSerialization.jsonObject(with: handle.read(upToCount: Int(length)) ?? Data()) as! [String: Any]
        for (name, value) in header where name != "__metadata__" {
            let entry = value as! [String: Any]
            all.append(Tensor(name: name, shape: entry["shape"] as! [Int], dtype: entry["dtype"] as! String))
        }
    }
    return all
}

@main enum TensorParallelPlanCheck {
    static func main() throws {
        let quantization: [String: Any] = ["group_size": 64, "bits": 4, "mode": "affine"]
        let c27 = syntheticConfiguration(hidden: 5120, layers: 64, heads: 24, kv: 4, linearK: 16, linearV: 48, intermediate: 17408)
        checkPlan("synthetic 27B", configuration: c27, tensors: syntheticTensors(c27), quantization: quantization)
        let c9 = syntheticConfiguration(hidden: 4096, layers: 32, heads: 16, kv: 4, linearK: 16, linearV: 32, intermediate: 12288)
        checkPlan("synthetic 9B", configuration: c9, tensors: syntheticTensors(c9), quantization: quantization)

        // Refusals.
        expectThrows("routed experts on a dense model type") { var c = c27; c["num_experts"] = 256
            _ = try QwenTensorParallelPlan(textConfiguration: c, quantization: quantization, size: 2) }
        expectThrows("tied head") { var c = c27; c["tie_word_embeddings"] = true
            _ = try QwenTensorParallelPlan(textConfiguration: c, quantization: quantization, size: 2) }
        expectThrows("three ranks with four KV heads") {
            _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 3) }
        expectThrows("per-module quantization override") {
            var q = quantization; q["language_model.lm_head"] = ["group_size": 32, "bits": 8]
            _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: q, size: 2) }
        expectThrows("MoE model type without experts") { var c = c27; c["model_type"] = "qwen3_5_moe_text"
            _ = try QwenTensorParallelPlan(textConfiguration: c, quantization: quantization, size: 2) }
        expectThrows("another model type") { var c = c27; c["model_type"] = "mimo_v2_flash"
            _ = try QwenTensorParallelPlan(textConfiguration: c, quantization: quantization, size: 2) }
        checkRoutedExperts(quantization: quantization)
        let plan = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2)
        expectThrows("unknown key") { _ = try plan.disposition(key: "language_model.model.layers.0.mlp.experts.weight", rank: 0) }
        expectThrows("attention key on a linear layer") { _ = try plan.disposition(key: "language_model.model.layers.0.self_attn.q_proj.weight", rank: 0) }
        expectThrows("layer out of range") { _ = try plan.disposition(key: "language_model.model.layers.64.mlp.up_proj.weight", rank: 0) }
        expectThrows("rank out of range") { _ = try plan.disposition(key: "language_model.model.norm.weight", rank: 2) }
        check((try? plan.disposition(key: "mtp.fc.weight", rank: 1)) == .skip, "mtp is skipped")
        // The linear attention's packed projection keeps each head block of q, k and v.
        check(plan.linearQKVRows(rank: 1) == [1024..<2048, 3072..<4096, 7168..<10240], "27B rank 1 q/k/v rows")
        check(plan.vocabularyRange(rank: 1) == 124_160..<248_320, "27B rank 1 vocabulary rows")
        let shard = plan.shardTextConfiguration(c27, rank: 1)
        check(shard["num_attention_heads"] as? Int == 12 && shard["num_key_value_heads"] as? Int == 2
              && shard["linear_num_key_heads"] as? Int == 8 && shard["linear_num_value_heads"] as? Int == 24
              && shard["intermediate_size"] as? Int == 8704 && shard["mtp_num_hidden_layers"] as? Int == 0, "27B shard configuration")

        checkWeightedShares(c27: c27, c9: c9, quantization: quantization)
        checkLaunchAgreement()

        for path in CommandLine.arguments.dropFirst() {
            let directory = URL(fileURLWithPath: path)
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as! [String: Any]
            let text = root["text_config"] as! [String: Any]
            let q = (root["quantization"] ?? root["quantization_config"]) as! [String: Any]
            let tensors = try checkpointTensors(directory)
            checkPlan("checkpoint \(directory.lastPathComponent)", configuration: text, tensors: tensors, quantization: q)
            checkPlan("checkpoint \(directory.lastPathComponent) shares [1, 3]", configuration: text, tensors: tensors,
                      quantization: q, shares: [1, 3])
        }
        print(failures == 0 ? "PASS" : "FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}
