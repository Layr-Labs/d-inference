import Foundation
import MLX
import MLXLMCommon
import Testing
@testable import MLXLLM
@testable import DarkbloomClusterRuntime

@Suite("MiMo paged phase state and speculative rollback", .serialized)
struct MiMoPagedPhaseStateTests {
    @Test func physicalRingHandoffAndContinuationMatchOriginalCaches() throws {
        try Device.withDefaultDevice(.cpu) {
            let configuration = try configuration()
            for frames in [[1], [1, 1, 1], [4, 4, 4, 1], [64, 64, 1], [67, 1, 1, 3, 64]] {
                let ordinary: [any KVCache] = [KVCacheSimple(), RotatingKVCache(maxSize: 65)]
                let pages = try makePages(configuration)
                for count in frames { try append(count, to: ordinary, configuration: configuration); try append(count, to: pages, configuration: configuration) }
                let shapes = try MiMoPhaseSplitState.expectedShapes(stage: configuration, firstGlobalLayer: 0,
                    frames: frames, activationDType: "bfloat16")
                let reference = try MiMoPhaseSplitState.exportArrays(caches: ordinary, configuration: configuration, frames: frames, shapes: shapes)
                let actual = try MiMoPhaseSplitState.exportArrays(caches: pages, configuration: configuration, frames: frames, shapes: shapes)
                equal(reference, actual)
                let state = transferred(actual, shapes: shapes, committed: frames.reduce(0, +))
                let adopted = try makePages(configuration)
                try MiMoPhaseSplitState.install(state, into: adopted, shapes: shapes, frames: frames, configuration: configuration)
                equal(pages.flatMap(\.state), adopted.flatMap(\.state))
                #expect(zip(pages, adopted).allSatisfy { $0.metaState == $1.metaState })
                let originalBytes = pages.flatMap(\.state).map(bytes)
                for count in [1, 3, 1] {
                    try append(count, to: ordinary, configuration: configuration)
                    try append(count, to: adopted, configuration: configuration)
                    equal(ordinary.flatMap(\.state), adopted.flatMap(\.state))
                    #expect(zip(ordinary, adopted).allSatisfy { $0.offset == $1.offset })
                }
                #expect(pages.flatMap(\.state).map(bytes) == originalBytes)
                #expect(adopted.allSatisfy { $0.pageCount > 0 && $0.allocatedBytes > 0 })
            }
        }
    }

