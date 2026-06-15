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
            let cache = try Self.makeCache(for: mode, model: context.model)
            return try Self.scoreTokenIDs(cappedTokenIDs, context: context, cache: cache)
        }
    }

    func logitFingerprint(text: String, mode: KVQuantCandidateMode, maxTokens: Int? = nil) async throws -> KVQuantLogitFingerprint {
        let container = try await loadContainer()
        return try await container.perform { context in
            let tokenIDs = context.tokenizer.encode(text: text, addSpecialTokens: true)
            let cappedTokenIDs = maxTokens.map { Array(tokenIDs.prefix(max($0, 2))) } ?? tokenIDs
            let cache = try Self.makeCache(for: mode, model: context.model)
            return try Self.logitFingerprint(cappedTokenIDs, context: context, cache: cache)
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

    private static func makeCache(for mode: KVQuantCandidateMode, model: any LanguageModel) throws -> [KVCache] {
        let execConfig = try KVQuantExecution.config(for: mode, base: Self.baseParameters())
        return execConfig.makeCache(using: model)
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
