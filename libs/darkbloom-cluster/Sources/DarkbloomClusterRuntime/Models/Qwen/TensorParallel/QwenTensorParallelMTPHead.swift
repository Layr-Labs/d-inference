import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

/// The assistant is replicated, but its target output head remains genuinely
/// vocabulary-sharded. Every draft step reconstructs complete logits through
/// an authoritative-hidden exchange and one score gather; no rank stores
/// another copy of the full head.
final class QwenTensorParallelMTPProjection: Linear {
    let local: Linear
    let vocabulary: Range<Int>
    let vocabularySize: Int
    let reduction: any QwenTensorParallelReduction

    init(local: Linear, vocabulary: Range<Int>, vocabularySize: Int,
         reduction: any QwenTensorParallelReduction) throws {
        guard reduction.size == 2, (0...1).contains(reduction.rank),
              vocabulary.lowerBound >= 0, vocabulary.upperBound <= vocabularySize,
              !vocabulary.isEmpty, local.weight.dim(0) == vocabulary.count else {
            throw ProbeError("Qwen TP assistant output head differs from the target shard")
        }
        self.local = local; self.vocabulary = vocabulary
        self.vocabularySize = vocabularySize; self.reduction = reduction
        super.init(weight: MLXArray.zeros([1, 1]), bias: nil)
    }

    override func callAsFunction(_ input: MLXArray) -> MLXArray {
        // Proposal generation is rank0-authoritative. Replica history need not
        // be bit-identical across different chips; both vocabulary shards must
        // project the same assistant row before gathering its scores.
        let contribution = reduction.rank == 0 ? input.asType(.float32)
            : -MLXArray.zeros(input.shape, dtype: .float32)
        let authoritative = reduction.allSum(contribution).asType(input.dtype)
        let selected = local(authoritative)
        var shape = selected.shape
        var pieces: [MLXArray] = []
        // Negative zero also preserves the sign of a selected zero. FP32
        // transport exactly represents every BF16/F16 head result.
        func empty(_ count: Int) -> MLXArray {
            shape[shape.count - 1] = count
            return -MLXArray.zeros(shape, dtype: .float32)
        }
        if vocabulary.lowerBound > 0 { pieces.append(empty(vocabulary.lowerBound)) }
        pieces.append(selected.asType(.float32))
        if vocabulary.upperBound < vocabularySize { pieces.append(empty(vocabularySize - vocabulary.upperBound)) }
        return reduction.allSum(concatenated(pieces, axis: -1)).asType(selected.dtype)
    }
}

/// A layerless full-geometry metadata shell borrows the replicated embedding
/// and final norm, and calls the actual sharded output projection above. Its
/// assistant alone owns the additional packed parameters. No model-global MTP
/// switch is changed, and request histories are created separately as pages.
final class QwenTensorParallelMTPHead {
    let assistant: Qwen35InlineMTPAssistant
    let target: Qwen35TextModel
    let projection: QwenTensorParallelMTPProjection

    init(model: QwenTensorParallelModel, configuration: Data,
         indexedWeights: [String: MLXArray], reduction: any QwenTensorParallelReduction,
         verificationMode: CBv2MTPVerificationMode = .rectangular,
         retainDuringLoad: ((Qwen35InlineMTPAssistant) -> Void)? = nil) throws {
        guard case .shard(let rank, let size) = model.role,
              rank == reduction.rank, size == reduction.size, size == 2,
              !model.plan.routedExperts, sha256(configuration) == model.configurationSHA256,
              let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              var text = root["text_config"] as? [String: Any],
              text["tie_word_embeddings"] as? Bool != true else {
            throw ProbeError("Qwen TP assistant requires its dense untied target and exact configuration")
        }
        let modules = Dictionary(uniqueKeysWithValues: model.model.namedModules())
        func module<T>(_ suffix: String) throws -> T {
            let found = modules.filter { $0.key == suffix || $0.key.hasSuffix("." + suffix) }
            guard found.count == 1, let value = found.first?.value as? T else {
                throw ProbeError("Qwen TP assistant cannot identify target \(suffix)")
            }
            return value
        }
        let embedding: Embedding = try module("model.embed_tokens")
        let norm: RMSNorm = try module("model.norm")
        let localHead: Linear = try module("lm_head")
        projection = try .init(local: localHead, vocabulary: model.vocabularyRange,
            vocabularySize: model.plan.vocabularySize, reduction: reduction)
        text["num_hidden_layers"] = 0; text["layer_types"] = [String](); text["mtp_num_hidden_layers"] = 0
        target = Qwen35TextModel(try JSONDecoder().decode(Qwen35TextConfiguration.self,
            from: JSONSerialization.data(withJSONObject: text, options: [.sortedKeys])))
        try target.update(modules: ModuleChildren.unflattened([
            ("model.embed_tokens", embedding as Module), ("lm_head", projection as Module)
        ]), verify: [.noUnusedKeys])
        try target.update(parameters: ModuleParameters.unflattened(["model.norm.weight": norm.weight]),
            verify: [.noUnusedKeys, .shapeMismatch])
        assistant = try Qwen35InlineMTPAssistant.load(configurationData: configuration,
            indexedWeights: indexedWeights, target: target, verificationMode: verificationMode,
            allowsShortlist: false, retainDuringLoad: retainDuringLoad)
        assistant.historyFlushRows = QwenTensorParallelMTPPolicy.historyFlushRows
    }
}
