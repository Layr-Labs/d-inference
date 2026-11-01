import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// A MiMo V2.6 text model loaded whole, or as one rank's shard of
/// `MiMoTensorParallelPlan`, and greedy generation over it.
///
/// - `full`: the unsharded model (the single-Mac reference on this code path).
/// - `shard(rank)`: this rank's heads and channels only, built by the SDK's
///   own MiMo modules from the rank's local configuration; every layer sums
///   its `o_proj` and feed-forward partials through `reduction`, and the head
///   projects this rank's vocabulary rows. `Gemma4TensorParallelSelection`
///   chooses across the ranks' rows (the vocabulary split is model-neutral).
///   Both ranks in one process (`Gemma4TensorParallelLocalPair`) are the
///   bitwise oracle of a two-process run.
public final class MiMoTensorParallelModel {
    public enum Role: Equatable, Sendable {
        case full
        case shard(rank: Int)

        public var label: String {
            switch self {
            case .full: return "full"
            case .shard(let rank): return "tp2-rank\(rank)"
            }
        }
    }

    public let role: Role
    public let plan: MiMoTensorParallelPlan
    public let vocabularyRange: Range<Int>
    public let loadSeconds: Double
    public let loadedParameterBytes: Int
    let model: MiMoV26TextModel
    let reduction: QwenTensorParallelReduction?

    /// Reads a checkpoint directory (`config.json`, `model.safetensors.index.json`
    /// and the files it names) directly: tools and oracles. Excluded
    /// components (MTP, vision, audio, speech) are skipped by name; every other
    /// tensor must be a text tensor of the plan.
    public static func load(modelDirectory: URL, role: Role, reduction: QwenTensorParallelReduction?) throws
        -> MiMoTensorParallelModel {
        let configurationData = try Data(contentsOf: modelDirectory.appendingPathComponent("config.json"))
        return try assemble(configurationData: configurationData, role: role, reduction: reduction) { keep in
            let indexData = try Data(contentsOf: modelDirectory.appendingPathComponent("model.safetensors.index.json"))
            guard let index = (try JSONSerialization.jsonObject(with: indexData) as? [String: Any])?["weight_map"]
                    as? [String: String] else {
                throw ProbeError("MiMo tensor parallel load: the checkpoint index has no weight map")
            }
            var byFile: [String: [String]] = [:]
            for (key, file) in index {
                guard !file.contains("/"), file.hasSuffix(".safetensors") else {
                    throw ProbeError("MiMo tensor parallel load: the checkpoint index names an unexpected file")
                }
                byFile[file, default: []].append(key)
            }
            for file in byFile.keys.sorted() {
                let arrays = try loadArrays(url: modelDirectory.appendingPathComponent(file))
                guard Set(arrays.keys) == Set(byFile[file]!) else {
                    throw ProbeError("MiMo tensor parallel load: \(file) differs from the index")
                }
                for key in byFile[file]!.sorted() { try keep(key, arrays[key]!) }
            }
        }
    }

    /// What `assemble`'s tensors hand to `keep`.
    enum Parts {
        /// Every stored tensor whole; `keep` cuts this rank's part.
        case whole
        /// Only this rank's part of each tensor, already cut where the plan
        /// divides it (`MiMoTensorParallelVerifiedLoad`): checked, never cut.
        case rankParts
    }

