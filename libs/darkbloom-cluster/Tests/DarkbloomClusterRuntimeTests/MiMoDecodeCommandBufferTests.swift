import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

// MiMo stage decode, verify windows and lane steps encode under
// `MiMoLayerStageSession.decodeCommandBuffers` (100 operations a buffer, no
// input-size bound) instead of the rank's 16-operation guard. Only where
// command buffers end may move. Two random MiMo stages are driven as the stage
// session drives them: the prompt under the guard, then decode once under the
// guard and once under the decode limits. Every residual that crosses the cut,
// every logits row and every cache array must be the same bytes, on the
// ordinary caches and on request-owned pages (one request, and two decoded as
// lanes). A tiny bfloat16 model, and one shaped and quantized like the
// registered row (MXFP4 experts, affine 8-bit projections, key width 192 and
// value width 128), whose guard commits at every expert launch as the
// registered row's does (`bankGuard`). No artifact, collective or network.

@Suite("MiMo decode command buffers change no byte (random stages)", .serialized)
struct MiMoDecodeCommandBufferTests {
    typealias P = MiMoStagePipelineEquivalenceTests
    /// The rank's own limits as a worker starts it (`ClusterWorkerEnvironmentGuards`):
    /// 16 operations, MLX's per-chip size bound.
    static let rankGuard = GPU.CommandBufferLimits(operations: 16, megabytes: 0)
    /// The guard scaled to the quantized model's banks. MLX's size bound counts
    /// Mi elements of distinct inputs, so at 1 each 2 Mi-element bank commits a
    /// buffer, as each registered 256 Mi-element bank does at MLX's own 40-50.
    static let bankGuard = GPU.CommandBufferLimits(operations: 16, megabytes: 1)

    /// Hidden 1,024, 16 experts of width 1,024 (8 a token), key width 192 and
    /// value width 128 on four layers (full, sliding, sliding, full).
    static let kernelShapeConfiguration = Data("""
        {"model_type":"mimo_v2","architectures":["MiMoV2ForCausalLM"],"hidden_size":1024,"intermediate_size":2048,
         "moe_intermediate_size":1024,"vocab_size":4096,"num_hidden_layers":4,"max_position_embeddings":4096,
         "sliding_window":8,"sliding_window_size":8,"num_nextn_predict_layers":0,
         "hybrid_layer_pattern":[0,1,1,0],"moe_layer_freq":[0,1,1,1],"partial_rotary_factor":0.334,
         "attention_value_scale":0.707,"layernorm_epsilon":0.000001,"attention_projection_layout":"fused_qkv",
         "moe_router_dtype":"bfloat16","hidden_act":"silu","dtype":"bfloat16","attention_bias":false,
         "tie_word_embeddings":false,"attention_dropout":0.0,"scoring_func":"sigmoid","topk_method":"noaux_tc",
         "n_routed_experts":16,"num_experts_per_tok":8,"n_group":1,"topk_group":1,"norm_topk_prob":true,
         "num_attention_heads":8,"num_key_value_heads":2,"head_dim":192,"v_head_dim":128,"rope_theta":10000000.0,
         "add_full_attention_sink_bias":false,"swa_num_attention_heads":8,"swa_num_key_value_heads":4,
         "swa_head_dim":192,"swa_v_head_dim":128,"swa_rope_theta":10000.0,"add_swa_attention_sink_bias":true,
         "eos_token_id":[1,2],"pad_token_id":0}
        """.utf8)

    /// The two stages of `cut` with random bfloat16 weights, quantized like
    /// the registered row when asked (the router stays bfloat16).
    static func randomStages(_ data: Data, cut: Int, quantized: Bool) throws -> [MiMoV26TextModel] {
        let plan = try MiMoLayerStagePlan(configuration: data, cut: cut)
        return try plan.stages.map { stage in
            try withRandomState(MLXRandom.RandomState(seed: UInt64(23 + stage.index))) { () throws -> MiMoV26TextModel in
                let model = try MiMoV26TextModel(plan.productConfiguration(stage: stage.index))
                let cast = model.parameters().flattened().map { name, value in
                    (name, name.hasSuffix("e_score_correction_bias") ? value : value.asType(.bfloat16))
                }
                try model.update(parameters: ModuleParameters.unflattened(cast), verify: [.noUnusedKeys, .shapeMismatch])
                if quantized {
                    quantize(model: model, filter: { path, _ -> (groupSize: Int, bits: Int, mode: QuantizationMode)? in
                        path.contains("switch_mlp") ? (32, 4, .mxfp4) : (64, 8, .affine)
                    })
                }
                eval(model)
                model.freeze()
                return model
            }
        }
    }