    @Test func malformedLastLayerRefusesBeforeAnyRecipientMutation() throws {
        try Device.withDefaultDevice(.cpu) {
            let configuration = try configuration(), frames = [67, 1]
            let source = try makePages(configuration)
            for count in frames { try append(count, to: source, configuration: configuration) }
            let shapes = try MiMoPhaseSplitState.expectedShapes(stage: configuration, firstGlobalLayer: 0,
                frames: frames, activationDType: "bfloat16")
            let arrays = try MiMoPhaseSplitState.exportArrays(caches: source, configuration: configuration, frames: frames, shapes: shapes)
            for invalidDtype in [false, true] {
                var broken = arrays
                broken[3] = invalidDtype ? broken[3].asType(.float32) : broken[3][0..., 0..., ..<64, 0...]
                let fresh = try makePages(configuration)
                #expect(throws: (any Error).self) {
                    try MiMoPhaseSplitState.install(transferred(broken, shapes: shapes, committed: 68), into: fresh,
                        shapes: shapes, frames: frames, configuration: configuration)
                }
                #expect(fresh.allSatisfy { $0.offset == 0 && $0.pageCount == 0 && $0.allocatedBytes == 0 })
            }
            let fresh = try makePages(configuration)
            #expect(throws: (any Error).self) {
                try MiMoPhaseSplitState.install(transferred(arrays, shapes: shapes, committed: 68), into: fresh,
                    shapes: shapes, frames: [68], configuration: configuration)
            }
            #expect(fresh.allSatisfy { $0.offset == 0 && $0.pageCount == 0 })
        }
    }

    @Test func windowRollbackChecksEveryLayerBeforeMutatingAndKeepsExactSuffix() throws {
        try Device.withDefaultDevice(.cpu) {
            let configuration = try configuration()
            for removed in 0...3 {
                let pages = try makePages(configuration)
                let ordinary: [any KVCache] = [KVCacheSimple(), RotatingKVCache(maxSize: 65)]
                for count in [67, 1, 1, 4] { try append(count, to: pages, configuration: configuration); try append(count, to: ordinary, configuration: configuration) }
                try MiMoWindowRollback.trim(pages, by: removed)
                try MiMoWindowRollback.trim(ordinary, by: removed)
                equal(ordinary.flatMap(\.state), pages.flatMap(\.state))
                for count in [1, 3] { try append(count, to: pages, configuration: configuration); try append(count, to: ordinary, configuration: configuration) }
                equal(ordinary.flatMap(\.state), pages.flatMap(\.state))
            }
            let invalid = try makePages(configuration)
            for count in [67, 4] { try append(count, to: invalid, configuration: configuration) }
            // Only the later sliding layer advances once: a single append is
            // not a verified window and must reject before trimming layer zero.
            let g = try configuration.attentionGeometry(at: 1)
            let values = inputs(g, count: 1, offset: invalid[1].offset)
            _ = invalid[1].update(keys: values.0, values: values.1)
            let original = invalid.map { ($0.offset, $0.state.map(bytes)) }
            #expect(throws: (any Error).self) { try MiMoWindowRollback.trim(invalid, by: 1) }
            for (cache, prior) in zip(invalid, original) { #expect(cache.offset == prior.0 && cache.state.map(bytes) == prior.1) }
        }
    }

    func configuration() throws -> MiMoV26Configuration {
        let data = Data("""
        {"model_type":"mimo_v2","architectures":["MiMoV2ForCausalLM"],"hidden_size":64,"intermediate_size":128,
         "moe_intermediate_size":32,"vocab_size":97,"num_hidden_layers":2,"max_position_embeddings":512,
         "sliding_window":65,"sliding_window_size":65,"num_nextn_predict_layers":0,
         "hybrid_layer_pattern":[0,1],"moe_layer_freq":[0,1],"partial_rotary_factor":0.5,
         "attention_value_scale":0.707,"layernorm_epsilon":0.000001,"attention_projection_layout":"split",
         "moe_router_dtype":"bfloat16","hidden_act":"silu","dtype":"bfloat16","attention_bias":false,
         "tie_word_embeddings":false,"attention_dropout":0,"scoring_func":"sigmoid","topk_method":"noaux_tc",
         "n_routed_experts":8,"num_experts_per_tok":2,"n_group":1,"topk_group":1,"norm_topk_prob":true,
         "num_attention_heads":4,"num_key_value_heads":2,"head_dim":16,"v_head_dim":8,"rope_theta":10000,
         "add_full_attention_sink_bias":false,"swa_num_attention_heads":4,"swa_num_key_value_heads":2,
         "swa_head_dim":16,"swa_v_head_dim":8,"swa_rope_theta":10000,"add_swa_attention_sink_bias":true,
         "eos_token_id":[1,2],"pad_token_id":0}
        """.utf8)
        return try JSONDecoder().decode(MiMoV26Configuration.self, from: data)
    }
    private func makePages(_ configuration: MiMoV26Configuration) throws -> [MiMoV26IndependentHistoryCache] {
        let model = UUID(), request = UUID()
        return try (0..<configuration.numHiddenLayers).map { index in
            let geometry = try configuration.attentionGeometry(at: index)
            return MiMoV26IndependentHistoryCache(modelIdentity: model, requestIdentity: request,
                layerIndex: index, maximumContext: configuration.maxPositionEmbeddings,
                heads: geometry.keyValueHeads, keyWidth: geometry.headDim, valueWidth: geometry.valueHeadDim,
                dtype: .bfloat16, window: geometry.slidingWindow)
        }
    }
    private func append(_ count: Int, to caches: [any KVCache], configuration: MiMoV26Configuration) throws {
        for (index, cache) in caches.enumerated() {
            let g = try configuration.attentionGeometry(at: index), pair = inputs(g, count: count, offset: cache.offset)
            _ = cache.update(keys: pair.0, values: pair.1)
        }
    }
    private func inputs(_ g: MiMoV26AttentionGeometry, count: Int, offset: Int) -> (MLXArray, MLXArray) {
        func array(_ width: Int, salt: Int) -> MLXArray {
            let shape = [1, g.keyValueHeads, count, width]
            return MLXArray((0..<shape.reduce(1, *)).map { Float(($0 + offset * 13 + salt) % 127 - 63) / 64 }, shape).asType(.bfloat16)
        }
        return (array(g.headDim, salt: 3), array(g.valueHeadDim, salt: 29))
    }
    private func transferred(_ arrays: [MLXArray], shapes: [QwenPhaseSplitStateShape], committed: Int) -> QwenLayerStageAdoptedState {
        var attention: [Int: (keys: MLXArray, values: MLXArray)] = [:]
        for layer in 0..<(arrays.count / 2) {
            func copy(_ index: Int) -> MLXArray { MLXArray(bytes(arrays[index]), arrays[index].shape, dtype: arrays[index].dtype) }
            attention[layer] = (copy(2 * layer), copy(2 * layer + 1))
        }
        return .init(committedTokens: committed, attention: attention, recurrent: [:])
    }
    private func bytes(_ array: MLXArray) -> Data { eval(array); return array.asData(access: .copy).data }
    private func equal(_ a: [MLXArray], _ b: [MLXArray]) {
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) { #expect(x.shape == y.shape && x.dtype == y.dtype && bytes(x) == bytes(y)) }
    }
}
