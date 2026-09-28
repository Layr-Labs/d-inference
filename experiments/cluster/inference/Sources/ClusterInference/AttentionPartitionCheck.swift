import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// Observe the actual internal Qwen35Attention through its public Linear child.
/// No attention implementation is copied into this test.
private final class AttentionOutputCapture: QuantizedLinear {
    var recorded: MLXArray?

    init(_ source: QuantizedLinear) {
        super.init(weight: source.weight, scales: source.scales, biases: source.biases,
                   groupSize: source.groupSize, bits: source.bits, mode: source.mode)
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        let output = super.callAsFunction(input)
        recorded = output
        return output
    }
}

private struct CapturedAttentionModel {
    let model: Qwen35TextModel
    let output: AttentionOutputCapture
    let cache: [KVCache]

    init(_ model: Qwen35TextModel) throws {
        guard let attention = model.namedModules().first(where: { $0.0.hasSuffix(".self_attn") })?.1,
            let projection = attention.namedModules().first(where: { $0.0 == "o_proj" })?.1 as? QuantizedLinear
        else { throw ProbeError("Missing synthetic Qwen attention output projection") }
        let capture = AttentionOutputCapture(projection)
        try attention.update(modules: ModuleChildren(values: ["o_proj": .value(capture)]), verify: [.noUnusedKeys])
        self.model = model; output = capture; cache = model.newCache(parameters: nil)
    }

    func forward(_ tokens: [Int]) throws -> MLXArray {
        output.recorded = nil
        let logits = model(MLXArray(tokens).reshaped(1, tokens.count), cache: cache)
        eval(logits)
        guard let recorded = output.recorded else { throw ProbeError("Attention capture did not execute") }
        eval(recorded)
        return recorded
    }
}

struct AttentionPartitionCheckResult: Encodable {
    let kind = "attention_partition_parity"
    let activationDType: String
    let queryHeads: Int
    let kvHeads: Int
    let headDim: Int
    let chunks: [Int]
    let comparedOutputValues: Int
    let maximumAbsoluteError: Double
    let relativeRMSError: Double
    let maximumKVError: Double
    let absoluteTolerance: Double
    let relativeRMSTolerance: Double
    let actualQwenAttention = true
    let kvShapesAndOffsetsEqual = true
    let correctnessOnly = true
}

/// Single-layer models let all three instances receive identical first-attention
/// inputs. Only captured attention contributions and KV states are compared;
/// the models' later logits are not equivalent without the output reduction.
func checkAttentionPartition() throws {
    for (heads, kv, dimension, bf16) in [(4, 2, 0, false), (8, 2, 256, false),
                                       (8, 2, 256, true), (12, 2, 256, true)] {
        try emitJSON(checkAttentionPartition(heads: heads, kv: kv, dimension: dimension, bf16: bf16))
    }
}

