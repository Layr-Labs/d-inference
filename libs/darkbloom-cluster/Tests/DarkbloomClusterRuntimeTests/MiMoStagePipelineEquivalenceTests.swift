import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// The cut itself, on a model small enough to hold twice: a four-layer MiMo
// V2.6 text model with random weights (one dense layer, three routed layers;
// full and sliding-window attention with a window shorter than the prompt) is
// run whole, and as the two compact stages the Plan constructs, with the whole
// model's own tensors assigned to them through the Plan's mapping. The stages
// are driven the way the stage session drives them: stage 0 from token IDs to
// the residual captured after its last layer, stage 1 from that residual to
// logits. This checks the architecture claim the adapter rests on (only the
// residual crosses a layer boundary, and each stage's caches keep positions),
// the compact configurations and the tensor mapping. It uses no artifact and
// says nothing about the registered weights, their packing or speed.

@Suite("MiMo layer stages reproduce the whole text model (tiny random model)")
struct MiMoStagePipelineEquivalenceTests {
    static let layers = 4, vocabulary = 97, hidden = 64, window = 3

    static func configuration(dtype: String) -> Data {
        Data("""
        {"model_type":"mimo_v2","architectures":["MiMoV2ForCausalLM"],"hidden_size":64,"intermediate_size":128,
         "moe_intermediate_size":32,"vocab_size":97,"num_hidden_layers":4,"max_position_embeddings":4096,
         "sliding_window":3,"sliding_window_size":3,"num_nextn_predict_layers":0,
         "hybrid_layer_pattern":[0,1,1,0],"moe_layer_freq":[0,1,1,1],"partial_rotary_factor":0.5,
         "attention_value_scale":0.707,"layernorm_epsilon":0.000001,"attention_projection_layout":"fused_qkv",
         "moe_router_dtype":"\(dtype)","hidden_act":"silu","dtype":"\(dtype)","attention_bias":false,
         "tie_word_embeddings":false,"attention_dropout":0.0,"scoring_func":"sigmoid","topk_method":"noaux_tc",
         "n_routed_experts":8,"num_experts_per_tok":2,"n_group":1,"topk_group":1,"norm_topk_prob":true,
         "num_attention_heads":4,"num_key_value_heads":2,"head_dim":16,"v_head_dim":8,"rope_theta":10000.0,
         "add_full_attention_sink_bias":false,"swa_num_attention_heads":4,"swa_num_key_value_heads":2,
         "swa_head_dim":16,"swa_v_head_dim":8,"swa_rope_theta":10000.0,"add_swa_attention_sink_bias":true,
         "eos_token_id":[1,2],"pad_token_id":0}
        """.utf8)
    }

    /// Random weights in the model's own activation dtype; the router's score
    /// correction stays float32, as it is stored.
    static func whole(_ data: Data, dtype: DType) throws -> MiMoV26TextModel {
        let model = try withRandomState(MLXRandom.RandomState(seed: 11)) { () throws -> MiMoV26TextModel in
            let model = try MiMoV26TextModel(JSONDecoder().decode(MiMoV26Configuration.self, from: data))
            let cast = model.parameters().flattened().map { name, value in
                (name, name.hasSuffix("e_score_correction_bias") ? value : value.asType(dtype))
            }
            try model.update(parameters: ModuleParameters.unflattened(cast), verify: [.noUnusedKeys, .shapeMismatch])
            eval(model)
            return model
        }
        model.freeze()
        return model
    }

    static func stages(_ plan: MiMoLayerStagePlan, from whole: MiMoV26TextModel, dtype: DType) throws -> [MiMoV26TextModel] {
        let source = Dictionary(uniqueKeysWithValues: whole.parameters().flattened())
        return try plan.stages.map { stage in
            let model = try MiMoV26TextModel(plan.productConfiguration(stage: stage.index))
            var assigned: [(String, MLXArray)] = []
            for name in source.keys.sorted() {
                guard let owner = try plan.parameter(sourceName: MiMoLayerStagePlan.sourceNamespace + name),
                      owner.stage == stage.index else { continue }
                assigned.append((owner.localName, source[name]!))
            }
            // Every parameter of the compact stage is either assigned or its one placeholder.
            let own = Set(model.parameters().flattened().map(\.0))
            let placeholder = stage.index == 0 ? ["model.norm.weight"] : ["model.embed_tokens.weight"]
            #expect(own == Set(assigned.map(\.0)).union(placeholder), "stage \(stage.index)")
            if stage.index == 0 {
                // As the loader leaves it: ones in the activation dtype, never read for the residual.
                assigned.append(("model.norm.weight", MLXArray.ones([hidden], dtype: dtype)))
            }
            try model.update(parameters: ModuleParameters.unflattened(assigned), verify: [.shapeMismatch])
            model.freeze()
            return model
        }
    }

