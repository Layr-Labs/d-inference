import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// A dense Qwen 3.5-family text model loaded whole, as the single-process
/// tensor-parallel oracle, or as one rank's tensor-parallel shard, and greedy
/// generation over it.
///
/// - `full`: the unsharded model (the single-Mac reference on this code path).
/// - `simulated(size)`: the unsharded model whose row-parallel projections
///   compute the ranks' float32 partial sums and add them in float32 — the
///   staged reference a tensor-parallel run must equal bit for bit on one chip.
/// - `shard(rank, size)`: this rank's heads and channels only; row-parallel
///   projections all-sum their float32 partials through `reduction`; the LM
///   head holds this rank's vocabulary rows and the next token is chosen by a
///   distributed argmax (one four-value all-sum), so both ranks select the
///   same token without a separate exchange and no rank holds the full logits.
///
/// The SDK's own Qwen 3.5 modules run every layer; only shapes (from a divided
/// configuration), weights (exact copies of checkpoint blocks) and the three
/// row-parallel projections per layer differ. No multi-token prediction head.
public final class QwenTensorParallelModel {
    public enum Role: Equatable, Sendable {
        case full
        case simulated(size: Int)
        case shard(rank: Int, size: Int)

        public var label: String {
            switch self {
            case .full: return "full"
            case .simulated(let size): return "simulated-tp\(size)"
            case .shard(let rank, let size): return "tp\(size)-rank\(rank)"
            }
        }
    }

    public let role: Role
    public let plan: QwenTensorParallelPlan
    public let vocabularyRange: Range<Int>
    public let configurationSHA256: String
    public let loadSeconds: Double
    public let loadedActiveBytes: Int
    public let loadedParameterBytes: Int
    private let model: Qwen35Model
    private let reduction: QwenTensorParallelReduction?

    /// `reduction` is required for `shard` and refused otherwise.
    public static func load(modelDirectory: URL, role: Role, reduction: QwenTensorParallelReduction?,
                            timing: QwenTensorParallelReductionTiming = .lazy,
                            partialDType: DType = .float32) throws -> QwenTensorParallelModel {
        guard [.float32, .bfloat16].contains(partialDType) else {
            throw ProbeError("Tensor parallel load: partial sums are float32 or bfloat16")
        }
        let started = DispatchTime.now().uptimeNanoseconds
        let configurationData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        guard let root = try JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              root["model_type"] as? String == "qwen3_5",
              let text = root["text_config"] as? [String: Any],
              let quantization = (root["quantization"] ?? root["quantization_config"]) as? [String: Any] else {
            throw ProbeError("Tensor parallel load: expected a quantized qwen3_5 checkpoint with a text configuration")
        }
        let size: Int, rank: Int
        switch role {
        case .full: size = 2; rank = 0
        case .simulated(let s): size = s; rank = 0
        case .shard(let r, let s): size = s; rank = r
        }
        let plan = try QwenTensorParallelPlan(textConfiguration: text, quantization: quantization, size: size)
        if case .shard = role {
            guard let reduction, reduction.size == size, reduction.rank == rank else {
                throw ProbeError("Tensor parallel load: a shard needs the reduction of its own rank and group size")
            }
        } else if reduction != nil {
            throw ProbeError("Tensor parallel load: only a shard takes a reduction")
        }

        let constructed: [String: Any]
        if case .shard = role { constructed = plan.shardTextConfiguration(text) } else { constructed = plan.unshardedTextConfiguration(text) }
        let wrapper: [String: Any] = ["model_type": "qwen3_5", "text_config": constructed]
        let configuration = try JSONDecoder().decode(Qwen35Configuration.self,
            from: JSONSerialization.data(withJSONObject: wrapper, options: [.sortedKeys]))
        let model = Qwen35Model(configuration)

        // Checkpoint tensors named by the index; the multi-token prediction
        // file and the vision tower are not part of the text model.
        let indexData = try Data(contentsOf: modelDirectory.appendingPathComponent("model.safetensors.index.json"))
        guard let index = (try JSONSerialization.jsonObject(with: indexData) as? [String: Any])?["weight_map"] as? [String: String] else {
            throw ProbeError("Tensor parallel load: the checkpoint index has no weight map")
        }
        var byFile: [String: [String]] = [:]
        for (key, file) in index {
            guard !file.contains("/"), file.hasSuffix(".safetensors") else {
                throw ProbeError("Tensor parallel load: the checkpoint index names an unexpected file")
            }
            byFile[file, default: []].append(key)
        }
        var weights: [String: MLXArray] = [:]
        for file in byFile.keys.sorted() {
            let arrays = try loadArrays(url: modelDirectory.appendingPathComponent(file))
            for key in byFile[file]!.sorted() {
                guard let value = arrays[key] else { throw ProbeError("Tensor parallel load: \(file) lacks \(key)") }
                let disposition: QwenTensorParallelPlan.Disposition
                if case .shard = role { disposition = try plan.disposition(key: key, rank: rank) }
                else { disposition = try plan.disposition(key: key, rank: 0) == .skip ? .skip : .load(.replicate) }
                guard case .load(let cut) = disposition else { continue }
                let leaf = String(key.split(separator: ".").last!)
                let sliced = try QwenTensorParallelSlicer.cut(value, cut, leaf: leaf,
                    groupSize: plan.groupSize, bits: plan.bits)
                // Materialize each cut now: the checkpoint tensor it came from is
                // released before the next one is read.
                eval(sliced)
                weights[key] = sliced
            }
        }

        quantize(model: model) { path, _ in
            weights[path + ".scales"] != nil ? (plan.groupSize, plan.bits, .affine) : nil
        }
        if case .shard = role {
            // The constructed head has the whole vocabulary; this rank's has its rows.
            guard let w = weights["language_model.lm_head.weight"], let s = weights["language_model.lm_head.scales"] else {
                throw ProbeError("Tensor parallel load: the checkpoint has no quantized LM head")
            }
            let head = QuantizedLinear(weight: w, bias: nil, scales: s, biases: weights["language_model.lm_head.biases"],
                groupSize: plan.groupSize, bits: plan.bits, mode: .affine)
            try model.update(modules: ModuleChildren.unflattened([("language_model.lm_head", head)]), verify: .none)
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])

