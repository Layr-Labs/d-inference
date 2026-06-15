import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import ProviderCoreFoundation

struct KVQuantEvaluator {
    let config: KVQuantGateConfig
    let modelDirectory: URL

    func loadContainer() async throws -> ModelContainer {
        let modelConfiguration = LocalMLXModelConfiguration(
            modelID: config.modelID,
            modelDirectory: modelDirectory
        )
        let readiness = LocalMLXModelReadiness.inspect(modelConfiguration)
        guard readiness.canAttemptLoad else {
            throw KVQuantEvaluatorError.modelNotReady(readiness.issues)
        }
        return try await LocalMLXModelLoader.live().loadContainer(for: modelConfiguration)
    }

    func score(text: String, mode: KVQuantCandidateMode, maxTokens: Int? = nil) async throws -> KVQuantSequenceScore {
        let container = try await loadContainer()
        return try await container.perform { context in
            let tokenIDs = context.tokenizer.encode(text: text, addSpecialTokens: true)
            let cappedTokenIDs = maxTokens.map { Array(tokenIDs.prefix(max($0, 2))) } ?? tokenIDs
            let execConfig = try Self.makeExecConfig(for: mode)
            if let kvBits = execConfig.parameters.kvBits, kvBits > 0 {
                return try Self.scoreTokenIDsIncremental(cappedTokenIDs, context: context, parameters: execConfig.parameters)
            } else {
                let cache = execConfig.makeCache(using: context.model)
                return try Self.scoreTokenIDs(cappedTokenIDs, context: context, cache: cache)
            }
        }
    }

    func logitFingerprint(text: String, mode: KVQuantCandidateMode, maxTokens: Int? = nil) async throws -> KVQuantLogitFingerprint {
        let container = try await loadContainer()
        return try await container.perform { context in
            let tokenIDs = context.tokenizer.encode(text: text, addSpecialTokens: true)
            let cappedTokenIDs = maxTokens.map { Array(tokenIDs.prefix(max($0, 2))) } ?? tokenIDs
            let execConfig = try Self.makeExecConfig(for: mode)
            if let kvBits = execConfig.parameters.kvBits, kvBits > 0 {
                return try Self.logitFingerprintIncremental(cappedTokenIDs, context: context, parameters: execConfig.parameters)
            } else {
                let cache = execConfig.makeCache(using: context.model)
                return try Self.logitFingerprint(cappedTokenIDs, context: context, cache: cache)
            }
        }
    }

    func generate(prompt: String, mode: KVQuantCandidateMode, maxTokens: Int) async throws -> String {
        try await generate(messages: [["role": "user", "content": prompt]], mode: mode, maxTokens: maxTokens)
    }

    func generate(messages: [[String: String]], mode: KVQuantCandidateMode, maxTokens: Int) async throws -> String {
        let container = try await loadContainer()
        return try await Self.generate(messages: messages, maxTokens: maxTokens, modelID: config.modelID, container: container, mode: mode)
    }

    static func generate(
        prompt: String,
        maxTokens: Int,
        modelID: String,
        container: ModelContainer,
        mode: KVQuantCandidateMode
    ) async throws -> String {
        try await generate(messages: [["role": "user", "content": prompt]], maxTokens: maxTokens, modelID: modelID, container: container, mode: mode)
    }

    static func generate(
        messages: [[String: String]],
        maxTokens: Int,
        modelID: String,
        container: ModelContainer,
        mode: KVQuantCandidateMode
    ) async throws -> String {
        let rawMessages = messages.map { $0 as MLXLMCommon.Message }
        let execConfig = try KVQuantExecution.config(for: mode, base: Self.baseParameters(maxTokens: maxTokens))
        let stream: AsyncStream<Generation> = try await container.perform { context in
            let input = try await context.processor.prepare(input: UserInput(messages: rawMessages))
            let cache = execConfig.makeCache(using: context.model)
            return try MLXLMCommon.generate(
                input: input,
                cache: cache,
                parameters: execConfig.parameters,
                context: context
            )
        }
        var output = ""
        for await generation in stream {
            switch generation {
            case .chunk(let text): output += text
            case .info, .toolCall: break
            }
        }
        _ = modelID
        return output
    }

