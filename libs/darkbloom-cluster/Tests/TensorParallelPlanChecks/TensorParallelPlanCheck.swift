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
    checkPlan("synthetic A3B-shaped equal", configuration: c, tensors: syntheticMoETensors(c), quantization: quantization)
    // A 512-wide expert is one aligned block: unequal shares would leave a rank without one.
    expectThrows("A3B-shaped 1:3 (one 512-wide aligned expert block)") {
        _ = try QwenTensorParallelPlan(textConfiguration: c, quantization: quantization, size: 2, shares: [1, 3]) }
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
    print("routed experts: plan covered (equal), dispositions and refusals checked")
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
    // 27B, kernel-aligned blocks (4-bit: input widths in 512s): 4 KV heads (6 x 256 = 1,536 each) -> 1 + 3;
    // 16 linear key heads in blocks of 4 (4 x 3 x 128 = 1,536) -> 4 + 12; 17,408 channels = 34 blocks of 512 -> 9 + 25.
    check(weighted.kvHeadsPerRank == [1, 3] && weighted.attentionHeadsPerRank == [6, 18], "27B 1:3 attention heads")
    check(weighted.linearKeyHeadsPerRank == [4, 12] && weighted.linearValueHeadsPerRank == [12, 36], "27B 1:3 linear heads")
    check(weighted.intermediatePerRank == [4608, 12800], "27B 1:3 MLP channels (512-aligned) \(weighted.intermediatePerRank)")
    check(weighted.vocabularyRange(rank: 0) == 0..<62_080 && weighted.vocabularyRange(rank: 1) == 62_080..<248_320,
          "27B 1:3 vocabulary rows")
    check(weighted.linearQKVRows(rank: 1) == [512..<2048, 2560..<4096, 5632..<10240], "27B 1:3 rank 1 q/k/v rows")
    let s0 = weighted.shardTextConfiguration(c27, rank: 0)
    check(s0["num_attention_heads"] as? Int == 6 && s0["num_key_value_heads"] as? Int == 1
          && s0["linear_num_key_heads"] as? Int == 4 && s0["linear_num_value_heads"] as? Int == 12
          && s0["intermediate_size"] as? Int == 4608, "27B 1:3 rank 0 configuration")
    // Largest remainder, ties to the lower rank: 3:5 of 4 KV heads = 1.5 / 2.5 -> 2 + 2; 4 key-head blocks -> 2 + 2;
    // 34 MLP blocks = 12.75 / 21.25 -> 13 + 21.
    if let p = try? QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [3, 5]) {
        check(p.kvHeadsPerRank == [2, 2] && p.linearKeyHeadsPerRank == [8, 8] && p.intermediatePerRank == [6656, 10752],
              "27B 3:5 apportioned \(p.kvHeadsPerRank) \(p.linearKeyHeadsPerRank) \(p.intermediatePerRank)")
    } else { failures += 1; print("FAIL: 27B 3:5 refused") }
    // Every weighted plan keeps every row-parallel input width on the fast kernel's alignment.
    for shares in [[1, 3], [3, 1], [2, 3], [3, 5], [1, 4], [1, 2]] {
        for (label, c) in [("27B", c27), ("9B", c9)] {
            guard let p = try? QwenTensorParallelPlan(textConfiguration: c, quantization: quantization, size: 2, shares: shares) else {
                failures += 1; print("FAIL: \(label) \(shares) refused"); continue
            }
            let aligned = (0..<2).allSatisfy { r in
                [p.attentionHeadsPerRank[r] * p.headDim, p.linearValueHeadsPerRank[r] * p.linearValueHeadDim,
                 p.intermediatePerRank[r]].allSatisfy { $0 % 512 == 0 } && p.vocabularyRange(rank: r).count % 8 == 0
            }
            check(aligned, "\(label) \(shares): every row-parallel input width a multiple of 512 and vocabulary rows of 8")
        }
    }
    expectThrows("a rank without a KV head (1:9 of 4)") {
        _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [1, 9]) }
    expectThrows("a zero share") {
        _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [0, 1]) }
    expectThrows("shares for the wrong rank count") {
        _ = try QwenTensorParallelPlan(textConfiguration: c27, quantization: quantization, size: 2, shares: [1, 1, 1]) }
    print("weighted shares: 12 plans covered, apportionment and refusals checked")
}