        // Row-parallel projections.
        let leaves = Dictionary(uniqueKeysWithValues: model.leafModules().flattened())
        var replacements: [(String, Module)] = []
        var extra: [MLXArray] = []
        for path in plan.rowParallelModulePaths() {
            guard let source = leaves[path] as? QuantizedLinear else {
                throw ProbeError("Tensor parallel load: \(path) is not a quantized projection")
            }
            switch role {
            case .full:
                break
            case .simulated(let s):
                let oracle = try QwenTensorParallelSplitSumLinear(source, size: s)
                extra += oracle.partArrays
                replacements.append((path, oracle))
            case .shard:
                replacements.append((path, QwenTensorParallelRowLinear(source, reduction: reduction!, timing: timing,
                                                                       partialDType: partialDType)))
            }
        }
        if !replacements.isEmpty {
            try model.update(modules: ModuleChildren.unflattened(replacements), verify: .none)
        }
        let parameters = model.parameters().flattened().map(\.1)
        eval(parameters + extra)
        Memory.clearCache()

        let vocabulary: Range<Int>
        if case .shard(let r, _) = role { vocabulary = plan.vocabularyRange(rank: r) } else { vocabulary = 0 ..< plan.vocabularySize }
        return QwenTensorParallelModel(role: role, plan: plan, vocabularyRange: vocabulary,
            configurationSHA256: sha256(configurationData),
            loadSeconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9,
            loadedActiveBytes: Memory.activeMemory,
            loadedParameterBytes: (parameters + extra).reduce(0) { $0 + $1.nbytes },
            model: model, reduction: reduction)
    }

    private init(role: Role, plan: QwenTensorParallelPlan, vocabularyRange: Range<Int>, configurationSHA256: String,
                 loadSeconds: Double, loadedActiveBytes: Int, loadedParameterBytes: Int, model: Qwen35Model,
                 reduction: QwenTensorParallelReduction?) {
        self.role = role; self.plan = plan; self.vocabularyRange = vocabularyRange
        self.configurationSHA256 = configurationSHA256; self.loadSeconds = loadSeconds
        self.loadedActiveBytes = loadedActiveBytes; self.loadedParameterBytes = loadedParameterBytes
        self.model = model; self.reduction = reduction
    }

    /// One greedy generation's tokens and timings.
    public struct Generation: Sendable {
        public var tokenIDs: [Int] = []
        /// Per step, the top `recordTop` token IDs and their logits (float32 of the
        /// model's logits), highest first; empty unless recorded.
        public var topTokenIDs: [[Int]] = []
        public var topLogits: [[Float]] = []
        /// From the first prompt chunk to the first token being available.
        public var firstTokenSeconds = 0.0
        /// From the first token to the last.
        public var decodeSeconds = 0.0
        /// Wall time between successive tokens.
        public var stepSeconds: [Double] = []
        public var peakActiveBytes = 0
        /// Hybrid only: prefill on one rank, its state cut by heads and moved.
        public var prefillSeconds: Double?
        public var handoffSeconds: Double?
        public var handoffBytes: Int?
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    /// The next token from this rank's logits `[1, V or V/size]`: an `[1]` int32
    /// array, not evaluated. A shard's choice is the argmax over every rank's
    /// vocabulary rows; ties go to the lowest token ID, as a full argmax does.
    func select(_ logits: MLXArray) -> MLXArray {
        let values = logits.asType(.float32)
        guard case .shard(let rank, let size) = role, let reduction else {
            return argMax(values, axis: -1).asType(.int32)
        }
        let localIndex = argMax(values, axis: -1).asType(.float32) + MLXArray(Float(vocabularyRange.lowerBound))
        let localMax = values.max(axis: -1)
        let mine = concatenated([localMax, localIndex], axis: 0)
        let zeros = MLXArray.zeros([2], dtype: .float32)
        let slots = concatenated((0..<size).map { $0 == rank ? mine : zeros }, axis: 0)
        let all = reduction.allSum(slots)
        var best = all[0], token = all[1]
        for other in 1..<size {
            let better = all[2 * other] .> best
            best = which(better, all[2 * other], best)
            token = which(better, all[2 * other + 1], token)
        }
        return token.asType(.int32).reshaped(1)
    }

    private func top(_ logits: MLXArray, _ count: Int) -> (MLXArray, MLXArray) {
        let values = logits.asType(.float32)
        let indices = argPartition(-values, kth: count - 1, axis: -1)[0..., 0 ..< count]
        return (indices, takeAlong(values, indices, axis: -1))
    }

    /// Greedy generation of `outputCount` tokens after `prompt`, prefilled in
    /// chunks of `chunk` tokens. The next step's graph is built and submitted
    /// before the current token is read. `recordTop` > 0 records each step's top
    /// logits (full and simulated roles only).
    public func generate(prompt: [Int], outputCount: Int, chunk: Int, recordTop: Int = 0) throws -> Generation {
        guard !prompt.isEmpty, outputCount >= 1, chunk >= 1 else { throw ProbeError("Tensor parallel generation: empty request") }
        if recordTop > 0, case .shard = role { throw ProbeError("Tensor parallel generation: a shard does not record logits") }
        guard recordTop <= 64 else { throw ProbeError("Tensor parallel generation: at most 64 logits per step") }
        let cache = model.newCache(parameters: nil)
        let started = Self.now()
        let logits = prefill(prompt, chunk: chunk, cache: cache)
        return decode(first: select(logits), firstLogits: logits, cache: cache, outputCount: outputCount,
                      recordTop: recordTop, started: started)
    }

    /// The prompt through the model in chunks; the last position's logits, not evaluated.
    func prefill(_ prompt: [Int], chunk: Int, cache: [KVCache]) -> MLXArray {
        var logits: MLXArray?
        var offset = 0
        while offset < prompt.count {
            let end = min(prompt.count, offset + chunk)
            let input = MLXArray(prompt[offset ..< end].map { Int32($0) }).reshaped(1, end - offset)
            let out = model(input, cache: cache)
            if end < prompt.count {
                eval(cache.flatMap { $0.innerState() })
            } else {
                logits = out[0..., -1, 0...]
            }
            offset = end
        }
        return logits!
    }

    func newCache() -> [KVCache] { model.newCache(parameters: nil) }

    /// Greedy decode from `first` (an `[1]` int32 token, possibly not evaluated
    /// yet) with `cache` holding the prompt. `firstLogits` are the logits `first`
    /// was chosen from (recorded when `recordTop` > 0).
    func decode(first: MLXArray, firstLogits: MLXArray?, cache: [KVCache], outputCount: Int, recordTop: Int,
                started: Double) -> Generation {
        var result = Generation()
        var current = first
        var currentTop = recordTop > 0 ? firstLogits.map { top($0, recordTop) } : nil
        if let currentTop { asyncEval(current, currentTop.0, currentTop.1) } else { asyncEval(current) }
        var last = started
        for step in 0 ..< outputCount {
            var next: MLXArray?
            var nextTop: (MLXArray, MLXArray)?
            if step + 1 < outputCount {
                let stepLogits = model(current.reshaped(1, 1), cache: cache)[0..., -1, 0...]
                next = select(stepLogits)
                nextTop = recordTop > 0 ? top(stepLogits, recordTop) : nil
                if let nextTop { asyncEval(next!, nextTop.0, nextTop.1) } else { asyncEval(next!) }
            }
            let token = Int(current.item(Int32.self))
            let time = Self.now()
            if step == 0 { result.firstTokenSeconds = time - started } else { result.stepSeconds.append(time - last) }
            last = time
            result.tokenIDs.append(token)
            if let currentTop {
                let ids = currentTop.0.asArray(UInt32.self).map { Int($0) }
                let values = currentTop.1.asArray(Float.self)
                let order = ids.indices.sorted { values[$0] != values[$1] ? values[$0] > values[$1] : ids[$0] < ids[$1] }
                result.topTokenIDs.append(order.map { ids[$0] })
                result.topLogits.append(order.map { values[$0] })
            }
            if let next { current = next }
            currentTop = nextTop
        }
        result.decodeSeconds = last - started - result.firstTokenSeconds
        result.peakActiveBytes = Memory.peakMemory
        return result
    }
}