    /// Greedy generation with the whole model: one row of logits per selected token.
    static func runWhole(_ model: MiMoV26TextModel, prompt: [Int], chunk: Int, outputs: Int) throws -> [MLXArray] {
        let cache = model.newCache()
        var rows: [MLXArray] = [], offset = 0
        while offset < prompt.count {
            let part = Array(prompt[offset..<min(prompt.count, offset + chunk)])
            let out = try model.forward(inputIDs: MLXArray(part.map(Int32.init)).reshaped([1, part.count]),
                                        cache: cache, logitsStart: part.count - 1)
            offset += part.count
            if offset == prompt.count { rows.append(out.logits[0..., -1, 0...]) } else { eval(cache.flatMap { $0.innerState() }) }
        }
        while rows.count < outputs {
            let token = Int32(argMax(rows[rows.count - 1], axis: -1).item(UInt32.self))
            rows.append(try model.forward(inputIDs: MLXArray([token]).reshaped([1, 1]), cache: cache).logits[0..., -1, 0...])
        }
        eval(rows)
        return rows
    }

    /// The same request through two stages, as `MiMoLayerStageSession` runs them.
    static func runStaged(_ stages: [MiMoV26TextModel], prompt: [Int], chunk: Int, outputs: Int) throws -> [MLXArray] {
        let caches = stages.map { $0.newCache() }
        let last = stages[0].configuration.numHiddenLayers - 1
        func step(_ tokens: [Int]) throws -> MLXArray {
            let residual: MLXArray = try {
                let out = try stages[0].forward(inputIDs: MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count]),
                                                cache: caches[0], captureLayers: [last])
                return try #require(out.layerFeatures[last])
            }()
            eval([residual] + caches[0].flatMap { $0.innerState() })
            #expect(residual.shape == [1, tokens.count, hidden])
            // What crosses the cut is bytes: the consumer gets a copy with no graph behind it.
            let received = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
            let row = try stages[1].forward(embeddings: received, cache: caches[1], logitsStart: tokens.count - 1)
                .logits[0..., -1, 0...]
            eval([row] + caches[1].flatMap { $0.innerState() })
            #expect(caches.allSatisfy { $0.allSatisfy { $0.offset == caches[0][0].offset } })
            return row
        }
        var rows: [MLXArray] = [], offset = 0
        while offset < prompt.count {
            let part = Array(prompt[offset..<min(prompt.count, offset + chunk)])
            let row = try step(part)
            offset += part.count
            if offset == prompt.count { rows.append(row) }
        }
        while rows.count < outputs {
            rows.append(try step([Int(argMax(rows[rows.count - 1], axis: -1).item(UInt32.self))]))
        }
        return rows
    }

    @Test(arguments: ["float32", "bfloat16"])
    func everyCutReproducesTheWholeModel(dtypeName: String) throws {
        let dtype: DType = dtypeName == "float32" ? .float32 : .bfloat16
        let data = Self.configuration(dtype: dtypeName)
        let whole = try Self.whole(data, dtype: dtype)
        // Eleven prompt tokens in chunks of four against a window of three, then decode.
        let prompt = [5, 17, 3, 44, 96, 8, 21, 60, 2, 33, 71]
        let reference = try Self.runWhole(whole, prompt: prompt, chunk: 4, outputs: 6)
        let expectedTokens = reference.map { Int(argMax($0, axis: -1).item(UInt32.self)) }
        #expect(reference.allSatisfy { all(isFinite($0)).item(Bool.self) })
        for cut in 1..<Self.layers {
            let plan = try MiMoLayerStagePlan(configuration: data, cut: cut)
            let stages = try Self.stages(plan, from: whole, dtype: dtype)
            let rows = try Self.runStaged(stages, prompt: prompt, chunk: 4, outputs: 6)
            #expect(rows.map { Int(argMax($0, axis: -1).item(UInt32.self)) } == expectedTokens, "cut \(cut) \(dtypeName)")
            for (index, row) in rows.enumerated() {
                let difference = abs(row.asType(.float32) - reference[index].asType(.float32)).max().item(Float.self)
                #expect(difference == 0, "cut \(cut) \(dtypeName) row \(index): logits differ by \(difference)")
            }
        }
    }
}
