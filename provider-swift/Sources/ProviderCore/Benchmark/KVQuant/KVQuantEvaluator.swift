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
            let cache = execConfig.makeCache(using: context.model)
            if mode.isReference {
                // fp16 reference: single-forward is exact and fast.
                return try Self.scoreTokenIDs(cappedTokenIDs, context: context, cache: cache)
            }
            // Candidate: incremental token-by-token so the cache's own start-delay
            // and quantization actually engage (single-forward would silently
            // return fp16 for start-delayed caches).
            return try Self.scoreTokenIDsIncrementalCache(cappedTokenIDs, context: context, cache: cache)
        }
    }

    func logitFingerprint(text: String, mode: KVQuantCandidateMode, maxTokens: Int? = nil) async throws -> KVQuantLogitFingerprint {
        let container = try await loadContainer()
        return try await container.perform { context in
            let tokenIDs = context.tokenizer.encode(text: text, addSpecialTokens: true)
            let cappedTokenIDs = maxTokens.map { Array(tokenIDs.prefix(max($0, 2))) } ?? tokenIDs
            let execConfig = try Self.makeExecConfig(for: mode)
            let cache = execConfig.makeCache(using: context.model)
            if mode.isReference {
                return try Self.logitFingerprint(cappedTokenIDs, context: context, cache: cache)
            }
            return try Self.logitFingerprintIncrementalCache(cappedTokenIDs, context: context, cache: cache)
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

    /// Generation-fidelity: the trustworthy quality gate. The reference greedily
    /// continues `prompt` (producing coherent, high-confidence tokens), then the
    /// candidate is teacher-forced over prompt+continuation and we measure how
    /// often the candidate's argmax matches the reference's tokens. This uses the
    /// correct generation forward, exercises quantization incrementally (start
    /// delay engages), and avoids the unreliable raw-text PPL gauge.
    func generationAgreement(
        prompt: String,
        reference: KVQuantCandidateMode,
        candidate: KVQuantCandidateMode,
        count: Int
    ) async throws -> KVQuantGenAgreement {
        let container = try await loadContainer()
        return try await container.perform { context in
            let model = context.model
            let promptTokens = context.tokenizer.encode(text: prompt, addSpecialTokens: true)
            guard promptTokens.count >= 1 else { throw KVQuantEvaluatorError.tooFewTokens(promptTokens.count) }

            // 1. Reference greedy continuation. Prime the (possibly long) prompt in a
            //    single batched forward, then decode token-by-token.
            let refCache = try Self.makeExecConfig(for: reference).makeCache(using: model)
            var last = Self.primePrompt(promptTokens, model: model, cache: refCache)
            var refTokens: [Int] = []
            for _ in 0..<count {
                let nt = Self.argmaxToken(last)
                refTokens.append(nt)
                last = Self.feedTokens([nt], model: model, cache: refCache)
            }

            let full = promptTokens + refTokens
            let promptLen = promptTokens.count

            // 2. Reference self-agreement (sanity; must be ~1.0) and candidate agreement,
            //    both teacher-forced over the same full sequence.
            let refTF = Self.teacherForcedTop(full, promptLen: promptLen, model: model,
                cache: try Self.makeExecConfig(for: reference).makeCache(using: model))
            let candTF = Self.teacherForcedTop(full, promptLen: promptLen, model: model,
                cache: try Self.makeExecConfig(for: candidate).makeCache(using: model))

            func agreement(_ tf: (top1: [Int], top5: [[Int]])) -> (Double, Double) {
                guard !refTokens.isEmpty else { return (0, 0) }
                var t1 = 0, t5 = 0
                for j in 0..<refTokens.count where j < tf.top1.count {
                    if tf.top1[j] == refTokens[j] { t1 += 1 }
                    if tf.top5[j].contains(refTokens[j]) { t5 += 1 }
                }
                return (Double(t1) / Double(refTokens.count), Double(t5) / Double(refTokens.count))
            }

            let (refSelf, _) = agreement(refTF)
            let (candTop1, candTop5) = agreement(candTF)
            return KVQuantGenAgreement(
                referenceSelfTop1: refSelf,
                candidateTop1: candTop1,
                candidateTop5: candTop5,
                generatedTokens: refTokens.count)
        }
    }

    /// Prime a (possibly long) prompt in ONE batched forward; returns last-position
    /// fp32 logits [1, vocab]. For ProtocolSafe this quantizes all prompt tokens at
    /// once; for start-delayed caches it stores fp16 then converts past the start.
    private static func primePrompt(_ tokens: [Int], model: any LanguageModel, cache: [KVCache]) -> MLXArray {
        precondition(!tokens.isEmpty)
        let input = MLXArray(tokens.map(Int32.init))[.newAxis]
        let out = model(input, cache: cache)
        let logits = out[0..., -1, 0...].asType(.float32)
        eval(logits)
        return logits
    }

    /// Feed tokens incrementally through `cache`; returns last-position fp32 logits [1, vocab].
    private static func feedTokens(_ tokens: [Int], model: any LanguageModel, cache: [KVCache]) -> MLXArray {
        var last = MLXArray.zeros([1, 1])
        for t in tokens {
            let input = MLXArray([Int32(t)])[.newAxis]
            last = model(input, cache: cache)
        }
        let logits = last[0..., -1, 0...].asType(.float32)
        eval(logits)
        return logits
    }

    private static func argmaxToken(_ logits1xVocab: MLXArray) -> Int {
        Int(argMax(logits1xVocab, axis: -1).item(Int32.self))
    }

    /// Teacher-force `tokenIDs`; return top-1/top-5 predictions for the continuation
    /// (the positions predicting tokenIDs[promptLen...]). Primes the prompt in one
    /// batched forward, then steps token-by-token over the continuation.
    private static func teacherForcedTop(
        _ tokenIDs: [Int], promptLen: Int, model: any LanguageModel, cache: [KVCache]
    ) -> (top1: [Int], top5: [[Int]]) {
        var top1: [Int] = []
        var top5: [[Int]] = []

        func record(_ out: MLXArray) {
            let logits = out[0..., -1, 0...].asType(.float32)
            top1.append(Int(argMax(logits, axis: -1).item(Int32.self)))
            let sorted = argSort(logits, axis: -1)
            let vocab = logits.dim(-1)
            let k = min(5, vocab)
            top5.append(sorted[.ellipsis, (vocab - k)..<vocab].asArray(Int32.self).map(Int.init))
        }

        // Prime prompt[0..<promptLen]; last position predicts the first continuation token.
        let promptInput = MLXArray(tokenIDs[0..<promptLen].map(Int32.init))[.newAxis]
        record(model(promptInput, cache: cache))
        // Step over continuation tokens (each predicts the next).
        for i in promptLen..<(tokenIDs.count - 1) {
            let input = MLXArray([Int32(tokenIDs[i])])[.newAxis]
            record(model(input, cache: cache))
        }
        return (top1, top5)
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

    /// Teacher-forced scorer that feeds one token at a time through the candidate's
    /// OWN cache, so the cache's start-delay and quantization actually engage. A
    /// single-forward pass would let start-delayed caches silently return fp16 for
    /// the whole sequence, hiding all quantization loss.
    private static func scoreTokenIDsIncrementalCache(
        _ tokenIDs: [Int],
        context: ModelContext,
        cache: [KVCache]
    ) throws -> KVQuantSequenceScore {
        guard tokenIDs.count >= 2 else { throw KVQuantEvaluatorError.tooFewTokens(tokenIDs.count) }

        let tokenArray = MLXArray(tokenIDs.map(Int32.init))[.newAxis]
        var negativeLogLikelihoods: [Float] = []

        for i in 0..<(tokenIDs.count - 1) {
            let input = tokenArray[0..., i..<(i + 1)]
            var logits = context.model(input, cache: cache)
            logits = logits[0..., -1, 0...].asType(.float32)
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

    /// Incremental logit fingerprint through the candidate's own cache (see
    /// ``scoreTokenIDsIncrementalCache`` for why incremental is required).
    private static func logitFingerprintIncrementalCache(
        _ tokenIDs: [Int],
        context: ModelContext,
        cache: [KVCache]
    ) throws -> KVQuantLogitFingerprint {
        guard tokenIDs.count >= 2 else { throw KVQuantEvaluatorError.tooFewTokens(tokenIDs.count) }

        let tokenArray = MLXArray(tokenIDs.map(Int32.init))[.newAxis]
        var top1: [Int] = []
        var top5: [[Int]] = []

        for i in 0..<(tokenIDs.count - 1) {
            let input = tokenArray[0..., i..<(i + 1)]
            var logits = context.model(input, cache: cache)
            logits = logits[0..., -1, 0...].asType(.float32)
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

struct KVQuantGenAgreement: Sendable, Equatable {
    let referenceSelfTop1: Double
    let candidateTop1: Double
    let candidateTop5: Double
    let generatedTokens: Int
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