    static func greedy(_ row: MLXArray) -> Int { Int(argMax(row, axis: -1).item(UInt32.self)) }

    /// One request through both stages: the prompt in frames of four under
    /// the rank's guard, then five decode steps, a verify window of three
    /// drafts rolled back to its first two rows on both stages, and four more
    /// steps, each under `limits`. Every residual that crossed the cut, every
    /// logits row and, at the end, every cache array, in order, as bytes.
    static func trace(_ stages: [MiMoV26TextModel], paged: Bool, prompt: [Int],
                      decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        let pages = try paged ? stages.map { try $0.makeIndependentHistoryCaches() } : []
        let caches: [[KVCache]] = paged ? pages.map { $0 as [KVCache] } : stages.map { $0.newCache() }
        let last = stages[0].configuration.numHiddenLayers - 1
        let vocabulary = stages[1].configuration.vocabularySize
        var recorded: [Data] = []
        func forward(_ tokens: [Int], logitsStart: Int) throws -> MLXArray {
            let input = MLXArray(tokens.map(Int32.init)).reshaped([1, tokens.count])
            let produced = try paged
                ? stages[0].forwardIndependentHistory(inputIDs: input, caches: pages[0], captureLayers: [last])
                : stages[0].forward(inputIDs: input, cache: caches[0], captureLayers: [last])
            let residual = try #require(produced.layerFeatures[last])
            eval([residual] + caches[0].flatMap { $0.innerState() })
            // What crosses the cut is bytes: the consumer gets a copy with no graph behind it.
            let crossed = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
            let consumed = try paged
                ? stages[1].forwardIndependentHistory(embeddings: crossed, caches: pages[1], logitsStart: logitsStart)
                : stages[1].forward(embeddings: crossed, cache: caches[1], logitsStart: logitsStart)
            eval([consumed.logits] + caches[1].flatMap { $0.innerState() })
            recorded += [residual.asData().data, consumed.logits.asData().data]
            return consumed.logits
        }
        var logits = MLXArray(0)
        try GPU.withCommandBufferLimits(rankGuard) {
            var offset = 0
            while offset < prompt.count {
                let part = Array(prompt[offset..<min(prompt.count, offset + 4)])
                logits = try forward(part, logitsStart: part.count - 1)
                offset += part.count
            }
        }
        try GPU.withCommandBufferLimits(limits) {
            var token = greedy(logits[0, -1])
            for _ in 0..<5 { token = greedy(try forward([token], logitsStart: 0)[0, -1]) }
            let window = [token, (token + 1) % vocabulary, (token + 7) % vocabulary, (token + 3) % vocabulary]
            let rows = try forward(window, logitsStart: 0)
            for stage in caches { try MiMoWindowRollback.trim(stage, by: window.count - 2) }
            token = greedy(rows[0, 1])
            for _ in 0..<4 { token = greedy(try forward([token], logitsStart: 0)[0, -1]) }
        }
        recorded += caches.flatMap { $0.flatMap { $0.innerState() } }.map { $0.asData().data }
        return recorded
    }

