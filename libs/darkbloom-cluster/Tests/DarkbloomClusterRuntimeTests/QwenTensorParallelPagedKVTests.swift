import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Paged attention KV for Qwen tensor parallel (`QwenTensorParallelPagedKV.swift`),
/// model-free: the default, the load agreement and a request's reservation.
/// The cache's bitwise equality with `KVCacheSimple` on a Qwen 3.5 model is
/// the SDK's `PagedAttentionKVTests` (GPU, `QWEN_PAGED_KV=1`).
struct QwenTensorParallelPagedKVTests {
    typealias Runtime = QwenTensorParallelResidentRuntime

    @Test func pagedKVIsTheDefaultAndBoundIntoTheAgreement() throws {
        #expect(try Runtime.pagedKV([:]))
        #expect(try Runtime.pagedKV(["DARKBLOOM_CLUSTER_QWEN_TP_PAGED_KV": "1"]))
        #expect(try !Runtime.pagedKV(["DARKBLOOM_CLUSTER_QWEN_TP_PAGED_KV": "0"]))
        #expect(throws: ProbeError.self) { try Runtime.pagedKV(["DARKBLOOM_CLUSTER_QWEN_TP_PAGED_KV": "on"]) }
        #expect(Runtime.pagedKVAgreementFields(true) == ["qwen-tp-paged-kv-v1", "page=64"])
        #expect(Runtime.pagedKVAgreementFields(false) == ["qwen-tp-paged-kv-v1", "contiguous"])
    }

