import Foundation
import MLX
import MLXNN
import MLXLLM
import MLXLMCommon

struct GemmaBatchFailure: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

struct GemmaBatchCase: Codable {
    let bits: Int
    let rows: Int
    let dtype: String
    let entry: String
    let steps: Int
    let comparisons: Int
    let mismatches: [String]
}

private func bytes(_ array: MLXArray) -> Data {
    eval(array)
    return array.asData(access: .copy).data
}

private final class GemmaRowState {
    let kv: [CBv2SequenceKV?]
    init(model: Gemma4TextModel, backend: CBv2ContiguousKVBackend, prompt: Int) throws {
        kv = try backend.makeSequenceState(layerKinds: model.cbv2LayerKinds,
            promptLength: prompt, maxLength: 64)
    }
}

func runGemmaBatchCase(bits: Int, rows: Int, dtype: DType, embeddings: Bool,
                       exact: Bool, check: () throws -> Void) throws -> GemmaBatchCase {
    // Reduced dimensions, actual Gemma decoder/router/SwitchGLU and CBv2
    // contiguous cache implementations. K=V, two RoPE widths, one ring and
    // one full-attention layer match the registered 26B topology.
    let configuration: [String: Any] = [
        "model_type": "gemma4_text", "hidden_size": 256, "num_hidden_layers": 2,
        "intermediate_size": 256, "num_attention_heads": 4, "head_dim": 64,
        "global_head_dim": 128, "num_key_value_heads": 2, "num_global_key_value_heads": 1,
        "num_kv_shared_layers": 0, "hidden_size_per_layer_input": 0,
        "vocab_size": 256, "tie_word_embeddings": true, "attention_k_eq_v": true,
        "enable_moe_block": true, "num_experts": 16, "top_k_experts": 8,
        "moe_intermediate_size": 128, "sliding_window": 8,
        "layer_types": ["sliding_attention", "full_attention"],
        "use_double_wide_mlp": false, "final_logit_softcapping": 30.0,
        "quantization": ["bits": bits, "group_size": 64, "mode": "affine"],
        "rope_parameters": [
            "full_attention": ["partial_rotary_factor": 0.25, "rope_theta": 1_000_000.0,
                               "rope_type": "proportional"],
            "sliding_attention": ["rope_theta": 10_000.0, "rope_type": "default"]],
    ]
    let config = try JSONDecoder().decode(Gemma4TextConfiguration.self,
        from: JSONSerialization.data(withJSONObject: configuration))
    MLXRandom.seed(9173)
    let model = Gemma4TextModel(config)
    model.update(parameters: ModuleParameters.unflattened(model.parameters().flattened().map {
        ($0.0, $0.1.asType(dtype))
    }))
    // Match the artifact's mixed default4/shared MLP+router8 or all8.
    quantize(model: model, filter: { path, _ -> (Int, Int, QuantizationMode)? in
        (64, path.contains(".mlp.") || path.hasSuffix(".router.proj") ? 8 : bits, .affine)
    })
    eval(model); try check()
    let backend = CBv2ContiguousKVBackend(config: .init(bytesCapacity: 256 << 20, kvDType: dtype))
    let reference = try (0..<rows).map { try GemmaRowState(model: model, backend: backend, prompt: $0 + 2) }
    let candidate = try (0..<rows).map { try GemmaRowState(model: model, backend: backend, prompt: $0 + 2) }
    let caches = try model.newCacheV2 { CBv2LayerCache(layerIndex: $0, kind: $1) }
    defer {
        for cache in caches { cache.setRows([]) }
        for state in reference + candidate { backend.release(state.kv) }
    }
    func forward(_ states: [GemmaRowState], tokens: [Int32], candidateScope: Bool) throws -> MLXArray {
        for index in caches.indices { caches[index].setRows(states.map { $0.kv[index]! }) }
        let input = MLXArray(tokens, [states.count, 1])
        func compute() -> MLXArray {
            if embeddings {
                return model.embeddingForward(input, inputEmbedding: model.scaledInputEmbeddings(input),
                    cache: caches.map { $0 as! any KVCache })
            }
            return model(input, cache: caches.map { $0 as! any KVCache })
        }
        let output: MLXArray
        #if GEMMA_ROW_BASELINE
        output = compute()
        #else
        output = Gemma4BatchDecodeScope.withDecodeFrame(tokens: input, enabled: candidateScope) { compute() }
        #endif
        eval([output] + caches.flatMap { ($0 as! any KVCache).innerState() }); try check()
        guard output.asType(.float32).asArray(Float.self).allSatisfy(\.isFinite) else {
            throw GemmaBatchFailure("Nonfinite logits")
        }
        return output
    }
    // Distinct histories and lengths; singleton prefill on both sides. Some
    // lanes cross the ring boundary before decode, others cross while batched.
    for row in 0..<rows {
        for step in 0..<row + 2 {
            let token = Int32((row * 19 + step * 7 + 3) % 256)
            let before = try forward([reference[row]], tokens: [token], candidateScope: false)
            let after = try forward([candidate[row]], tokens: [token], candidateScope: false)
            guard bytes(before) == bytes(after) else { throw GemmaBatchFailure("Prefill oracle differs") }
        }
    }
    var comparisons = 0
    var mismatches: [String] = []
    func compare(_ before: MLXArray, _ after: MLXArray, _ name: String) {
        comparisons += 1
        if !before.asType(.float32).asArray(Float.self).allSatisfy(\.isFinite)
            || !after.asType(.float32).asArray(Float.self).allSatisfy(\.isFinite) {
            mismatches.append("\(name) nonfinite")
        }
        if before.shape != after.shape || before.dtype != after.dtype || bytes(before) != bytes(after) {
            let a = [UInt8](bytes(before)), b = [UInt8](bytes(after))
            let differences = a.indices.filter { a[$0] != b[$0] }
            let first = differences.prefix(6).map { "\($0):\(a[$0])->\(b[$0])" }.joined(separator: ",")
            mismatches.append("\(name) shape=\(before.shape) bytes=\(differences.count) first=\(first)")
        }
    }
    let steps = 10
    for step in 0..<steps {
        let tokens = (0..<rows).map { Int32(($0 * 29 + step * 11 + 5) % 256) }
        // A lane leaves for two steps and rejoins without advancing. Ordering
        // changes on every frame, so slot ordinal cannot identify a request.
        let members = (0..<rows).filter { !(step == 3 || step == 4) || $0 != rows - 1 }
        let order = members.indices.map { members[(step + (step % 2 == 0 ? $0 : members.count - 1 - $0)) % members.count] }
        var expected: [Int: MLXArray] = [:]
        for row in members { expected[row] = try forward([reference[row]], tokens: [tokens[row]], candidateScope: false) }
        let actual = try forward(order.map { candidate[$0] }, tokens: order.map { tokens[$0] }, candidateScope: exact)
        for (slot, row) in order.enumerated() {
            compare(expected[row]!, actual[slot..<slot + 1], "step=\(step) row=\(row) logits")
        }
        // Includes inactive lanes: no batched call may mutate their state.
        for row in 0..<rows {
            for index in reference[row].kv.indices {
                let a = reference[row].kv[index]!.snapshot(), b = candidate[row].kv[index]!.snapshot()
                guard a.offset == b.offset else { throw GemmaBatchFailure("KV frontier differs") }
                compare(a.keys, b.keys, "step=\(step) row=\(row) layer=\(index) keys")
                compare(a.values, b.values, "step=\(step) row=\(row) layer=\(index) values")
            }
        }
        try check()
    }
    return .init(bits: bits, rows: rows, dtype: String(describing: dtype),
        entry: embeddings ? "embeddingForward" : "tokenForward", steps: steps,
        comparisons: comparisons, mismatches: mismatches)
}