    private static func baseParameters(maxTokens: Int? = nil) -> GenerateParameters {
        GenerateParameters(
            maxTokens: maxTokens,
            temperature: 0.0,
            topP: 1.0,
            topK: 0
        )
    }

    private static func makeExecConfig(for mode: KVQuantCandidateMode) throws -> KVQuantExecutionConfig {
        try KVQuantExecution.config(for: mode, base: Self.baseParameters())
    }

    private static func makeCache(for mode: KVQuantCandidateMode, model: any LanguageModel) throws -> [KVCache] {
        try makeExecConfig(for: mode).makeCache(using: model)
    }

    private static func scoreTokenIDs(_ tokenIDs: [Int], context: ModelContext, cache: [KVCache]) throws -> KVQuantSequenceScore {
        guard tokenIDs.count >= 2 else { throw KVQuantEvaluatorError.tooFewTokens(tokenIDs.count) }
        let input = MLXArray(tokenIDs.map(Int32.init))[.newAxis]
        var logits = context.model(input, cache: cache)
        eval(logits)
        logits = logits[0..., ..<(tokenIDs.count - 1), 0...].asType(.float32)
        let targets = MLXArray(tokenIDs.dropFirst().map(Int32.init)).reshaped([1, tokenIDs.count - 1, 1])
        let logProbs = logSoftmax(logits, axis: -1)
        let targetLogProbs = takeAlong(logProbs, targets, axis: -1)
        let meanNLL = -targetLogProbs.mean().item(Float.self)
        let perplexity = Foundation.exp(Double(meanNLL))
        return KVQuantSequenceScore(
            tokenCount: tokenIDs.count,
            scoredTokenCount: tokenIDs.count - 1,
            meanNegativeLogLikelihood: Double(meanNLL),
            perplexity: perplexity
        )
    }

    private static func logitFingerprint(_ tokenIDs: [Int], context: ModelContext, cache: [KVCache]) throws -> KVQuantLogitFingerprint {
        guard tokenIDs.count >= 2 else { throw KVQuantEvaluatorError.tooFewTokens(tokenIDs.count) }
        let input = MLXArray(tokenIDs.map(Int32.init))[.newAxis]
        var logits = context.model(input, cache: cache)
        eval(logits)
        logits = logits[0..., ..<(tokenIDs.count - 1), 0...].asType(.float32)
        let logProbs = logSoftmax(logits, axis: -1)
        let top1 = argMax(logProbs, axis: -1).asArray(Int32.self).map(Int.init)
        let sorted = argSort(logProbs, axis: -1)
        let vocab = logProbs.dim(-1)
        let topK = min(5, vocab)
        let top5Array = sorted[.ellipsis, (vocab - topK)..<vocab].asArray(Int32.self).map(Int.init)
        var groupedTop5: [[Int]] = []
        for index in stride(from: 0, to: top5Array.count, by: topK) {
            groupedTop5.append(Array(top5Array[index ..< min(index + topK, top5Array.count)]))
        }
        return KVQuantLogitFingerprint(top1: top1, top5: groupedTop5)
    }

