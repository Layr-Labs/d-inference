import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// A Gemma 4 MoE text model loaded whole, as the single-process
/// tensor-parallel oracle, or as one rank's shard, and generation over it.
///
/// - `full`: the unsharded model (the single-Mac reference on this code path).
/// - `splitSum`: the unsharded model whose row-parallel projections compute
///   both ranks' FP32 partials over their stored columns (zero outside each
///   rank's own channels) and add them in FP32, and whose head normalizes
///   log probabilities over the two vocabulary halves: the decomposition's
///   oracle. Two ranks equal it bit for bit wherever each column-parallel
///   kernel's rows do not depend on the row count (the CPU; on an M5 Ultra
///   GPU a prefill-width full-attention `k_proj` of 1,024 rows rounds some
///   rows differently from its 512-row half). `Gemma4TensorParallelLocalPair`
///   runs both real shards in one process: the bitwise oracle everywhere.
/// - `shard(rank)`: this rank's heads and channels only, built by the SDK's
///   own Gemma 4 modules from the rank's local configuration; every layer
///   sums its attention partial and one packed feed-forward collective
///   through `reduction`, and the head projects this rank's vocabulary rows
///   (`Gemma4TensorParallelSelection` chooses across ranks).
public final class Gemma4TensorParallelModel {
    public enum Role: Equatable, Sendable {
        case full
        case splitSum
        case shard(rank: Int)

        public var label: String {
            switch self {
            case .full: return "full"
            case .splitSum: return "split-sum-tp2"
            case .shard(let rank): return "tp2-rank\(rank)"
            }
        }
    }

    public let role: Role
    public let plan: Gemma4TensorParallelPlan
    public let vocabularyRange: Range<Int>
    public let configurationSHA256: String
    public let loadSeconds: Double
    public let loadedParameterBytes: Int
    /// The residual's and every layer's key/value dtype (the embedding's scales).
    public let activationDType: DType
    let model: Gemma4Model
    let reduction: QwenTensorParallelReduction?

    var textModel: Gemma4TextModel { model.textModel }

    /// Reads a checkpoint directory (`config.json`, `model.safetensors.index.json`
    /// and the files it names) directly: tools and oracles. Vision tensors are
    /// skipped; every other tensor must be a text tensor the plan covers.
    public static func load(modelDirectory: URL, role: Role, reduction: QwenTensorParallelReduction?,
                            packFeedForward: Bool = true) throws -> Gemma4TensorParallelModel {
        let configurationData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        return try assemble(configurationData: configurationData, role: role, reduction: reduction,
                            packFeedForward: packFeedForward) { keep in
            let indexData = try Data(contentsOf: modelDirectory.appendingPathComponent("model.safetensors.index.json"))
            guard let index = (try JSONSerialization.jsonObject(with: indexData) as? [String: Any])?["weight_map"]
                    as? [String: String] else {
                throw ProbeError("Gemma tensor parallel load: the checkpoint index has no weight map")
            }
            var byFile: [String: [String]] = [:]
            for (key, file) in index {
                guard !file.contains("/"), file.hasSuffix(".safetensors") else {
                    throw ProbeError("Gemma tensor parallel load: the checkpoint index names an unexpected file")
                }
                byFile[file, default: []].append(key)
            }
            for file in byFile.keys.sorted() {
                let arrays = try loadArrays(url: modelDirectory.appendingPathComponent(file))
                for key in byFile[file]!.sorted() {
                    guard let value = arrays[key] else { throw ProbeError("Gemma tensor parallel load: \(file) lacks \(key)") }
                    try keep(key, value)
                }
            }
        }
    }