private func checkAttentionPartition(heads: Int, kv: Int, dimension: Int, bf16: Bool) throws
    -> AttentionPartitionCheckResult
{
    _qwen35MTPEnabled = false
    MLXRandom.seed(317)
    var text: [String: Any] = [
        "model_type": "qwen3_5_text", "hidden_size": 256, "num_hidden_layers": 1,
        "intermediate_size": 256, "num_attention_heads": heads, "num_key_value_heads": kv,
        "full_attention_interval": 1, "vocab_size": 512, "tie_word_embeddings": false,
        "attention_bias": false, "partial_rotary_factor": 0.5, "rope_theta": 10000.0,
        "max_position_embeddings": 2048, "mtp_num_hidden_layers": 0,
    ]
    if dimension > 0 { text["head_dim"] = dimension }
    let plan = try QwenAttentionPartition(text: text)
    func construct(_ configuration: [String: Any]) throws -> Qwen35TextModel {
        let data = try JSONSerialization.data(withJSONObject: configuration, options: [.sortedKeys])
        let model = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self, from: data))
        quantize(model: model, groupSize: 64, bits: 4)
        return model
    }
    let original = try construct(text)
    var weights = Dictionary(uniqueKeysWithValues: original.parameters().flattened())
    // Nonuniform norms exercise replication of complete per-head normalization.
    for name in ["q_norm", "k_norm"] {
        weights["model.layers.0.self_attn.\(name).weight"] = MLXRandom.uniform(low: 0.7, high: 1.3, [plan.headDim])
    }
    if bf16 { weights = weights.mapValues { $0.dtype == .float32 ? $0.asType(.bfloat16) : $0 } }
    try original.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
    original.freeze(); eval(original)
    let baseline = try CapturedAttentionModel(original)
    var localText = text
    for (key, value) in plan.configurationUpdates { localText[key] = value }
    var shards: [CapturedAttentionModel] = []
    for rank in 0..<2 {
        let model = try construct(localText)
        var selected: [String: MLXArray] = [:]
        for (name, value) in weights {
            let prefix = "model.layers.0.self_attn."
            let selection = try name.hasPrefix(prefix)
                ? plan.selection(relativeName: String(name.dropFirst(prefix.count)), shape: value.shape, rank: rank)
                : TensorSelection.all
            selected[name] = try copySelectedTensor(value, selection: selection)
        }
        try model.update(parameters: ModuleParameters.unflattened(selected), verify: [.all])
        model.freeze(); eval(model)
        shards.append(try CapturedAttentionModel(model))
    }
    let chunks = [17, 32, 1, 1]
    var count = 0, compared = 0
    var maximum = 0.0, squares = 0.0, referenceSquares = 0.0, kvMaximum = 0.0
    for length in chunks {
        let tokens = (count..<(count + length)).map { 3 + (($0 * 17 + 9) % 509) }
        let reference = try baseline.forward(tokens)
        let pieces = try shards.map { try $0.forward(tokens) }
        let expectedDType: DType = bf16 ? .bfloat16 : .float32
        guard reference.dtype == expectedDType, pieces.allSatisfy({ $0.dtype == expectedDType }) else {
            throw ProbeError("Attention fixture did not execute at the requested activation dtype")
        }
        let candidate = pieces[0] + pieces[1]
        eval(candidate)
        let a = reference.asType(.float32).asArray(Float.self)
        let b = candidate.asType(.float32).asArray(Float.self)
        guard reference.shape == candidate.shape, a.count == b.count else { throw ProbeError("Attention output shape mismatch") }
        for (x, y) in zip(a, b) {
            guard x.isFinite, y.isFinite else { throw ProbeError("Nonfinite attention output") }
            let delta = Double(x) - Double(y)
            maximum = max(maximum, abs(delta)); squares += delta * delta
            referenceSquares += Double(x) * Double(x); compared += 1
        }
        count += length
        guard ([baseline] + shards).allSatisfy({ $0.cache.count == 1 && $0.cache[0].offset == count }),
            baseline.cache[0].state.count == 2, shards.allSatisfy({ $0.cache[0].state.count == 2 })
        else { throw ProbeError("Attention partition cache offsets disagree") }
        for index in 0..<2 {
            let referenceState = baseline.cache[0].state[index]
            let states = shards.map { $0.cache[0].state[index] }
            guard referenceState.shape == [1, kv, count, plan.headDim],
                referenceState.dtype == expectedDType,
                states.allSatisfy({ $0.shape == [1, kv / 2, count, plan.headDim] && $0.dtype == expectedDType })
            else { throw ProbeError("Attention partition cache geometry mismatch") }
            let combined = concatenated(states, axis: 1)
            let delta = abs(referenceState.asType(.float32) - combined.asType(.float32)).max().item(Float.self)
            guard delta.isFinite else { throw ProbeError("Nonfinite attention cache") }
            kvMaximum = max(kvMaximum, Double(delta))
        }
    }
    let rms = sqrt(squares / max(referenceSquares, 1e-30))
    let absolute = bf16 ? 0.008 : 0.00005
    let relative = bf16 ? 0.02 : 0.00002
    guard maximum <= absolute, rms <= relative, kvMaximum <= absolute else {
        throw ProbeError("Attention partition parity failed: max=\(maximum), RMS=\(rms), KV=\(kvMaximum)")
    }
    return AttentionPartitionCheckResult(activationDType: bf16 ? "bfloat16" : "float32",
        queryHeads: heads, kvHeads: kv, headDim: plan.headDim, chunks: chunks,
        comparedOutputValues: compared, maximumAbsoluteError: maximum, relativeRMSError: rms,
        maximumKVError: kvMaximum, absoluteTolerance: absolute, relativeRMSTolerance: relative)
}
