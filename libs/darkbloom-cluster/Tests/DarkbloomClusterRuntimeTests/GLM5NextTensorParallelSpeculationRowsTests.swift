import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Testing
@testable import DarkbloomClusterRuntime

/// Opt-in (`GLM53_ROW_INVARIANCE=1`, GPU, about 1 GB of synthetic weights):
/// several requests' speculative rounds in ONE stage forward
/// (`GLM5NextTensorParallelSpeculation.rounds`) decide exactly the tokens,
/// and leave exactly the caches and NextN histories, of each request's own
/// `round`. A synthetic serving-policy whole-model stage at the artifact's
/// widths (five layers, NVFP4 dense MLPs and experts, affine Q4/g64 elsewhere)
/// on one device: the agreement is the identity.
@Suite(.serialized)
struct GLM5NextTensorParallelSpeculationRowsTests {
    static let enabled = ProcessInfo.processInfo.environment["GLM53_ROW_INVARIANCE"] == "1"

    static func configuration() throws -> GLM5NextConfiguration {
        let layers = 5
        let kinds = (0..<layers).map { $0 % 4 == 3 ? "deepseek_sparse_attention" : "linear_attention" }
        let text: [String: Any] = [
            "model_type": "glm5_next_text", "vocab_size": 8192, "hidden_size": 4096,
            "intermediate_size": 12288, "moe_intermediate_size": 2048, "num_hidden_layers": layers,
            "num_attention_heads": 64, "num_key_value_heads": 64, "head_dim": 0,
            "qk_head_dim": 256, "qk_nope_head_dim": 256, "qk_rope_head_dim": 0,
            "v_head_dim": 256, "q_lora_rank": 1536, "kv_lora_rank": 512, "mla_use_nope": true,
            "layer_types": kinds,
            "mlp_layer_types": (0..<layers).map { $0 < 3 ? "dense" : "sparse" },
            "indexer_types": Array(repeating: "full", count: layers),
            "linear_attn_config": [
                "num_heads": 64, "head_dim": 128, "gate_lower_bound": -5, "short_conv_kernel_size": 4,
                "kda_layers": kinds.indices.filter { kinds[$0] == "linear_attention" },
                "full_attn_layers": kinds.indices.filter { kinds[$0] == "deepseek_sparse_attention" },
            ],
            "index_head_dim": 128, "index_n_heads": 32, "index_topk": 2048, "index_kpool": 4,
            "index_kpool_compress": true, "index_kpool_always_select_tail": true,
            "indexer_rope_interleave": true, "index_share_for_mtp_iteration": true,
            "mhc": true, "hc_mult": 4, "hc_eps": 1e-6, "hc_sinkhorn_iters": 20,
            "first_k_dense_replace": 3, "n_routed_experts": 16, "n_shared_experts": 1,
            "num_experts_per_tok": 8, "n_group": 1, "topk_group": 1, "norm_topk_prob": true,
            "routed_scaling_factor": 2.5, "scoring_func": "sigmoid", "topk_method": "noaux_tc",
            "moe_router_dtype": "float32", "output_router_logits": false, "router_aux_loss_coef": 0.001,
            "num_nextn_predict_layers": 1, "hidden_act": "silu", "swiglu_limit": 10, "rms_norm_eps": 1e-5,
            "attention_bias": false, "attention_dropout": 0, "max_position_embeddings": 1_048_576,
            "initializer_range": 0.02, "use_cache": true, "tie_word_embeddings": false,
            "dtype": "bfloat16", "pad_token_id": 0, "eos_token_id": [1, 2, 3],
        ]
        var root: [String: Any] = [
            "model_type": "glm5_next", "architectures": ["Glm5NextForConditionalGeneration"],
            "tie_word_embeddings": false, "text_config": text,
            "image_token_id": 10, "video_token_id": 11, "image_start_token_id": 12,
            "image_end_token_id": 13, "video_start_token_id": 14, "video_end_token_id": 15,
            "vision_config": [
                "model_type": "glm5_next_vision", "depth": 1, "hidden_size": 8,
                "intermediate_size": 12, "num_heads": 2, "image_size": 8, "patch_size": 2,
                "temporal_patch_size": 2, "spatial_merge_size": 2, "in_channels": 3,
                "out_hidden_size": 4096, "projection_intermediate_size": 8, "hidden_act": "silu",
                "swiglu_limit": 10, "rms_norm_eps": 1e-5, "attention_bias": true,
                "attention_dropout": 0, "initializer_range": 0.02,
            ],
        ]
        let declared = try JSONDecoder().decode(GLM5NextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root))
        var policy: [String: Any] = ["bits": 4, "group_size": 64, "mode": "affine"]
        for module in GLM5NextWeightInventory.nvfp4Modules(declared.textConfig) {
            policy[module] = ["bits": 4, "group_size": 16, "mode": "nvfp4"]
        }
        root["quantization"] = policy
        root["quantization_config"] = policy
        return try JSONDecoder().decode(GLM5NextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: root))
    }

    /// Deterministic synthetic payload in a sane range (as the SDK's
    /// `GLM5NextBatchInvarianceTests` fixture).
    static func tensor(_ entry: GLM5NextWeightInventory.Entry) -> MLXArray {
        let name = entry.tensor.name, shape = entry.tensor.shape
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        let key = MLXRandom.key(hash)
        func uniform(_ range: Range<Float>) -> MLXArray {
            let value = MLXRandom.uniform(range, shape, key: key)
            return entry.tensor.dtype == "F32" ? value : value.asType(.bfloat16)
        }
        switch entry.tensor.dtype {
        case "U32": return MLXRandom.randInt(UInt32(0) ..< UInt32.max, shape, key: key)
        case "U8": return MLXRandom.randInt(UInt8(32) ..< UInt8(56), shape, key: key)
        default: break
        }
        if name.hasSuffix(".weight_scale_2") { return MLXArray(Float(0.02)) }
        if entry.packing != nil && name.hasSuffix(".scales") { return uniform(0.003 ..< 0.006) }
        if entry.packing != nil && name.hasSuffix(".biases") { return uniform(-0.04 ..< -0.028) }
        if name.hasSuffix("norm.weight") || name.hasSuffix("_scale") { return uniform(0.8 ..< 1.2) }
        if name.hasSuffix("A_log") { return uniform(-1 ..< 0) }
        if name.hasSuffix("dt_bias") { return uniform(-0.5 ..< 0) }
        if name.hasSuffix("_base") || name.hasSuffix("correction_bias") || name.hasSuffix(".bias") {
            return uniform(-0.01 ..< 0.01)
        }
        if name.contains("conv1d") { return uniform(-0.3 ..< 0.3) }
        return uniform(-0.02 ..< 0.02)
    }

    static func fence(_ roots: [MLXArray]) throws {
        try MLX.withError { error in
            eval(roots)
            try error.check()
        }
    }

    static func bytes(_ array: MLXArray) -> Data { array.asData(access: .copy).data }

    /// One request as the runtime runs it: prefill, prompt priming, the first
    /// token, then rounds.
    final class Request {
        let cache: GLM5NextTextStageCache
        let speculation: GLM5NextTensorParallelSpeculation
        var last: Int
        var tokens: [Int] = []

        init(stage: GLM5NextTextStage, mtp: GLM5NextMTP, prompt: [Int]) throws {
            cache = stage.newCache()
            speculation = try GLM5NextTensorParallelSpeculation(mtp: mtp, depth: 2, rank: 0, ranks: 1,
                primeRows: 512, agree: { $0 })
            let candidate = try stage.prepareForward(tokens: MLXArray(prompt.map(Int32.init), [1, prompt.count]),
                cache: cache, readout: .allTokens)
            try candidate.commit(afterEvaluating: fence)
            guard case .final(let output) = candidate.output else { throw ProbeError("no readout") }
            try speculation.primePrompt(prompt, from: 0, to: prompt.count, hidden: output.hidden)
            last = Int(argMax(output.logits[0, -1].asType(.float32), axis: -1).item(Int32.self))
            try speculation.begin(carry: last, lastHidden: output.hidden[0..., (prompt.count - 1)..., 0...])
        }
    }

    @Test(.enabled(if: enabled), arguments: [2, 4, 7])
    func roundsAreEachRequestsOwnRound(lanes: Int) throws {
        try Device.withDefaultDevice(.gpu) {
            let declared = try Self.configuration()
            let inventory = try GLM5NextWeightInventory.validate(configuration: declared,
                tensors: GLM5NextWeightInventory.expectedTensors(configuration: declared, storage: .nvfp4Hybrid,
                    shard: "rows.safetensors"), storage: .nvfp4Hybrid)
            let resolve: (String) throws -> MLXArray = { name in
                guard let entry = inventory.entries[name] else { throw ProbeError("missing \(name)") }
                return Self.tensor(entry)
            }
            let text = declared.textConfig
            let stage = try GLM5NextTextStage(plan: .init(configuration: text, layers: 0 ..< text.hiddenLayers),
                inventory: inventory, tensor: resolve, materializeExpertStack: { eval($0) },
                releaseSourceTensors: { _ in }, executionPolicy: .serving, materializeFusedProjections: { eval($0) })
            let mtp = try GLM5NextMTP(stage: stage, tensor: resolve, materializeExpertStack: { eval($0) },
                releaseSourceTensors: { _ in }, materializeFusedProjections: { eval($0) })
            let lengths = [7, 300, 41, 2_061, 12, 129, 650]
            let prompts = (0..<lanes).map { lane in
                (0..<lengths[lane % lengths.count]).map { (($0 + 3) * 7919 + lane * 104_729) % text.vocabularySize }
            }
            let batched = try prompts.map { try Request(stage: stage, mtp: mtp, prompt: $0) }
            let alone = try prompts.map { try Request(stage: stage, mtp: mtp, prompt: $0) }
            for round in 0..<5 {
                // The last round of a request whose output limit leaves one
                // token verifies only `last` (window 0).
                let windows = (0..<lanes).map { lane in round == 4 && lane % 3 == 1 ? 0 : 2 }
                let decided = try GLM5NextTensorParallelSpeculation.rounds(stage: stage, lanes: zip(batched, windows).map {
                    .init(speculation: $0.speculation, cache: $0.cache, last: $0.last, window: $1, stop: 0)
                })
                for (lane, request) in alone.enumerated() {
                    let own = try request.speculation.round(stage: stage, cache: request.cache, last: request.last,
                        window: windows[lane], stop: 0)
                    #expect(decided[lane] == own, "lanes \(lanes) round \(round) lane \(lane)")
                    request.tokens += own.tokens; request.last = own.tokens.last!
                    batched[lane].tokens += decided[lane].tokens; batched[lane].last = decided[lane].tokens.last!
                }
            }
            for (lane, (a, b)) in zip(batched, alone).enumerated() {
                #expect(a.tokens == b.tokens, "lane \(lane) tokens")
                #expect(a.cache.offset == b.cache.offset, "lane \(lane) offset")
                let left = a.cache.layers.flatMap(\.state), right = b.cache.layers.flatMap(\.state)
                #expect(left.count == right.count)
                for (index, (x, y)) in zip(left, right).enumerated() {
                    #expect(Self.bytes(x) == Self.bytes(y), "lane \(lane) state \(index)")
                }
                let history = try a.speculation.evaluationTargets(), own = try b.speculation.evaluationTargets()
                try Self.fence(history + own)
                #expect(history.count == own.count)
                for (x, y) in zip(history, own) { #expect(Self.bytes(x) == Self.bytes(y), "lane \(lane) NextN history") }
                #expect(a.speculation.rounds == b.speculation.rounds
                    && a.speculation.acceptedTokens == b.speculation.acceptedTokens
                    && a.speculation.proposedTokens == b.speculation.proposedTokens)
            }
        }
    }
}