    /// Two requests on pages, each prompt alone under the rank's guard, then
    /// five steps decoding both as lanes (`MiMoLayerStageSession.decodeBatch`'s
    /// calls) under `limits`. The residual rows, logits rows and every page, as bytes.
    static func laneTrace(_ stages: [MiMoV26TextModel], prompts: [[Int]],
                          decode limits: GPU.CommandBufferLimits) throws -> [Data] {
        let last = stages[0].configuration.numHiddenLayers - 1
        let histories = try prompts.map { _ in try stages.map { try $0.makeIndependentHistoryCaches() } }
        var recorded: [Data] = [], tokens: [Int] = []
        try GPU.withCommandBufferLimits(rankGuard) {
            for (request, prompt) in prompts.enumerated() {
                var offset = 0, logits = MLXArray(0)
                while offset < prompt.count {
                    let part = Array(prompt[offset..<min(prompt.count, offset + 4)])
                    let produced = try stages[0].forwardIndependentHistory(
                        inputIDs: MLXArray(part.map(Int32.init)).reshaped([1, part.count]),
                        caches: histories[request][0], captureLayers: [last])
                    let residual = try #require(produced.layerFeatures[last])
                    eval([residual] + histories[request][0].flatMap { $0.innerState() })
                    let crossed = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
                    logits = try stages[1].forwardIndependentHistory(embeddings: crossed, caches: histories[request][1],
                        logitsStart: part.count - 1).logits
                    eval([logits] + histories[request][1].flatMap { $0.innerState() })
                    offset += part.count
                }
                tokens.append(greedy(logits[0, -1]))
            }
        }
        try GPU.withCommandBufferLimits(limits) {
            for _ in 0..<5 {
                let produced = try stages[0].decodeIndependentHistories(
                    inputIDs: MLXArray(tokens.map(Int32.init)).reshaped([tokens.count, 1]),
                    caches: histories.map { $0[0] }, captureLayers: [last])
                let residual = concatenated(try produced.map { try #require($0.layerFeatures[last]) }, axis: 0)
                eval([residual] + histories.flatMap { $0[0].flatMap { $0.innerState() } })
                let crossed = MLXArray(residual.asData().data, residual.shape, dtype: residual.dtype)
                let consumed = try stages[1].decodeIndependentHistories(embeddings: crossed,
                                                                         caches: histories.map { $0[1] })
                let rows = concatenated(consumed.map { $0.logits[0..., -1, 0...] }, axis: 0)
                eval([rows] + histories.flatMap { $0[1].flatMap { $0.innerState() } })
                recorded += [residual.asData().data, rows.asData().data]
                tokens = (0..<tokens.count).map { greedy(rows[$0]) }
            }
        }
        recorded += histories.flatMap { $0.flatMap { $0.flatMap { $0.innerState() } } }.map { $0.asData().data }
        return recorded
    }

    static func requireSameBytes(_ guarded: [Data], _ decoded: [Data], _ label: String) {
        #expect(guarded.count == decoded.count && !guarded.isEmpty, "\(label): \(guarded.count) against \(decoded.count) arrays")
        let first = zip(guarded, decoded).enumerated().first { $0.element.0 != $0.element.1 }?.offset
        #expect(first == nil, "\(label): array \(first ?? -1) of \(guarded.count) differs")
    }

    @Test func theDecodeLimitsAreTheTensorParallelRuntimes() {
        #expect(MiMoLayerStageSession.decodeCommandBuffers == .init(operations: 100, megabytes: 1 << 20))
        #expect(MiMoLayerStageSession.decodeCommandBuffers == GLM5NextTensorParallelResidentRuntime.decodeCommandBuffers)
        #expect(MiMoLayerStageSession.decodeCommandBuffers == QwenTensorParallelBatchSession.decodeCommandBuffers)
    }

    @Test(arguments: [false, true])
    func tinyStagesDecodeTheSameBytes(paged: Bool) throws {
        let data = P.configuration(dtype: "bfloat16")
        let stages = try P.stages(try MiMoLayerStagePlan(configuration: data, cut: 2),
                                  from: try P.whole(data, dtype: .bfloat16), dtype: .bfloat16)
        let prompt = [5, 17, 3, 44, 96, 8, 21, 60, 2, 33, 71]
        let guarded = try Self.trace(stages, paged: paged, prompt: prompt, decode: Self.rankGuard)
        let decoded = try Self.trace(stages, paged: paged, prompt: prompt, decode: MiMoLayerStageSession.decodeCommandBuffers)
        Self.requireSameBytes(guarded, decoded, "tiny \(paged ? "pages" : "caches")")
    }

    @Test(arguments: [false, true])
    func registeredShapeStagesDecodeTheSameBytes(paged: Bool) throws {
        let stages = try Self.randomStages(Self.kernelShapeConfiguration, cut: 2, quantized: true)
        let prompt = [5, 1017, 3, 2044, 96, 8, 3021, 60, 2, 33, 4071]
        let guarded = try Self.trace(stages, paged: paged, prompt: prompt, decode: Self.bankGuard)
        let decoded = try Self.trace(stages, paged: paged, prompt: prompt, decode: MiMoLayerStageSession.decodeCommandBuffers)
        Self.requireSameBytes(guarded, decoded, "registered shape \(paged ? "pages" : "caches")")
    }

    @Test(arguments: [false, true])
    func lanesDecodeTheSameBytes(registeredShape: Bool) throws {
        let stages: [MiMoV26TextModel]
        if registeredShape {
            stages = try Self.randomStages(Self.kernelShapeConfiguration, cut: 2, quantized: true)
        } else {
            let data = P.configuration(dtype: "bfloat16")
            stages = try P.stages(try MiMoLayerStagePlan(configuration: data, cut: 2),
                                  from: try P.whole(data, dtype: .bfloat16), dtype: .bfloat16)
        }
        let prompts = [[5, 17, 3, 44, 96, 8, 21, 60, 2, 33, 71], [9, 4, 81, 2, 15, 66, 30]]
        let guarded = try Self.laneTrace(stages, prompts: prompts, decode: registeredShape ? Self.bankGuard : Self.rankGuard)
        let decoded = try Self.laneTrace(stages, prompts: prompts, decode: MiMoLayerStageSession.decodeCommandBuffers)
        Self.requireSameBytes(guarded, decoded, "lanes \(registeredShape ? "registered shape" : "tiny")")
    }
}
