import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import Testing
@testable import DarkbloomClusterRuntime

/// Actual BF16 affine8/MXFP4 model arithmetic and the production phase-state
/// codec. This is a tiny CPU fixture, not an artifact or transport qualification.
@Suite("MiMo paged model phase continuation", .serialized)
struct MiMoPagedModelHandoffTests {
    @Test func transferredProducerKeepsEveryContinuationRowAndCacheExact() throws {
        try Device.withDefaultDevice(.cpu) {
            let models = try stages()
            for frames in [[1], [4, 4, 4, 1], [64, 1, 4], [67, 1, 3]] {
                var ordinary = models.map { $0.newCache() }
                var kept: [[any KVCache]] = try models.map { try $0.makeIndependentHistoryCaches() }
                var moved: [[any KVCache]] = try models.map { try $0.makeIndependentHistoryCaches() }
                var offset = 0
                for count in frames {
                    let tokens = (offset..<(offset + count)).map { ($0 * 7 + 5) % 97 }
                    let expected = try step(models, caches: ordinary, tokens: tokens, paged: false)
                    equal(expected, try step(models, caches: kept, tokens: tokens, paged: true))
                    equal(expected, try step(models, caches: moved, tokens: tokens, paged: true))
                    offset += count
                }
                let shapes = try MiMoPhaseSplitState.expectedShapes(stage: models[0].configuration,
                    firstGlobalLayer: 0, frames: frames, activationDType: "bfloat16")
                let arrays = try MiMoPhaseSplitState.exportArrays(caches: moved[0], configuration: models[0].configuration,
                    frames: frames, shapes: shapes)
                let source = moved[0], frozen = source.flatMap(\.state).map(bytes)
                var received: [Int: (keys: MLXArray, values: MLXArray)] = [:]
                for layer in 0..<source.count {
                    func copy(_ index: Int) -> MLXArray { MLXArray(bytes(arrays[index]), arrays[index].shape, dtype: arrays[index].dtype) }
                    received[layer] = (copy(layer * 2), copy(layer * 2 + 1))
                }
                moved[0] = try models[0].makeIndependentHistoryCaches()
                try MiMoPhaseSplitState.install(.init(committedTokens: offset, attention: received, recurrent: [:]),
                    into: moved[0], shapes: shapes, frames: frames, configuration: models[0].configuration)
                equalCaches(ordinary, kept); equalCaches(kept, moved)
                // Includes a multi-row verify window after transfer and ordinary
                // single-token updates through the ring's physical wrap boundary.
                for count in [1, 3, 1, 4, 1] {
                    let tokens = (offset..<(offset + count)).map { ($0 * 11 + 3) % 97 }
                    let expected = try step(models, caches: ordinary, tokens: tokens, paged: false)
                    equal(expected, try step(models, caches: kept, tokens: tokens, paged: true))
                    equal(expected, try step(models, caches: moved, tokens: tokens, paged: true))
                    equalCaches(ordinary, kept); equalCaches(kept, moved)
                    offset += count
                }
                #expect(source.flatMap(\.state).map(bytes) == frozen)
                ordinary.removeAll(); kept.removeAll(); moved.removeAll()
            }
        }
    }