    /// The model of `role` from a configuration and its stored tensors:
    /// `tensors` hands every stored tensor (by indexed name) to `keep`, which
    /// cuts this rank's part (or checks a part already cut) and materializes
    /// it at once.
    static func assemble(configurationData: Data, role: Role, reduction: QwenTensorParallelReduction?,
                         parts: Parts = .whole,
                         tensors: (_ keep: (String, MLXArray) throws -> Void) throws -> Void) throws
        -> MiMoTensorParallelModel {
        let started = DispatchTime.now().uptimeNanoseconds
        let plan = try MiMoTensorParallelPlan(configuration: configurationData)
        let full = try JSONDecoder().decode(MiMoV26Configuration.self, from: configurationData)
        var shard: MiMoV26TensorShard?
        var configuration = full
        switch role {
        case .full:
            guard reduction == nil else { throw ProbeError("MiMo tensor parallel load: only a shard takes a reduction") }
        case .shard(let rank):
            guard let reduction, reduction.size == plan.size, reduction.rank == rank else {
                throw ProbeError("MiMo tensor parallel load: a shard needs the reduction of its own rank and group size")
            }
            let rankShard = try MiMoV26TensorShard(rank: rank)
            shard = rankShard
            configuration = try JSONDecoder().decode(MiMoV26Configuration.self,
                from: plan.shardConfigurationData(configurationData, rank: rank))
            // The plan's configuration and the SDK's own derivation must agree.
            let derived = try rankShard.localConfiguration(full)
            guard configuration.fullAttention == derived.fullAttention,
                  configuration.slidingAttention == derived.slidingAttention,
                  configuration.intermediateSize == derived.intermediateSize,
                  configuration.moeIntermediateSize == derived.moeIntermediateSize,
                  configuration.hybridLayerPattern == full.hybridLayerPattern,
                  configuration.moeLayerFrequency == full.moeLayerFrequency,
                  configuration.vocabularySize == full.vocabularySize, configuration.hiddenSize == full.hiddenSize,
                  configuration.numNextnPredictLayers == 0, derived.numNextnPredictLayers == 0 else {
                throw ProbeError("MiMo tensor parallel load: the plan's shard configuration differs from the SDK's")
            }
        }
        let model = try MiMoV26TextModel(configuration)
        if case .shard(let rank) = role, let reduction {
            try model.installTensorParallel(reduce: { reduction.allSum($0) },
                                            vocabularyRows: plan.vocabularyRange(rank: rank))
        }
        var weights: [String: MLXArray] = [:]
        try tensors { key, value in
            if case .excluded = try plan.disposition(of: key) { return }
            let local = String(key.dropFirst(MiMoTensorParallelPlan.textNamespace.count))
            guard weights[local] == nil else { throw ProbeError("MiMo tensor parallel load: \(key) was given twice") }
            let stored = try plan.expectedShape(key: key)
            let axis = try plan.cut(key: key)
            guard try MiMoV26TensorShard.splitAxis(local) == axis else {
                throw ProbeError("MiMo tensor parallel load: the plan and the SDK cut \(key) differently")
            }
            var part = value
            switch (parts, shard) {
            case (.rankParts, .some):
                guard value.shape == (try plan.localShape(key: key, shape: stored)) else {
                    throw ProbeError("MiMo tensor parallel load: \(key)'s part has shape \(value.shape), not the plan's")
                }
            case (_, let shard?):
                guard stored == value.shape else {
                    throw ProbeError("MiMo tensor parallel load: \(key) has shape \(value.shape), not the plan's")
                }
                part = try shard.slice(value, axis: axis)
                guard part.shape == (try plan.localShape(key: key, shape: value.shape)) else {
                    throw ProbeError("MiMo tensor parallel load: \(key) cut to \(part.shape), not the plan's")
                }
            case (_, nil):
                guard stored == value.shape else {
                    throw ProbeError("MiMo tensor parallel load: \(key) has shape \(value.shape), not the plan's")
                }
            }
            // Materialize each part now: the stored tensor is released before the next read.
            eval(part)
            weights[local] = part
        }
        quantize(model: model) { path, _ in
            guard weights[path + ".scales"] != nil,
                  let policy = plan.policy(module: MiMoTensorParallelPlan.textNamespace + path) else { return nil }
            return (policy.groupSize, policy.bits, policy.mode == "mxfp4" ? .mxfp4 : .affine)
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.all])
        model.freeze()
        let parameters = model.parameters().flattened().map(\.1)
        eval(parameters)
        Memory.clearCache()
        let vocabulary: Range<Int>
        if case .shard(let rank) = role { vocabulary = plan.vocabularyRange(rank: rank) } else { vocabulary = 0 ..< plan.vocabularySize }
        guard model.headVocabularyRange == vocabulary else {
            throw ProbeError("MiMo tensor parallel load: the head does not project the plan's vocabulary rows")
        }
        return MiMoTensorParallelModel(role: role, plan: plan, vocabularyRange: vocabulary,
            loadSeconds: Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9,
            loadedParameterBytes: parameters.reduce(0) { $0 + $1.nbytes }, model: model, reduction: reduction)
    }

    private init(role: Role, plan: MiMoTensorParallelPlan, vocabularyRange: Range<Int>, loadSeconds: Double,
                 loadedParameterBytes: Int, model: MiMoV26TextModel, reduction: QwenTensorParallelReduction?) {
        self.role = role; self.plan = plan; self.vocabularyRange = vocabularyRange; self.loadSeconds = loadSeconds
        self.loadedParameterBytes = loadedParameterBytes; self.model = model; self.reduction = reduction
    }

    /// The head's selections over this model's vocabulary rows.
    public var selection: Gemma4TensorParallelSelection {
        Gemma4TensorParallelSelection(vocabularyRange: vocabularyRange, vocabularySize: plan.vocabularySize,
                                      reduction: reduction)
    }

    func newCache() -> [KVCache] { model.newCache() }

    /// The last position's logits `[1, V or V/2]` after `tokens`, not evaluated.
    func forward(_ tokens: [Int], cache: [KVCache]) throws -> MLXArray {
        let input = MLXArray(tokens.map { Int32($0) }).reshaped(1, tokens.count)
        return try model.forward(inputIDs: input, cache: cache, logitsStart: tokens.count - 1).logits[0..., -1, 0...]
    }

    /// The prompt through the model in chunks; the last position's logits.
    func prefill(_ prompt: [Int], chunk: Int, cache: [KVCache]) throws -> MLXArray {
        var offset = 0
        while true {
            let end = min(prompt.count, offset + chunk)
            let logits = try forward(Array(prompt[offset ..< end]), cache: cache)
            if end == prompt.count { return logits }
            eval(cache.flatMap { $0.innerState() })
            offset = end
        }
    }

    /// One greedy generation's tokens and per-step evidence.
    public struct Generation: Sendable {
        public var tokenIDs: [Int] = []
        /// Per step, the top `recordTop` token IDs, their logits and log
        /// probabilities over the whole vocabulary, highest first.
        public var topTokenIDs: [[Int]] = []
        public var topLogits: [[Float]] = []
        public var topLogprobs: [[Float]] = []
        /// Per step, SHA-256 of the whole vocabulary's FP32 row.
        public var stepRowSHA256: [String] = []
        /// The last step's whole row (FP32), when recorded.
        public var finalLogits: [Float]?
        /// SHA-256 of this model's KV caches after the last step.
        public var cacheSHA256 = ""
        /// Per position (prompt, then each fed output token), each routed
        /// layer's selected experts, ascending; when recorded.
        public var routeSets: [[[Int]]]?
        public var firstTokenSeconds = 0.0
        public var decodeSeconds = 0.0
        public var peakActiveBytes = 0
    }

    /// Sampling as the product samples one row: `MLXRandom.categorical` over
    /// the whole row scaled by `1 / temperature`, keyed by `seed + step`.
    public struct Sampling: Sendable, Equatable {
        public let temperature: Float
        public let seed: UInt64
        public init(temperature: Float, seed: UInt64) { self.temperature = temperature; self.seed = seed }
    }

    /// Generation of `outputCount` tokens after `prompt`, prefilled in chunks
    /// of `chunk`: greedy through the vocabulary-split argmax, or `sampling`
    /// over the whole row gathered bit for bit on every rank, so each rank
    /// draws the token one Mac draws from the same row. `recordTop` > 0
    /// records each step's top logits and log probabilities (a shard through
    /// the vocabulary-split top-k gather), each step's whole row digest and
    /// the final row (a shard through the row gather). Every rank issues its
    /// collectives in one fixed order: the forward's, the selection, the
    /// top-k gather, then the row gather.
    public func generate(prompt: [Int], outputCount: Int, chunk: Int, recordTop: Int = 0,
                         sampling: Sampling? = nil) throws -> Generation {
        guard !prompt.isEmpty, outputCount >= 1, chunk >= 1,
              prompt.allSatisfy({ (0 ..< plan.vocabularySize).contains($0) }) else {
            throw ProbeError("MiMo tensor parallel generation: empty or out-of-vocabulary request")
        }
        guard (0 ... 64).contains(recordTop) else { throw ProbeError("MiMo tensor parallel generation: at most 64 logits per step") }
        guard sampling.map({ $0.temperature.isFinite && $0.temperature > 0 }) ?? true else {
            throw ProbeError("MiMo tensor parallel generation: sampling needs a positive temperature")
        }
        let selection = self.selection
        let cache = newCache()
        var result = Generation()
        let started = Self.now()
        var logits = try prefill(prompt, chunk: chunk, cache: cache)
        for step in 0 ..< outputCount {
            let token: MLXArray
            if let sampling {
                token = MLXRandom.categorical(selection.gather(logits) * (1 / sampling.temperature),
                                              key: MLXRandom.key(sampling.seed &+ UInt64(step))).asType(.int32)
            } else {
                token = selection.greedy(logits)
            }
            eval(token)
            let id = Int(token.item(Int32.self))
            if recordTop > 0 {
                let top = try selection.topK(logits, count: recordTop)
                result.topTokenIDs.append(top.tokenIDs)
                result.topLogits.append(top.logits)
                result.topLogprobs.append(top.logprobs)
                let row = selection.gather(logits)
                eval(row)
                let values = row.asArray(Float.self)
                result.stepRowSHA256.append(Self.digest(values))
                if step == outputCount - 1 { result.finalLogits = values }
            }
            if step == 0 { result.firstTokenSeconds = Self.now() - started }
            result.tokenIDs.append(id)
            if step + 1 < outputCount { logits = try forward([id], cache: cache) }
        }
        result.decodeSeconds = Self.now() - started - result.firstTokenSeconds
        let state = cache.flatMap(\.state)
        eval(state)
        result.cacheSHA256 = sha256(state.reduce(into: Data()) { $0.append($1.asData(access: .copy).data) })
        result.peakActiveBytes = Memory.peakMemory
        return result
    }

    static func digest(_ values: [Float]) -> String {
        sha256(values.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}