/// The sealed all-sum's codec: a frame opens only on the peer, at its own
/// counter, under its own scope; one flipped byte is refused, and a refused
/// codec seals and opens nothing more.
func checkSealCodec() {
    let scope = Data("scope-a".utf8)
    let (r0, r1) = QwenTensorParallelSealCodec.pair(scope: scope)
    var partial = (0..<5120).map { Float($0) * 0.25 - 7 }
    let bytes = partial.count * 4
    var frame = [UInt8](repeating: 0, count: bytes + QwenTensorParallelSealCodec.frameOverhead)
    var opened = [Float](repeating: 0, count: partial.count)
    let sealed = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in r0.seal(p.baseAddress!, bytes, f.baseAddress!, 41) } }
    check(sealed == 0, "codec: rank 0 seals")
    check(frame.withUnsafeBytes { f in partial.withUnsafeBytes { p in !f.starts(with: p) } }, "codec: the frame is not the plaintext")
    func open(_ codec: QwenTensorParallelSealCodec, _ counter: UInt64, _ peer: Int, _ f: [UInt8]) -> Int32 {
        f.withUnsafeBytes { fb in opened.withUnsafeMutableBytes { o in codec.open(fb.baseAddress!, bytes, o.baseAddress!, counter, peer) } }
    }
    check(open(r1, 41, 0, frame) == 0 && opened == partial, "codec: rank 1 opens rank 0's frame at its counter, byte for byte")
    let (s0, s1) = QwenTensorParallelSealCodec.pair(scope: scope)
    _ = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in s0.seal(p.baseAddress!, bytes, f.baseAddress!, 7) } }
    check(open(s1, 8, 0, frame) != 0, "codec: another counter is refused")
    check(s1.refused && open(s1, 7, 0, frame) != 0, "codec: a refused codec opens nothing more, even a good frame")
    let (t0, t1) = QwenTensorParallelSealCodec.pair(scope: scope)
    _ = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in t0.seal(p.baseAddress!, bytes, f.baseAddress!, 9) } }
    var flipped = frame; flipped[bytes / 2] ^= 1
    check(open(t1, 9, 0, flipped) != 0, "codec: one flipped ciphertext byte is refused")
    let (u0, u1) = QwenTensorParallelSealCodec.pair(scope: scope)
    _ = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in u0.seal(p.baseAddress!, bytes, f.baseAddress!, 3) } }
    check(open(u1, 3, 1, frame) != 0, "codec: a frame claimed from the wrong peer is refused")
    let (v0, _) = QwenTensorParallelSealCodec.pair(scope: scope)
    let (_, w1) = QwenTensorParallelSealCodec.pair(scope: Data("scope-b".utf8))
    _ = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in v0.seal(p.baseAddress!, bytes, f.baseAddress!, 5) } }
    check(open(w1, 5, 0, frame) != 0, "codec: another run's keys and scope are refused")
    // A prefill-sized partial (512 x 5,120 float32 = 10.5 MB) is sealed in 40 pieces, in parallel.
    let big = (0..<(512 * 5120)).map { Float($0 % 977) * 0.5 - 100 }
    let bigBytes = big.count * 4
    check(QwenTensorParallelSealCodec.chunks(bigBytes) == 40 && QwenTensorParallelSealCodec.chunks(bytes) == 1, "codec: piece counts")
    var bigFrame = [UInt8](repeating: 0, count: bigBytes + QwenTensorParallelSealCodec.frameOverhead)
    var bigOpened = [Float](repeating: 0, count: big.count)
    let (p0, p1) = QwenTensorParallelSealCodec.pair(scope: scope)
    let bigSealed = big.withUnsafeBytes { p in bigFrame.withUnsafeMutableBytes { f in p0.seal(p.baseAddress!, bigBytes, f.baseAddress!, 11) } }
    let o1 = bigFrame.withUnsafeBytes { f in bigOpened.withUnsafeMutableBytes { o in p1.open(f.baseAddress!, bigBytes, o.baseAddress!, 11, 0) } }
    check(bigSealed == 0 && o1 == 0 && bigOpened == big, "codec: a 10.5 MB partial round-trips through 40 parallel pieces")
    let (q0, q1) = QwenTensorParallelSealCodec.pair(scope: scope)
    _ = big.withUnsafeBytes { p in bigFrame.withUnsafeMutableBytes { f in q0.seal(p.baseAddress!, bigBytes, f.baseAddress!, 12) } }
    var swapped = bigFrame
    let tags = bigBytes
    for i in 0..<16 { swapped.swapAt(tags + i, tags + 16 + i) }
    let refusedSwap = swapped.withUnsafeBytes { f in bigOpened.withUnsafeMutableBytes { o in q1.open(f.baseAddress!, bigBytes, o.baseAddress!, 12, 0) } }
    check(refusedSwap != 0, "codec: two pieces' tags swapped are refused (each piece's nonce and data name its index)")
    let (z0, z1) = QwenTensorParallelSealCodec.pair(scope: scope)
    _ = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in z0.seal(p.baseAddress!, bytes, f.baseAddress!, 13) } }
    var padded = frame; padded[bytes + QwenTensorParallelSealCodec.frameOverhead - 1] = 1
    check(open(z1, 13, 0, padded) != 0, "codec: a non-zero padding byte is refused")
    // Rekey: a new key generation every 3 frames per direction; both ranks
    // cross it at the same counter, and a frame sealed in one generation
    // does not open in another.
    let (g0, g1) = QwenTensorParallelSealCodec.pair(scope: scope, rekeyFrames: 3)
    var crossed = true
    for counter in UInt64(20)..<UInt64(30) {
        let s = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in g0.seal(p.baseAddress!, bytes, f.baseAddress!, counter) } }
        crossed = crossed && s == 0 && open(g1, counter, 0, frame) == 0 && opened == partial
    }
    check(crossed && g0.keyGeneration == 3 && g1.keyGeneration == 3, "codec: rekey every 3 frames, both ranks at generation 3 after 10 frames")
    let (h0, h1) = QwenTensorParallelSealCodec.pair(scope: scope, rekeyFrames: 1)
    let (_, k1) = QwenTensorParallelSealCodec.pair(scope: scope)
    _ = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in h0.seal(p.baseAddress!, bytes, f.baseAddress!, 1) } }
    check(open(h1, 1, 0, frame) == 0, "codec: generation 0 opens")
    _ = partial.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in h0.seal(p.baseAddress!, bytes, f.baseAddress!, 2) } }
    check(h0.keyGeneration == 1 && open(k1, 2, 0, frame) != 0, "codec: a generation-1 frame does not open under the base keys")
    check(open(h1, 2, 0, frame) == 0 && h1.keyGeneration == 1, "codec: the peer opens it in generation 1")
    check(open(h1, 1, 0, frame) != 0, "codec: counters only grow (an older counter is refused)")
    partial[0] = 1
    print("seal codec: round trip, counter, tamper, direction, scope, pieces, padding, rekey and refusal checked")
}