    /// The model of `role` from a configuration and its stored tensors:
    /// `tensors` hands every stored tensor (by checkpoint key) to `keep`,
    /// which cuts this rank's part and materializes it at once.
    static func assemble(configurationData: Data, role: Role, reduction: QwenTensorParallelReduction?,
                         packFeedForward: Bool = true,
                         tensors: (_ keep: (String, MLXArray) throws -> Void) throws -> Void) throws
        -> Gemma4TensorParallelModel {
        let started = DispatchTime.now().uptimeNanoseconds
        guard var root = try JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              let text = root["text_config"] as? [String: Any] else {
            throw ProbeError("Gemma tensor parallel load: expected a gemma4 configuration with a text configuration")
        }
        let plan = try Gemma4TensorParallelPlan(configuration: root)
        // The wrapper takes the vocabulary from its root (262,144 when absent).
        root["vocab_size"] = plan.vocabularySize
        let full = try JSONDecoder().decode(Gemma4Configuration.self,
            from: JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]))
        let rank: Int
        switch role {
        case .full, .splitSum:
            rank = 0
            guard reduction == nil else { throw ProbeError("Gemma tensor parallel load: only a shard takes a reduction") }
        case .shard(let r):
            rank = r
            guard let reduction, reduction.size == plan.size, reduction.rank == r else {
                throw ProbeError("Gemma tensor parallel load: a shard needs the reduction of its own rank and group size")
            }
        }
        var constructed = root
        if case .shard = role { constructed["text_config"] = try plan.shardTextConfiguration(text, rank: rank) }
        let configuration = try JSONDecoder().decode(Gemma4Configuration.self,
            from: JSONSerialization.data(withJSONObject: constructed, options: [.sortedKeys]))
        let model = Gemma4Model(configuration)

        var weights: [String: MLXArray] = [:]
        try tensors { key, value in
            if !key.hasPrefix("language_model.") {
                guard Gemma4TensorParallelPlan.isVisionTensor(key) else {
                    throw ProbeError("Gemma tensor parallel load: unknown checkpoint key \(key)")
                }
                return
            }
            guard weights[key] == nil else { throw ProbeError("Gemma tensor parallel load: \(key) was given twice") }
            guard try plan.expectedShape(key: key) == value.shape else {
                throw ProbeError("Gemma tensor parallel load: \(key) has shape \(value.shape), not the plan's")
            }
            let cut = try plan.cut(key: key, rank: rank)
            let part: MLXArray
            if case .shard = role { part = try Gemma4TensorParallelSlicer.cut(value, cut, key: key, plan: plan) }
            else { part = value }
            // Materialize each part now: the stored tensor it came from is
            // released before the next one is read.
            eval(part)
            weights[key] = part
        }
        quantize(model: model) { path, _ in
            weights[path + ".scales"] != nil ? (plan.groupSize, plan.bits(forModule: path), .affine) : nil
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])

        var extra: [MLXArray] = []
        switch role {
        case .full:
            break
        case .shard(let r):
            try model.textModel.installTensorParallel(shard: Gemma4TensorShard(rank: r), full: full.textConfiguration,
                packFeedForward: packFeedForward) { reduction!.allSum($0) }
        case .splitSum:
            extra = try Gemma4TensorParallelSplitSum.install(in: model, plan: plan)
        }
        let parameters = model.parameters().flattened().map(\.1)
        eval(parameters + extra)
        Memory.clearCache()
        let vocabulary: Range<Int>
        if case .shard(let r) = role { vocabulary = plan.vocabularyRange(rank: r) } else { vocabulary = 0 ..< plan.vocabularySize }
        guard model.textModel.headVocabularyRange == vocabulary else {
            throw ProbeError("Gemma tensor parallel load: the head does not project the plan's vocabulary rows")
        }
        // The embedding's scales are what the residual and every layer's keys and values are computed in.
        guard let activation = weights["language_model.model.embed_tokens.scales"]?.dtype,
              [.bfloat16, .float16, .float32].contains(activation) else {
            throw ProbeError("Gemma tensor parallel load: the embedding has no native activation dtype")
        }
        return Gemma4TensorParallelModel(role: role, plan: plan, vocabularyRange: vocabulary,
            configurationSHA256: sha256(configurationData),
            loadSeconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9,
            loadedParameterBytes: (parameters + extra).reduce(0) { $0 + $1.nbytes },
            activationDType: activation, model: model, reduction: reduction)
    }

    private init(role: Role, plan: Gemma4TensorParallelPlan, vocabularyRange: Range<Int>,
                 configurationSHA256: String, loadSeconds: Double, loadedParameterBytes: Int,
                 activationDType: DType, model: Gemma4Model, reduction: QwenTensorParallelReduction?) {
        self.role = role; self.plan = plan; self.vocabularyRange = vocabularyRange
        self.configurationSHA256 = configurationSHA256; self.loadSeconds = loadSeconds
        self.loadedParameterBytes = loadedParameterBytes; self.activationDType = activationDType
        self.model = model; self.reduction = reduction
    }

    /// The head's selections over this model's vocabulary rows.
    public var selection: Gemma4TensorParallelSelection {
        Gemma4TensorParallelSelection(vocabularyRange: vocabularyRange, vocabularySize: plan.vocabularySize,
                                      reduction: reduction, splitsWholeRow: role == .splitSum)
    }

    func newCache() -> [KVCache] { model.newCache(parameters: nil) }

    /// The model over `input` `[1, T]`: logits `[1, T, V or V/2]` (FP32 after
    /// the softcap), not evaluated.
    func forward(_ input: MLXArray, cache: [KVCache]) -> MLXArray { model(input, cache: cache) }

    /// The prompt through the model in chunks; the last position's logits
    /// `[1, V or V/2]`, not evaluated.
    func prefill(_ prompt: [Int], chunk: Int, cache: [KVCache]) -> MLXArray {
        var logits: MLXArray?
        var offset = 0
        while offset < prompt.count {
            let end = min(prompt.count, offset + chunk)
            let out = forward(MLXArray(prompt[offset ..< end].map { Int32($0) }).reshaped(1, end - offset), cache: cache)
            if end < prompt.count {
                eval(cache.flatMap { $0.innerState() })
            } else {
                logits = out[0..., -1, 0...]
            }
            offset = end
        }
        return logits!
    }

    /// One greedy generation's tokens and per-step evidence.
    public struct Generation: Sendable {
        public var tokenIDs: [Int] = []
        /// Per step, the top `recordTop` token IDs, their logits and log
        /// probabilities over the whole vocabulary, highest first.
        public var topTokenIDs: [[Int]] = []
        public var topLogits: [[Float]] = []
        public var topLogprobs: [[Float]] = []
        /// The last step's whole vocabulary row (FP32), when recorded.
        public var finalLogits: [Float]?
        public var firstTokenSeconds = 0.0
        public var decodeSeconds = 0.0
        public var stepSeconds: [Double] = []
        public var peakActiveBytes = 0
    }

    /// Greedy generation of `outputCount` tokens after `prompt`, prefilled in
    /// chunks of `chunk`. `recordTop` > 0 records each step's top logits and
    /// log probabilities (a shard through the vocabulary-split top-k gather)
    /// and the final step's whole row (a shard through the row gather). Each
    /// step's collectives run in one fixed order on every rank: the forward's,
    /// the selection, the top-k gather, then the final row.
    public func generate(prompt: [Int], outputCount: Int, chunk: Int, recordTop: Int = 0) throws -> Generation {
        guard !prompt.isEmpty, outputCount >= 1, chunk >= 1, prompt.allSatisfy({ (0 ..< plan.vocabularySize).contains($0) }) else {
            throw ProbeError("Gemma tensor parallel generation: empty or out-of-vocabulary request")
        }
        guard (0 ... 64).contains(recordTop) else { throw ProbeError("Gemma tensor parallel generation: at most 64 logits per step") }
        let selection = self.selection
        let cache = newCache()
        var result = Generation()
        let started = Self.now()
        var logits = prefill(prompt, chunk: chunk, cache: cache)
        var last = started
        for step in 0 ..< outputCount {
            let token = selection.greedy(logits)
            eval(token)
            let id = Int(token.item(Int32.self))
            if recordTop > 0 {
                let top = try selection.topK(logits, count: recordTop)
                result.topTokenIDs.append(top.tokenIDs)
                result.topLogits.append(top.logits)
                result.topLogprobs.append(top.logprobs)
                if step == outputCount - 1 {
                    let row = selection.gather(logits)
                    eval(row)
                    result.finalLogits = row.asArray(Float.self)
                }
            }
            let time = Self.now()
            if step == 0 { result.firstTokenSeconds = time - started } else { result.stepSeconds.append(time - last) }
            last = time
            result.tokenIDs.append(id)
            if step + 1 < outputCount {
                logits = forward(token.reshaped(1, 1), cache: cache)[0..., -1, 0...]
            }
        }
        result.decodeSeconds = last - started - result.firstTokenSeconds
        result.peakActiveBytes = Memory.peakMemory
        return result
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

/// Exact copies of a stored tensor's rank part into new row-major buffers
/// (never views, which would keep the whole stored tensor alive), with the
/// plan's zero rows: zero packed words, scales and offsets, so every padded
/// channel's projection is exactly zero.
enum Gemma4TensorParallelSlicer {
    static func cut(_ value: MLXArray, _ cut: Gemma4TensorParallelPlan.Cut, key: String,
                    plan: Gemma4TensorParallelPlan) throws -> MLXArray {
        let local = try plan.localShape(key: key, shape: value.shape, cut: cut)
        let part: MLXArray
        switch cut {
        case .replicate:
            return value
        case .rows(let range, let before, let after):
            part = padded(value[range], axis: 0, before: before, after: after)
        case .inputColumns(let logical):
            let divisor = columnDivisor(key: key, plan: plan)
            part = value[0..., (logical.lowerBound / divisor) ..< (logical.upperBound / divisor)]
        case .expertRows(let range, let before, let after):
            part = padded(value[0..., range], axis: 1, before: before, after: after)
        case .expertInputColumns(let logical):
            let divisor = columnDivisor(key: key, plan: plan)
            part = value[0..., 0..., (logical.lowerBound / divisor) ..< (logical.upperBound / divisor)]
        }
        let copied = contiguous(part)
        guard copied.shape == local else {
            throw ProbeError("Gemma tensor parallel slice: \(key) cut to \(copied.shape), not \(local)")
        }
        return copied
    }

    /// Logical input columns per stored column: values per packed word for a
    /// weight, the group size for scales and offsets.
    static func columnDivisor(key: String, plan: Gemma4TensorParallelPlan) -> Int {
        let parts = key.split(separator: ".")
        return parts.last == "weight" ? 32 / plan.bits(forModule: parts.dropLast().joined(separator: ".")) : plan.groupSize
    }

    private static func padded(_ value: MLXArray, axis: Int, before: Int, after: Int) -> MLXArray {
        guard before > 0 || after > 0 else { return value }
        func zeros(_ count: Int) -> MLXArray {
            var shape = value.shape
            shape[axis] = count
            return MLXArray.zeros(shape, dtype: value.dtype)
        }
        var parts: [MLXArray] = []
        if before > 0 { parts.append(zeros(before)) }
        parts.append(value)
        if after > 0 { parts.append(zeros(after)) }
        return concatenated(parts, axis: axis)
    }
}

extension Gemma4TensorParallelModel {
    /// Writes a tiny random Gemma 4 MoE checkpoint into `directory`
    /// (`config.json`, `model.safetensors` and its index), seeded, with the
    /// 26B's structure scaled down: sliding and full layers (window 16), 16
    /// query heads with 8 sliding and 2 full KV heads (head dims 256 and 512,
    /// K=V on full layers), a dense GeGLU MLP in parallel with 16 routed
    /// experts (top-4), sandwich norms, a tied softcapped head, and affine
    /// group-64 quantization (`bits` by default, 8-bit dense MLP and router)
    /// whose dense (5) and expert (3) group counts are odd, so both overlap
    /// splits run. For model-free equality checks of tensor parallel; never a
    /// model pass.
    ///
    /// `dtype` is the weights' and so the activations' type: BF16 as the
    /// artifacts, or FP32, whose rounding is too small to flip a random
    /// router's near-tied top-k choice (a random router's scores sit closer
    /// together than a trained one's).
    /// `experts`/`topK` change the routed bank (with `topK == experts` every
    /// token takes every expert, and no rounding can change a route).
    public static func writeSyntheticCheckpoint(directory: URL, seed: UInt64 = 7, bits: Int = 4,
                                                dtype: DType = .bfloat16, experts: Int = 16, topK: Int = 4) throws {
        guard [4, 8].contains(bits) else { throw ProbeError("Gemma synthetic checkpoint: bits are 4 or 8") }
        guard (1 ... 64).contains(experts), (1 ... experts).contains(topK) else {
            throw ProbeError("Gemma synthetic checkpoint: 1 to 64 experts, top-k at most the experts")
        }
        guard [.bfloat16, .float32].contains(dtype) else {
            throw ProbeError("Gemma synthetic checkpoint: weights are bfloat16 or float32")
        }
        let layers = 6
        let kinds = (0 ..< layers).map { ($0 + 1) % 3 == 0 ? "full_attention" : "sliding_attention" }
        let text: [String: Any] = [
            "model_type": "gemma4_text", "hidden_size": 256, "num_hidden_layers": layers, "layer_types": kinds,
            "intermediate_size": 320, "moe_intermediate_size": 192, "num_experts": experts, "top_k_experts": topK,
            "num_attention_heads": 16, "num_key_value_heads": 8, "num_global_key_value_heads": 2,
            "head_dim": 256, "global_head_dim": 512, "sliding_window": 16, "vocab_size": 512,
            "vocab_size_per_layer_input": 0, "hidden_size_per_layer_input": 0, "num_kv_shared_layers": 0,
            "attention_k_eq_v": true, "enable_moe_block": true, "tie_word_embeddings": true,
            "use_double_wide_mlp": false, "attention_bias": false, "final_logit_softcapping": 30.0,
            "rms_norm_eps": 1e-6, "max_position_embeddings": 4096, "hidden_activation": "gelu_pytorch_tanh",
            "use_bidirectional_attention": "vision", "dtype": dtype == .float32 ? "float32" : "bfloat16",
            "rope_parameters": [
                "sliding_attention": ["rope_type": "default", "rope_theta": 10000.0],
                "full_attention": ["rope_type": "proportional", "rope_theta": 1_000_000.0, "partial_rotary_factor": 0.25],
            ],
        ]
        var quantization: [String: Any] = ["group_size": 64, "bits": bits, "mode": "affine"]
        for layer in 0 ..< layers {
            for module in ["mlp.gate_proj", "mlp.up_proj", "mlp.down_proj", "router.proj"] {
                quantization["language_model.model.layers.\(layer).\(module)"] = ["group_size": 64, "bits": 8]
            }
        }
        let root: [String: Any] = ["model_type": "gemma4", "text_config": text, "tie_word_embeddings": true,
                                   "vocab_size": 512, "quantization": quantization, "quantization_config": quantization]
        let configurationData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted])
        let plan = try Gemma4TensorParallelPlan(configuration: root)
        let configuration = try JSONDecoder().decode(Gemma4Configuration.self, from: configurationData)
        let arrays: [String: MLXArray] = withRandomState(MLXRandom.RandomState(seed: seed)) {
            let model = Gemma4Model(configuration)
            var values: [(String, MLXArray)] = []
            for (key, value) in model.parameters().flattened() {
                let shape = value.shape
                let generated: MLXArray
                if key.hasSuffix("embed_tokens.weight") {
                    generated = MLXRandom.normal(shape) * 0.1
                } else if key.hasSuffix("layer_scalar") {
                    generated = MLXRandom.uniform(low: 0.5, high: 1.0, shape)
                } else if key.hasSuffix("per_expert_scale") {
                    generated = MLXRandom.uniform(low: 0.5, high: 1.5, shape)
                } else if key.hasSuffix("q_norm.weight") || key.hasSuffix("k_norm.weight") {
                    // Gemma 4 attends at scale 1: small per-head norms keep
                    // scores near unit spread, as a trained model's do, so
                    // softmax is not an argmax that rounding can flip.
                    generated = MLXRandom.uniform(low: 0.2, high: 0.3, shape)
                } else if key.hasSuffix("norm.weight") || key.hasSuffix("router.scale") {
                    generated = MLXRandom.uniform(low: 0.6, high: 1.4, shape)
                } else {
                    let fanIn = Float(shape.last ?? 1)
                    generated = MLXRandom.normal(shape) * (1 / fanIn.squareRoot())
                }
                values.append((key, generated.asType(dtype)))
            }
            model.update(parameters: ModuleParameters.unflattened(values))
            quantize(model: model) { path, module in
                guard module is Linear || module is SwitchLinear || module is Embedding else { return nil }
                return (64, plan.bits(forModule: path), .affine)
            }
            let flat = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
            eval(Array(flat.values))
            return flat
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try configurationData.write(to: directory.appendingPathComponent("config.json"))
        try save(arrays: arrays, url: directory.appendingPathComponent("model.safetensors"))
        let index: [String: Any] = ["metadata": [:] as [String: Any],
                                    "weight_map": Dictionary(uniqueKeysWithValues: arrays.keys.map { ($0, "model.safetensors") })]
        try JSONSerialization.data(withJSONObject: index, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("model.safetensors.index.json"))
    }
}
