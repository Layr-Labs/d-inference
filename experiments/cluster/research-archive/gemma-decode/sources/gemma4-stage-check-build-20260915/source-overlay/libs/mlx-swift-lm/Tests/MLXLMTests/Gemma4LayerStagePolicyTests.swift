import Foundation
import MLXLMCommon
import Testing
@testable import MLXLLM

/// Value-only tests: none constructs a Module or MLXArray. Native constructor,
/// loaded dtype and whole/split numerical checks remain separately required.
@Suite("Gemma4 global stage geometry and prefill policy")
struct Gemma4LayerStagePolicyTests {
    private func fields() -> [String: Any] {
        var quantization: [String: Any] = ["bits": 4, "group_size": 64, "mode": "affine"]
        for index in 0..<30 {
            for suffix in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"] {
                quantization["language_model.model.layers.\(index).\(suffix)"] =
                    ["bits": 8, "group_size": 64]
            }
        }
        return ["model_type": "gemma4", "vocab_size": 262_144,
            "quantization": quantization,
            "text_config": [
                "model_type": "gemma4_text", "hidden_size": 2_816,
                "num_hidden_layers": 30, "intermediate_size": 2_112,
                "num_attention_heads": 16, "num_key_value_heads": 8,
                "num_global_key_value_heads": 2, "head_dim": 256,
                "global_head_dim": 512, "sliding_window": 1_024,
                "layer_types": (0..<30).map { ($0 + 1).isMultiple(of: 6)
                    ? "full_attention" : "sliding_attention" },
                "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 0,
                "use_double_wide_mlp": false, "tie_word_embeddings": true,
                "attention_k_eq_v": true, "final_logit_softcapping": 30,
                "rms_norm_eps": 1e-6, "enable_moe_block": true,
                "num_experts": 128, "top_k_experts": 8, "moe_intermediate_size": 704,
                "use_bidirectional_attention": "vision",
                "rope_parameters": [
                    "sliding_attention": ["rope_theta": 10_000],
                    "full_attention": ["rope_theta": 1_000_000, "partial_rotary_factor": 0.25]
                ]
            ] as [String: Any]]
    }

    private func config(_ fields: [String: Any]? = nil) throws -> Gemma4Configuration {
        try JSONDecoder().decode(Gemma4Configuration.self,
            from: JSONSerialization.data(withJSONObject: fields ?? self.fields()))
    }

    @Test func allCutsKeepGlobalAttentionAndLocalCacheIndices() throws {
        let original = try config()
        for cut in 1..<30 {
            let left = try Gemma4LayerStageLayout(originalConfiguration: original,
                rank: 0, sourceLayerRange: 0..<cut)
            let right = try Gemma4LayerStageLayout(originalConfiguration: original,
                rank: 1, sourceLayerRange: cut..<30)
            #expect(left.globalLayerIndices + right.globalLayerIndices == Array(0..<30))
            #expect(!left.ownsFinalOutput && right.ownsFinalOutput)
            for layout in [left, right] {
                for (local, global) in layout.globalLayerIndices.enumerated() {
                    let kind = layout.layerKinds[local]
                    #expect(kind.modelLayerIndex == local && kind.sharesKVWithLayer == nil)
                    #expect(kind.queryHeads == 16)
                    #expect(kind.attention == ((global + 1).isMultiple(of: 6) ? .full : .slidingWindow(1_024)))
                    #expect(kind.kvHeads == ((global + 1).isMultiple(of: 6) ? 2 : 8))
                    #expect(kind.headDim == ((global + 1).isMultiple(of: 6) ? 512 : 256))
                }
            }
        }
    }

    @Test func refusesInvalidRangesAndResponsibilities() throws {
        let original = try config()
        for (rank, range) in [(0, 0..<0), (0, 0..<30), (0, 1..<15),
            (1, 0..<30), (1, 15..<29), (2, 15..<30), (1, -1..<30)] {
            #expect(throws: Gemma4LayerStageError.self) {
                try Gemma4LayerStageLayout(originalConfiguration: original,
                    rank: rank, sourceLayerRange: range)
            }
        }
    }

    @Test func rejectsCompactedOrUnsupportedOriginalGeometry() throws {
        for (key, value) in [("num_hidden_layers", 15), ("num_kv_shared_layers", 1),
            ("hidden_size_per_layer_input", 8), ("sliding_window", 512)] {
            var data = fields();var text = data["text_config"] as! [String: Any]
            text[key] = value;data["text_config"] = text
            let original = try config(data)
            #expect(throws: Gemma4LayerStageError.self) {
                try Gemma4LayerStageLayout(originalConfiguration: original,
                    rank: 0, sourceLayerRange: 0..<15)
            }
        }
    }

    @Test func retainsMixedPrecisionAndSplitExpertEligibility() throws {
        let original = try config()
        #expect(gemma4SupportsCoupledExpertOptimizations(original.textConfig))
        for mutation in 0..<3 {
            var data = fields();var policy = data["quantization"] as! [String: Any]
            let shared = "language_model.model.layers.0.mlp.gate_proj"
            if mutation == 0 { policy.removeValue(forKey: shared) }
            if mutation == 1 { policy[shared] = ["bits": 4, "group_size": 64] }
            if mutation == 2 {
                policy["language_model.model.layers.0.experts.switch_glu.gate_proj"] =
                    ["bits": 4, "group_size": 64]
            }
            data["quantization"] = policy
            let changed = try config(data)
            #expect(throws: Gemma4LayerStageError.self) {
                try Gemma4LayerStageLayout(originalConfiguration: changed,
                    rank: 0, sourceLayerRange: 0..<15)
            }
        }
    }

    @Test func rankZeroAlwaysPreservesEveryResidualRow() throws {
        let original = try config().textConfig
        for global in 0..<30 {
            let policy = gemma4LayerPrefillPolicy(original,
                globalLayerIndex: global, finalOutputLayerIndex: 29, ownsFinalOutput: false,
                schedulePrefill: true, isCBv2: true, batchSize: 1,
                sequenceLength: 512, inputSequenceLength: 512, hasLastQueryCache: true,
                tailRows: 1, minimumTailChunk: 128, submissionInterval: 18, lastQueryEnabled: true)
            #expect(policy.outputTailRows == nil && !policy.useLastQuery)
        }
    }

    @Test func onlyGlobalFinalLayerCanUseLastQuery() throws {
        let original = try config().textConfig
        for global in 0..<30 {
            let policy = gemma4LayerPrefillPolicy(original,
                globalLayerIndex: global, finalOutputLayerIndex: 29, ownsFinalOutput: true,
                schedulePrefill: true, isCBv2: true, batchSize: 1,
                sequenceLength: 512, inputSequenceLength: 512, hasLastQueryCache: true,
                tailRows: 1, minimumTailChunk: 128, submissionInterval: 18, lastQueryEnabled: true)
            #expect(policy.useLastQuery == (global == 29))
            #expect(policy.outputTailRows == (global == 29 ? 1 : nil))
            #expect(policy.submitIntermediate == (global == 17))
        }
    }

    @Test func fullTrunkPolicyMatchesPreExtractionConditions() throws {
        let original = try config().textConfig
        for count in [15, 30] {
            for global in 0..<count {
                for length in [1, 16, 128, 512] {
                    for tail in [0, 1, 8] {
                        for schedule in [false, true] {
                            let final = schedule && global == count - 1 && length >= 128
                            let oldTail: Int? = final && tail > 0 ? min(tail, length) : nil
                            let policy = gemma4LayerPrefillPolicy(original,
                                globalLayerIndex: global, finalOutputLayerIndex: count - 1,
                                ownsFinalOutput: true, schedulePrefill: schedule, isCBv2: true,
                                batchSize: 1, sequenceLength: length, inputSequenceLength: length,
                                hasLastQueryCache: true, tailRows: tail, minimumTailChunk: 128,
                                submissionInterval: 18, lastQueryEnabled: true)
                            #expect(policy.outputTailRows == oldTail)
                            #expect(policy.useLastQuery == gemma4UseLastQueryPrefill(original,
                                layerIdx: global, batchSize: 1, sequenceLength: length,
                                outputTailRows: oldTail, hasCapableCache: true, enabled: true))
                            #expect(policy.expertPrefill == schedule)
                            #expect(policy.submitIntermediate == (schedule && length > 1 && (global + 1).isMultiple(of: 18)))
                        }
                    }
                }
            }
        }
    }
}