/// Every launch option that changes the collectives must change the first
/// agreement, or two ranks launched differently meet in mismatched all-sums.
/// The streamed codec: each piece opens alone, in any order and on any
/// thread, only on the peer, at its counter and index. A flipped byte, a
/// swapped tag or a whole-frame piece is refused.
func checkSealPieces() {
    typealias Codec = QwenTensorParallelSealCodec
    let scope = Data("scope-a".utf8)
    let size = Codec.streamedPieceBytes, tag = Codec.tagBytes, stride = size + tag
    check(stride == 256 << 10, "pieces: four sealed pieces fill one 1 MiB frame")
    check(Codec.isStreamedPiece(64, of: 65, total: 16 << 20, length: 1024)
          && !Codec.isStreamedPiece(64, of: 65, total: 16 << 20, length: size)
          && !Codec.isStreamedPiece(0, of: 64, total: 16 << 20, length: size)
          && Codec.isStreamedPiece(128, of: 129, total: 32 << 20, length: 2048)
          && Codec.isStreamedPiece(0, of: 1, total: 8192, length: 8192)
          && !Codec.isStreamedPiece(0, of: 70_000, total: 70_000 * size, length: size), "pieces: counts and lengths")
    let total = 3 * size + 1000, count = 4
    let plain = (0..<total).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }
    func length(_ k: Int) -> Int { min(size, total - k * size) }
    func seal(_ codec: Codec, _ counter: UInt64) -> [UInt8]? {
        var frame = [UInt8](repeating: 0, count: total + count * tag)
        var refused = 0
        plain.withUnsafeBytes { p in frame.withUnsafeMutableBytes { f in
            let source = p.baseAddress!, target = f.baseAddress!
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: count) { k in
                if codec.sealPiece(source + k * size, length(k), target + k * stride, counter, k, count, total) != 0 {
                    lock.lock(); refused += 1; lock.unlock()
                }
            }
        } }
        return refused == 0 ? frame : nil
    }
    func open(_ codec: Codec, _ frame: [UInt8], _ counter: UInt64, _ k: Int, at offset: Int? = nil,
              into out: inout [UInt8], peer: Int = 0) -> Int32 {
        frame.withUnsafeBytes { f in out.withUnsafeMutableBytes { o in
            codec.openPiece(f.baseAddress! + (offset ?? k * stride), length(k), o.baseAddress! + k * size,
                            counter, k, count, total, peer)
        } }
    }
    let (r0, r1) = Codec.pair(scope: scope)
    var out = [UInt8](repeating: 0, count: total)
    guard let frame = seal(r0, 41) else { failures += 1; print("FAIL: pieces: rank 0 seals"); return }
    check(!frame.starts(with: plain.prefix(64)), "pieces: a sealed piece is not the plaintext")
    let reversed = (0..<count).reversed().allSatisfy { open(r1, frame, 41, $0, into: &out) == 0 }
    check(reversed && out == plain, "pieces: rank 1 opens rank 0's pieces in reverse order, byte for byte")
    let (t0, t1) = Codec.pair(scope: scope)
    if let good = seal(t0, 9) {
        var flipped = good; flipped[2 * stride + 100] ^= 1
        check(open(t1, flipped, 9, 2, into: &out) != 0, "pieces: one flipped byte is refused")
        check(t1.refused && open(t1, good, 9, 0, into: &out) != 0, "pieces: a refused codec opens nothing more")
        check(seal(t1, 10) == nil, "pieces: a refused codec seals nothing more")
    }
    let (u0, u1) = Codec.pair(scope: scope)
    if var swapped = seal(u0, 3) {
        for i in 0..<tag { swapped.swapAt(size + i, stride + size + i) }
        check(open(u1, swapped, 3, 0, into: &out) != 0, "pieces: two pieces' tags swapped are refused")
    }
    let (v0, v1) = Codec.pair(scope: scope)
    if let moved = seal(v0, 4) {
        check(open(v1, moved, 4, 0, at: stride, into: &out) != 0, "pieces: piece 1 opened as piece 0 is refused")
    }
    let (w0, w1) = Codec.pair(scope: scope)
    if let other = seal(w0, 5) {
        check(open(w1, other, 6, 0, into: &out) != 0, "pieces: another counter is refused")
    }
    let (x0, x1) = Codec.pair(scope: scope)
    if let own = seal(x0, 6) {
        check(open(x1, own, 6, 0, into: &out, peer: 1) != 0, "pieces: a piece claimed from the wrong peer is refused")
    }
    // A whole frame (one v1 piece) and a streamed piece of the same bytes,
    // counter and nonce do not open as each other.
    let small = 1000
    var whole = [UInt8](repeating: 0, count: small + Codec.frameOverhead)
    var single = [UInt8](repeating: 0, count: small + Codec.frameOverhead)
    var opened = [UInt8](repeating: 0, count: small)
    let (y0, y1) = Codec.pair(scope: scope)
    _ = plain.withUnsafeBytes { p in whole.withUnsafeMutableBytes { f in y0.seal(p.baseAddress!, small, f.baseAddress!, 7) } }
    let asPiece = whole.withUnsafeBytes { f in opened.withUnsafeMutableBytes { o in
        y1.openPiece(f.baseAddress!, small, o.baseAddress!, 7, 0, 1, small, 0) } }
    check(asPiece != 0, "pieces: a whole frame does not open as a streamed piece")
    let (z0, z1) = Codec.pair(scope: scope)
    _ = plain.withUnsafeBytes { p in single.withUnsafeMutableBytes { f in z0.sealPiece(p.baseAddress!, small, f.baseAddress!, 8, 0, 1, small) } }
    let asWhole = single.withUnsafeBytes { f in opened.withUnsafeMutableBytes { o in z1.open(f.baseAddress!, small, o.baseAddress!, 8, 0) } }
    check(asWhole != 0, "pieces: a streamed piece does not open as a whole frame")
    // Rekey: pieces of one counter share its generation; both ranks cross
    // each generation at the same counter.
    let (g0, g1) = Codec.pair(scope: scope, rekeyFrames: 3)
    var crossed = true
    for counter in UInt64(20)..<UInt64(30) {
        guard let f = seal(g0, counter) else { crossed = false; break }
        crossed = crossed && (0..<count).allSatisfy { open(g1, f, counter, $0, into: &out) == 0 } && out == plain
    }
    check(crossed && g0.keyGeneration == 3 && g1.keyGeneration == 3, "pieces: rekey every 3 sums, both at generation 3")
    check(open(g1, frame, 19, 0, into: &out) != 0, "pieces: counters only grow")
    print("seal pieces: layout, any-order open, tamper, swap, index, counter, direction, frame kind and rekey checked")
}

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
    variant("sealed reduction") { $0.sealedReduction = true }
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

        // The ready shard keeps a freed-buffer cache (a decode step's ~1,500 intermediate buffers are not
        // created by the driver one by one), bounded inside the memory gate's allocator headroom.
        let gib = 1 << 30
        for headroom in [2 * gib, 4 * gib, 512 << 20] {
            let bytes = QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: headroom)
            check(bytes > 0 && bytes <= headroom / 2, "freed-buffer cache \(bytes) for headroom \(headroom) is half of it at most")
        }
        check(QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: 2 * gib) >= 256 << 20,
              "the product's 2 GiB headroom leaves a cache that holds a decode step's buffers")
        check(QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: 0) == 0, "no headroom, no cache")

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
        checkSealCodec()
        checkSealPieces()

        for path in CommandLine.arguments.dropFirst() {
            let directory = URL(fileURLWithPath: path)
            let root = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as! [String: Any]
            let text = root["text_config"] as! [String: Any]
            let q = (root["quantization"] ?? root["quantization_config"]) as! [String: Any]
            let tensors = try checkpointTensors(directory)
            checkPlan("checkpoint \(directory.lastPathComponent)", configuration: text, tensors: tensors, quantization: q)
            if (text["num_experts"] as? Int ?? 0) == 0 {
                checkPlan("checkpoint \(directory.lastPathComponent) shares [1, 3]", configuration: text, tensors: tensors,
                          quantization: q, shares: [1, 3])
            }
        }
        checkStopRule()
        print(failures == 0 ? "PASS" : "FAILED: \(failures)")
        exit(failures == 0 ? 0 : 1)
    }
}