    private func stages() throws -> [MiMoV26TextModel] {
        let original = try MiMoPagedPhaseStateTests().configuration()
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        // Affine group64 requires four value heads to project at least 64
        // columns; keep K and V unequal while using valid packed geometry.
        encoded["num_hidden_layers"] = 4
        encoded["hybrid_layer_pattern"] = [0, 1, 1, 0]
        encoded["moe_layer_freq"] = [0, 1, 1, 1]
        for key in ["head_dim", "swa_head_dim"] { encoded[key] = 32 }
        for key in ["v_head_dim", "swa_v_head_dim"] { encoded[key] = 16 }
        let config = try JSONDecoder().decode(MiMoV26Configuration.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        let whole = try withRandomState(MLXRandom.RandomState(seed: 43)) { try MiMoV26TextModel(config) }
        let weights = Dictionary(uniqueKeysWithValues: whole.parameters().flattened().map { name, value in
            (name, name.hasSuffix("e_score_correction_bias") ? value : value.asType(.bfloat16))
        })
        let plan = try MiMoLayerStagePlan(configuration: JSONEncoder().encode(config), cut: 2)
        return try plan.stages.map { stage in
            let model = try MiMoV26TextModel(plan.productConfiguration(stage: stage.index))
            var assigned: [(String, MLXArray)] = []
            for name in weights.keys.sorted() {
                guard let owner = try plan.parameter(sourceName: MiMoLayerStagePlan.sourceNamespace + name),
                      owner.stage == stage.index else { continue }
                assigned.append((owner.localName, weights[name]!))
            }
            if stage.index == 0 { assigned.append(("model.norm.weight", .ones([64], dtype: .bfloat16))) }
            try model.update(parameters: .unflattened(assigned), verify: [.shapeMismatch])
            var parents = Dictionary(uniqueKeysWithValues: model.namedModules()); parents[""] = model
            for (path, leaf) in model.leafModules().flattened() {
                let expert = path.contains("switch_mlp")
                guard let packed = quantizeSingle(layer: leaf, groupSize: expert ? 32 : 64,
                    bits: expert ? 4 : 8, mode: expert ? .mxfp4 : .affine) else { continue }
                var pieces = path.split(separator: ".").map(String.init); pieces.removeLast()
                while !pieces.isEmpty && parents[pieces.joined(separator: ".")] == nil { pieces.removeLast() }
                let parent = pieces.joined(separator: ".")
                let suffix = parent.isEmpty ? path : String(path.dropFirst(parent.count + 1))
                try parents[parent]!.update(modules: .unflattened([(suffix, packed)]), verify: [.noUnusedKeys])
            }
            model.freeze(); eval(model)
            return model
        }
    }

    private func step(_ stages: [MiMoV26TextModel], caches: [[any KVCache]], tokens: [Int], paged: Bool) throws -> [MLXArray] {
        let input = MLXArray(tokens.map(Int32.init), [1, tokens.count])
        let last = stages[0].configuration.numHiddenLayers - 1
        let producer = paged
            ? try stages[0].forwardIndependentHistory(inputIDs: input,
                caches: #require(caches[0] as? [MiMoV26IndependentHistoryCache]), captureLayers: [last])
            : try stages[0].forward(inputIDs: input, cache: caches[0], captureLayers: [last])
        let residual = try #require(producer.layerFeatures[last]); eval(residual)
        let received = MLXArray(bytes(residual), residual.shape, dtype: residual.dtype)
        let consumer = paged
            ? try stages[1].forwardIndependentHistory(embeddings: received,
                caches: #require(caches[1] as? [MiMoV26IndependentHistoryCache]))
            : try stages[1].forward(embeddings: received, cache: caches[1])
        let rows = [residual, consumer.normalizedHiddenStates, consumer.logits]
        eval(rows + caches.flatMap { $0.flatMap { $0.innerState() } })
        return rows
    }
    private func bytes(_ a: MLXArray) -> Data { eval(a); return a.asData(access: .copy).data }
    private func equal(_ a: [MLXArray], _ b: [MLXArray]) {
        #expect(a.count == b.count)
        for (x, y) in zip(a, b) { #expect(x.shape == y.shape && x.dtype == y.dtype && bytes(x) == bytes(y)) }
    }
    private func equalCaches(_ a: [[any KVCache]], _ b: [[any KVCache]]) {
        for (left, right) in zip(a, b) {
            for (x, y) in zip(left, right) {
                #expect(x.offset == y.offset && x.metaState == y.metaState)
                equal(x.state, y.state)
            }
        }
    }
}