    /// A request reserves every attention layer's history at its own length,
    /// one page each beside it for a copy on write, and the pool's page holds
    /// exactly one rank's keys and values (27B under TP2: 2 key/value heads
    /// of 256 per rank, bf16, 16 attention layers).
    @Test func aRequestReservesItsAttentionPages() throws {
        let pool = try PagedAttentionKVPool(pageSize: Runtime.attentionPageTokens, kvHeads: 2, keyHeadDim: 256,
            valueHeadDim: 256, dtype: .bfloat16)
        #expect(pool.pageBytes == 64 * 2 * (2 * 256) * 2)
        #expect(pool.pages(tokens: 0) == 0 && pool.pages(tokens: 1) == 2 && pool.pages(tokens: 64) == 2
            && pool.pages(tokens: 65) == 3)
        #expect(Runtime.historyPages(pool: pool, attentionLayers: 16, tokens: 32_768) == 16 * 513)
        // 32K tokens: 16 x 513 pages of 128 KiB, about 1 GiB per rank.
        #expect(16 * 513 * pool.pageBytes == 1_075_838_976)
        #expect(Runtime.pagedGrowthBytes(model: nil, tokens: 32_768) == 0)
    }

    /// A synthetic 4-bit Qwen 3.5 dense checkpoint (random weights; the
    /// tensor names and cuts of the real rows, `TensorParallelPlanCheck`).
    static func checkpoint(hidden h: Int, layers: Int, heads hq: Int, kvHeads hkv: Int, vocabulary: Int)
        -> (configuration: Data, tensors: [(String, MLXArray)]) {
        let hd = 256, lk = 2 * 128, lv = 4 * 128, nv = 4, inter = 2 * h
        let text: [String: Any] = ["model_type": "qwen3_5_text", "hidden_size": h, "num_hidden_layers": layers,
            "full_attention_interval": 4, "num_attention_heads": hq, "num_key_value_heads": hkv, "head_dim": hd,
            "linear_num_key_heads": 2, "linear_num_value_heads": nv, "linear_key_head_dim": 128,
            "linear_value_head_dim": 128, "intermediate_size": inter, "vocab_size": vocabulary,
            "tie_word_embeddings": false, "attn_output_gate": true, "linear_conv_kernel_dim": 4]
        let root: [String: Any] = ["model_type": "qwen3_5", "text_config": text,
                                   "quantization": ["group_size": 64, "bits": 4]]
        var key = MLXRandom.key(2026)
        func next() -> MLXArray { let (a, b) = MLXRandom.split(key: key); key = a; return b }
        func q(_ name: String, _ out: Int, _ input: Int) -> [(String, MLXArray)] {
            let scales = MLXRandom.uniform(low: Float(0.002), high: Float(0.02), [out, input / 64], key: next()).asType(.bfloat16)
            return [(name + ".weight", MLXRandom.randInt(low: 0, high: Int32.max, [out, input / 8], key: next())
                        .asType(.uint32)),
                    (name + ".scales", scales), (name + ".biases", (scales * -7.5).asType(.bfloat16))]
        }
        func norm(_ name: String, _ n: Int, _ dtype: DType = .bfloat16) -> (String, MLXArray) {
            (name, MLXRandom.uniform(low: Float(0.9), high: Float(1.1), [n], key: next()).asType(dtype))
        }
        var all = q("language_model.model.embed_tokens", vocabulary, h) + q("language_model.lm_head", vocabulary, h)
        all.append(norm("language_model.model.norm.weight", h))
        for layer in 0..<layers {
            let p = "language_model.model.layers.\(layer)."
            all += [norm(p + "input_layernorm.weight", h), norm(p + "post_attention_layernorm.weight", h)]
            all += q(p + "mlp.gate_proj", inter, h) + q(p + "mlp.up_proj", inter, h) + q(p + "mlp.down_proj", h, inter)
            if (layer + 1) % 4 != 0 {
                all += q(p + "linear_attn.in_proj_qkv", 2 * lk + lv, h) + q(p + "linear_attn.in_proj_z", lv, h)
                    + q(p + "linear_attn.in_proj_b", nv, h) + q(p + "linear_attn.in_proj_a", nv, h)
                    + q(p + "linear_attn.out_proj", h, lv)
                all += [(p + "linear_attn.conv1d.weight",
                         (MLXRandom.normal([2 * lk + lv, 4, 1], key: next()) * 0.2).asType(.bfloat16)),
                        (p + "linear_attn.A_log", MLXRandom.uniform(low: Float(-1), high: Float(0), [nv], key: next())),
                        (p + "linear_attn.dt_bias", MLXRandom.uniform(low: Float(-0.5), high: Float(0.5), [nv], key: next())
                            .asType(.bfloat16)),
                        norm(p + "linear_attn.norm.weight", 128, .float32)]
            } else {
                all += q(p + "self_attn.q_proj", 2 * hq * hd, h) + q(p + "self_attn.k_proj", hkv * hd, h)
                    + q(p + "self_attn.v_proj", hkv * hd, h) + q(p + "self_attn.o_proj", h, hq * hd)
                all += [norm(p + "self_attn.q_norm.weight", hd), norm(p + "self_attn.k_norm.weight", hd)]
            }
        }
        return (try! JSONSerialization.data(withJSONObject: root), all)
    }

    /// Opt-in (`QWEN_PAGED_KV=1`, GPU): one rank's shard of a synthetic Qwen
    /// 3.5 model (divided key/value heads; no peer: the local reduction) with
    /// its pool (`makeAttentionPagePool`, the runtime's `newCache(account:)`)
    /// gives exactly the logits of the same shard with `KVCacheSimple`, bit
    /// for bit: prefill chunks across pages, decode steps, and a prefix entry
    /// shared by page that the request and a restore both continue from
    /// (`QwenTensorParallelPrefixCache`); every page comes back.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["QWEN_PAGED_KV"] == "1"))
    func aPagedShardComputesWhatAContiguousShardDoes() throws {
        try Device.withDefaultDevice(.gpu) {
            for rank in 0..<2 {
                let source = Self.checkpoint(hidden: 512, layers: 8, heads: 4, kvHeads: 2, vocabulary: 4096)
                let model = try QwenTensorParallelModel.assemble(configurationData: source.configuration,
                    role: .shard(rank: rank, size: 2), reduction: QwenTensorParallelLocalReduction(rank: rank, size: 2)
                ) { _, keep in for (name, value) in source.tensors { try keep(name, value) } }
                let pool = try model.makeAttentionPagePool(pageSize: Runtime.attentionPageTokens)
                #expect(pool.kvHeads == 1 && pool.keyHeadDim == 256 && pool.dtype == .bfloat16 && model.attentionLayerCount == 2)
                model.attentionPagePool = pool
                let prompt = (0..<1_300).map { ($0 * 7919 + 13) % 4096 }
                let pages = try #require(try Runtime.reservePages(model: model, tokens: prompt.count + 40))
                let paged = model.newCache(account: pages.account), contiguous = model.newCache()
                #expect(paged.filter { $0 is PagedAttentionKVCache }.count == 2)
                #expect(contiguous.filter { $0 is KVCacheSimple }.count == 2)
                func bytes(_ a: MLXArray) -> Data { a.asData(access: .copy).data }
                func same(_ a: [KVCache], _ b: [KVCache], _ tokens: [Int], _ label: String) {
                    let input = MLXArray(tokens.map { Int32($0) }).reshaped(1, tokens.count)
                    let x = model.forwardForRuntime(input, cache: a), y = model.forwardForRuntime(input, cache: b)
                    eval([x, y] + a.flatMap { $0.innerState() } + b.flatMap { $0.innerState() })
                    #expect(x.shape == y.shape && bytes(x) == bytes(y), "rank \(rank) \(label) logits")
                    for (index, (p, c)) in zip(a, b).enumerated() {
                        let left = p.state, right = c.state
                        eval(left + right)
                        #expect(left.count == right.count && zip(left, right).allSatisfy { bytes($0) == bytes($1) },
                            "rank \(rank) \(label) layer \(index) state")
                    }
                }
                let prefix = QwenTensorParallelPrefixCache(budgetBytes: 1 << 30)
                for start in stride(from: 0, to: prompt.count, by: 256) {
                    let end = min(prompt.count, start + 256)
                    same(paged, contiguous, Array(prompt[start..<end]), "prefill \(start)")
                    if end == 1_024 {
                        prefix.store(scope: "s", prompt: prompt, length: end, cache: paged)
                        prefix.store(scope: "c", prompt: prompt, length: end, cache: contiguous)
                    }
                }
                for step in 0..<8 { same(paged, contiguous, [(step * 31 + 5) % 4096], "step \(step)") }
                // A restore from the shared pages continues as a contiguous restore does.
                let restoredPaged = try #require(prefix.restore(scope: "s", prompt: prompt, length: 1_024))
                let restoredContiguous = try #require(prefix.restore(scope: "c", prompt: prompt, length: 1_024))
                for case let history as PagedAttentionKVCache in restoredPaged { history.account = pages.account }
                same(restoredPaged, restoredContiguous, Array(prompt[1_024...]), "restored prefill")
                for step in 0..<4 { same(restoredPaged, restoredContiguous, [(step * 17 + 3) % 4096], "restored step \(step)") }
                #expect(prefix.bytesInUse >= 2 * 17 * pool.pageBytes)
                #expect(pool.allocatedPages > 0)
            }
        }
    }
}