// A committed token's outcome on a tensor-parallel rank. The product's engine
// answers "not wanted" for the token that ends the request (a stop token, or
// the output limit): that answer must not turn an EOS or length finish into a
// client stop (the owner and rank 0's session expect EOS/length there, as the
// pipeline's decision packet decides), and both ranks must report one finish.
func checkStopRule() {
    typealias R = QwenTensorParallelStopRule
    // EOS wins over "not wanted" at the same token (the onboarding's first request).
    check(R.outcome(isStopToken: true, committed: 6, outputCount: 16, wanted: false) == .eos, "EOS answered not-wanted stays EOS")
    check(R.outcome(isStopToken: true, committed: 6, outputCount: 16, wanted: true) == .eos, "EOS")
    // The output limit wins over "not wanted" at the last token.
    check(R.outcome(isStopToken: false, committed: 16, outputCount: 16, wanted: false) == .length, "last token answered not-wanted stays length")
    check(R.outcome(isStopToken: false, committed: 16, outputCount: 16, wanted: true) == .length, "length")
    // A stop token that is also the last token is EOS (the owner checks EOS first).
    check(R.outcome(isStopToken: true, committed: 16, outputCount: 16, wanted: false) == .eos, "EOS at the limit")
    // Mid-stream: the answer decides.
    check(R.outcome(isStopToken: false, committed: 5, outputCount: 16, wanted: false) == .clientStop, "mid-stream not-wanted is a client stop")
    check(R.outcome(isStopToken: false, committed: 5, outputCount: 16, wanted: true) == .proceed, "mid-stream wanted proceeds")

    // Both ranks end on rank 0's outcome. A client stop rank 0 made when no
    // later step could carry its flag (the step after it was the last one
    // already built) leaves rank 1 at length with one token more: rank 1
    // adopts rank 0's count and finish.
    let adopted = R.reconcile(rank: 1, localFinish: .length, localCount: 16, localStopped: false,
                              rank0Finish: .clientStop, rank0Count: 15)
    check(adopted.finish == .clientStop && adopted.count == 15, "rank 1 adopts rank 0's client stop: \(adopted)")
    let same = R.reconcile(rank: 1, localFinish: .eos, localCount: 6, localStopped: false, rank0Finish: .eos, rank0Count: 6)
    check(same.finish == .eos && same.count == 6, "agreeing ranks keep their finish")
    // A rank that stopped on its own (cancel, deadline, memory) keeps its stop: the request fails on both.
    let own = R.reconcile(rank: 1, localFinish: .clientStop, localCount: 9, localStopped: true, rank0Finish: .length, rank0Count: 16)
    check(own.finish == .clientStop && own.count == 9, "a rank's own stop is kept")
    // Rank 0 never changes its outcome.
    let zero = R.reconcile(rank: 0, localFinish: .clientStop, localCount: 15, localStopped: false, rank0Finish: .clientStop, rank0Count: 15)
    check(zero.finish == .clientStop && zero.count == 15, "rank 0 keeps its outcome")
    // The agreement crosses as two integers and decodes back exactly.
    for finish in [R.Finish.eos, .length, .clientStop] {
        check(R.Finish(code: finish.code) == finish, "finish code round trip \(finish)")
    }
    check(R.Finish(code: 0) == nil && R.Finish(code: 9) == nil, "unknown finish codes are refused")
}