    /// Teacher-forced scorer that processes one token at a time so that
    /// mlx-swift-lm's dynamic KV-cache quantization (``GenerateParameters.kvBits``)
    /// is exercised. This is required for full-KV affine modes because the upstream
    /// ``QuantizedKVCache`` does not support the single-pass ``update(keys:values:)``
    /// path used by ``scoreTokenIDs(_:context:cache:)``.
    private static func scoreTokenIDsIncremental(
        _ tokenIDs: [Int],
        context: ModelContext,
        parameters: GenerateParameters
    ) throws -> KVQuantSequenceScore {
        guard tokenIDs.count >= 2 else { throw KVQuantEvaluatorError.tooFewTokens(tokenIDs.count) }

        var cache = context.model.newCache(parameters: parameters)
        let tokenArray = MLXArray(tokenIDs.map(Int32.init))[.newAxis]
        var negativeLogLikelihoods: [Float] = []

        for i in 0..<(tokenIDs.count - 1) {
            let input = LMInput.Text(tokens: tokenArray[0..., i...i])
            let output = context.model(input, cache: cache, state: nil)
            maybeQuantizeKVCache(
                cache: &cache,
                kvBits: parameters.kvBits,
                kvGroupSize: parameters.kvGroupSize,
                quantizedKVStart: parameters.quantizedKVStart
            )

            let logits = output.logits[0..., -1, 0...].asType(.float32)
            let logProbs = logSoftmax(logits, axis: -1)
            let target = MLXArray(Int32(tokenIDs[i + 1])).reshaped([1, 1])
            let targetLogProb = takeAlong(logProbs, target, axis: -1)
            negativeLogLikelihoods.append(-targetLogProb.item(Float.self))
        }

        let meanNLL = Double(negativeLogLikelihoods.reduce(0, +)) / Double(negativeLogLikelihoods.count)
        let perplexity = Foundation.exp(meanNLL)
        return KVQuantSequenceScore(
            tokenCount: tokenIDs.count,
            scoredTokenCount: tokenIDs.count - 1,
            meanNegativeLogLikelihood: meanNLL,
            perplexity: perplexity
        )
    }

    /// Incremental logit fingerprint matching ``scoreTokenIDsIncremental`` so that
    /// full-KV affine modes are evaluated through the same quantized generation path.
    private static func logitFingerprintIncremental(
        _ tokenIDs: [Int],
        context: ModelContext,
        parameters: GenerateParameters
    ) throws -> KVQuantLogitFingerprint {
        guard tokenIDs.count >= 2 else { throw KVQuantEvaluatorError.tooFewTokens(tokenIDs.count) }

        var cache = context.model.newCache(parameters: parameters)
        let tokenArray = MLXArray(tokenIDs.map(Int32.init))[.newAxis]
        var top1: [Int] = []
        var top5: [[Int]] = []

        for i in 0..<(tokenIDs.count - 1) {
            let input = LMInput.Text(tokens: tokenArray[0..., i...i])
            let output = context.model(input, cache: cache, state: nil)
            maybeQuantizeKVCache(
                cache: &cache,
                kvBits: parameters.kvBits,
                kvGroupSize: parameters.kvGroupSize,
                quantizedKVStart: parameters.quantizedKVStart
            )

            let logits = output.logits[0..., -1, 0...].asType(.float32)
            let logProbs = logSoftmax(logits, axis: -1)
            top1.append(Int(argMax(logProbs, axis: -1).asArray(Int32.self)[0]))

            let sorted = argSort(logProbs, axis: -1)
            let vocab = logProbs.dim(-1)
            let topK = min(5, vocab)
            let topKIndices = sorted[.ellipsis, (vocab - topK)..<vocab].asArray(Int32.self).map(Int.init)
            top5.append(topKIndices)
        }

        return KVQuantLogitFingerprint(top1: top1, top5: top5)
    }
}

struct KVQuantSequenceScore: Sendable, Equatable {
    let tokenCount: Int
    let scoredTokenCount: Int
    let meanNegativeLogLikelihood: Double
    let perplexity: Double
}

struct KVQuantLogitFingerprint: Sendable, Equatable {
    let top1: [Int]
    let top5: [[Int]]
}

enum KVQuantEvaluatorError: Error, LocalizedError {
    case modelNotReady([LocalMLXModelReadinessIssue])
    case tooFewTokens(Int)

    var errorDescription: String? {
        switch self {
        case .modelNotReady(let issues):
            let issueList = issues.map { issue in
                if let detail = issue.detail {
                    return "\(issue.kind.rawValue) at \(issue.path.path): \(detail)"
                }
                return "\(issue.kind.rawValue) at \(issue.path.path)"
            }
            return "local model snapshot is not ready to load: \(issueList.joined(separator: "; "))"
        case .tooFewTokens(let count):
            return "need at least two tokens to score sequence, got \(count)"
        }
    }
}
