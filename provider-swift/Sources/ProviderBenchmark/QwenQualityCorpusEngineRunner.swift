import Foundation
import MLXLMCommon

struct QwenQualityPreparedCase: Sendable {
    let corpusCase: QwenQualityCorpus.Case
    let promptTokens: [Int]
}

/// Tiny CBv2 stream seam used by both the real corpus harness and unit tests.
///
/// Engine construction and model/tokenizer loading deliberately stay outside
/// this type. The real-model caller supplies the one EngineV2Factory engine;
/// tests supply a scripted CBv2Engine while exercising identical request,
/// sequencing, timing, terminal, usage, and output validation.
enum QwenQualityCorpusEngineRunner {
    static func run(
        engine: any CBv2Engine,
        prepared: QwenQualityPreparedCase,
        maximumTokens: Int,
        requestID: CBv2RequestID
    ) async throws -> QwenQualityCorpusReport.CaseResult {
        guard maximumTokens > 0 else {
            throw QwenQualityCorpusExecutionError.invalidMaximumTokens(maximumTokens)
        }

        let submittedAt = DispatchTime.now().uptimeNanoseconds
        let stream: AsyncStream<CBv2Event>
        do {
            stream = try engine.submit(CBv2Request(
                id: requestID,
                promptTokens: prepared.promptTokens,
                sampling: CBv2SamplingParams(
                    temperature: 0,
                    topP: 1,
                    topK: 0,
                    minP: 0,
                    repetitionPenalty: 1,
                    frequencyPenalty: 0,
                    presencePenalty: 0),
                maxTokens: maximumTokens,
                stopTokens: [],
                stopStrings: [],
                prefixCacheEnabled: false))
        } catch {
            throw QwenQualityCorpusExecutionError.submissionFailed(
                caseID: prepared.corpusCase.id,
                message: String(describing: error))
        }

        var generatedTokenIDs: [Int] = []
        generatedTokenIDs.reserveCapacity(maximumTokens)
        var text = ""
        var firstTokenAt: UInt64?
        var terminalAt: UInt64?
        var terminalReason: CBv2FinishReason?
        var terminalUsage: CBv2Usage?

        for await event in stream {
            guard terminalReason == nil else {
                throw QwenQualityCorpusExecutionError.eventAfterTerminal(
                    caseID: prepared.corpusCase.id)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            switch event {
            case .delta(let fragment, let tokens, _):
                if firstTokenAt == nil, !tokens.isEmpty {
                    firstTokenAt = now
                }
                generatedTokenIDs.append(contentsOf: tokens)
                text += fragment
                guard generatedTokenIDs.count <= maximumTokens else {
                    throw QwenQualityCorpusExecutionError.tooManyTokens(
                        caseID: prepared.corpusCase.id,
                        expected: maximumTokens,
                        actual: generatedTokenIDs.count)
                }
            case .finished(let reason, let usage):
                terminalReason = reason
                terminalUsage = usage
                terminalAt = now
            }
        }

        guard let firstTokenAt else {
            throw QwenQualityCorpusExecutionError.noFirstToken(
                caseID: prepared.corpusCase.id)
        }
        guard let terminalReason, let terminalUsage, let terminalAt else {
            throw QwenQualityCorpusExecutionError.missingTerminal(
                caseID: prepared.corpusCase.id)
        }
        guard terminalReason == .length else {
            throw QwenQualityCorpusExecutionError.unexpectedTerminal(
                caseID: prepared.corpusCase.id,
                reason: describe(terminalReason))
        }
        guard generatedTokenIDs.count == maximumTokens else {
            throw QwenQualityCorpusExecutionError.unexpectedTokenCount(
                caseID: prepared.corpusCase.id,
                expected: maximumTokens,
                actual: generatedTokenIDs.count)
        }
        guard generatedTokenIDs.allSatisfy({ $0 >= 0 }) else {
            throw QwenQualityCorpusExecutionError.negativeTokenID(
                caseID: prepared.corpusCase.id)
        }
        guard terminalUsage.promptTokens == prepared.promptTokens.count,
              terminalUsage.completionTokens == generatedTokenIDs.count
        else {
            throw QwenQualityCorpusExecutionError.usageMismatch(
                caseID: prepared.corpusCase.id,
                expectedPrompt: prepared.promptTokens.count,
                actualPrompt: terminalUsage.promptTokens,
                expectedCompletion: generatedTokenIDs.count,
                actualCompletion: terminalUsage.completionTokens)
        }

        let firstTokenNanoseconds = firstTokenAt >= submittedAt
            ? firstTokenAt - submittedAt : 0
        let totalNanoseconds = terminalAt >= submittedAt
            ? terminalAt - submittedAt : 0
        let timeToFirstTokenMs = Double(firstTokenNanoseconds) / 1_000_000
        let totalTimeMs = Double(totalNanoseconds) / 1_000_000
        let prefillWork = max(0, prepared.promptTokens.count - 1)
        let prefillTokensPerSecond = firstTokenNanoseconds > 0
            ? Double(prefillWork) / (Double(firstTokenNanoseconds) / 1_000_000_000)
            : 0

        return QwenQualityCorpusReport.CaseResult(
            id: prepared.corpusCase.id,
            category: prepared.corpusCase.category,
            prompt: prepared.corpusCase.prompt,
            promptTokenCount: prepared.promptTokens.count,
            timeToFirstTokenMs: timeToFirstTokenMs,
            estimatedPrefillTokensPerSecond: prefillTokensPerSecond,
            totalTimeMs: max(totalTimeMs, timeToFirstTokenMs),
            generatedTokenCount: generatedTokenIDs.count,
            generatedTokenIDs: generatedTokenIDs,
            tokenChecksum: ArrivalPrefillAccounting.tokenChecksum(generatedTokenIDs),
            text: text,
            finishReason: "length")
    }

    private static func describe(_ reason: CBv2FinishReason) -> String {
        switch reason {
        case .stop: return "stop"
        case .length: return "length"
        case .cancelled: return "cancelled"
        case .error(let message): return "error: \(message)"
        case .terminal(let cause, let message): return "terminal \(cause): \(message)"
        }
    }
}

public enum QwenQualityCorpusExecutor {
    public static let minimumGenerationTokens = 32
    public static let maximumGenerationTokens = 4_096

    static func prepare(
        corpus: QwenQualityCorpus,
        maximumTokens: Int,
        maximumContextTokens: Int?,
        tokenizer: any Tokenizer
    ) throws -> [QwenQualityPreparedCase] {
        try QwenQualityCorpusLoader.validate(corpus)
        guard (minimumGenerationTokens ... maximumGenerationTokens)
            .contains(maximumTokens)
        else {
            throw QwenQualityCorpusExecutionError.invalidGenerationWindow(
                actual: maximumTokens,
                minimum: minimumGenerationTokens,
                maximum: maximumGenerationTokens)
        }

        return try corpus.cases.map { entry in
            let messages: [[String: any Sendable]] = [
                ["role": "user", "content": entry.prompt],
            ]
            let tokens: [Int]
            do {
                tokens = try tokenizer.applyChatTemplate(
                    messages: messages,
                    tools: nil,
                    additionalContext: nil)
            } catch {
                throw QwenQualityCorpusExecutionError.tokenizationFailed(
                    caseID: entry.id,
                    message: String(describing: error))
            }
            guard !tokens.isEmpty else {
                throw QwenQualityCorpusExecutionError.emptyTokenizedPrompt(
                    caseID: entry.id)
            }
            let (required, overflow) = tokens.count.addingReportingOverflow(maximumTokens)
            guard !overflow else {
                throw QwenQualityCorpusExecutionError.contextLengthOverflow(
                    caseID: entry.id)
            }
            if let maximumContextTokens, maximumContextTokens > 0,
               required > maximumContextTokens
            {
                throw QwenQualityCorpusExecutionError.contextLengthExceeded(
                    caseID: entry.id,
                    promptTokens: tokens.count,
                    generationTokens: maximumTokens,
                    maximumContextTokens: maximumContextTokens)
            }
            return QwenQualityPreparedCase(corpusCase: entry, promptTokens: tokens)
        }
    }

    static func execute(
        engine: any CBv2Engine,
        preparedCases: [QwenQualityPreparedCase],
        maximumTokens: Int,
        requestIDBase: UInt64
    ) async throws -> [QwenQualityCorpusReport.CaseResult] {
        var results: [QwenQualityCorpusReport.CaseResult] = []
        results.reserveCapacity(preparedCases.count)
        for (index, prepared) in preparedCases.enumerated() {
            guard let offset = UInt64(exactly: index) else {
                throw QwenQualityCorpusExecutionError.requestIDOverflow
            }
            let (rawID, overflow) = requestIDBase.addingReportingOverflow(offset)
            guard !overflow else {
                throw QwenQualityCorpusExecutionError.requestIDOverflow
            }
            // Await the terminal event before the next submission. This is the
            // binding sequential-execution guarantee, not a scheduler hint.
            results.append(try await QwenQualityCorpusEngineRunner.run(
                engine: engine,
                prepared: prepared,
                maximumTokens: maximumTokens,
                requestID: CBv2RequestID(rawID)))
        }
        return results
    }
}

enum QwenQualityCorpusExecutionError: Error, Equatable, CustomStringConvertible {
    case invalidMaximumTokens(Int)
    case invalidGenerationWindow(actual: Int, minimum: Int, maximum: Int)
    case tokenizationFailed(caseID: String, message: String)
    case emptyTokenizedPrompt(caseID: String)
    case contextLengthOverflow(caseID: String)
    case contextLengthExceeded(
        caseID: String,
        promptTokens: Int,
        generationTokens: Int,
        maximumContextTokens: Int
    )
    case requestIDOverflow
    case submissionFailed(caseID: String, message: String)
    case noFirstToken(caseID: String)
    case missingTerminal(caseID: String)
    case eventAfterTerminal(caseID: String)
    case unexpectedTerminal(caseID: String, reason: String)
    case tooManyTokens(caseID: String, expected: Int, actual: Int)
    case unexpectedTokenCount(caseID: String, expected: Int, actual: Int)
    case negativeTokenID(caseID: String)
    case usageMismatch(
        caseID: String,
        expectedPrompt: Int,
        actualPrompt: Int,
        expectedCompletion: Int,
        actualCompletion: Int
    )

    var description: String {
        switch self {
        case .invalidMaximumTokens(let value):
            return "quality generation maximumTokens must be positive (got \(value))"
        case .invalidGenerationWindow(let actual, let minimum, let maximum):
            return "quality generation tokens must be in \(minimum)...\(maximum) (got \(actual))"
        case .tokenizationFailed(let id, let message):
            return "quality case '\(id)' chat-template tokenization failed: \(message)"
        case .emptyTokenizedPrompt(let id):
            return "quality case '\(id)' chat template produced no tokens"
        case .contextLengthOverflow(let id):
            return "quality case '\(id)' prompt plus generation length overflowed"
        case .contextLengthExceeded(
            let id, let prompt, let generation, let maximum
        ):
            return "quality case '\(id)' requires \(prompt)+\(generation) tokens, "
                + "exceeding model context \(maximum)"
        case .requestIDOverflow:
            return "quality corpus exhausted the CBv2 request-id space"
        case .submissionFailed(let id, let message):
            return "quality case '\(id)' submission failed: \(message)"
        case .noFirstToken(let id):
            return "quality case '\(id)' completed without a first token"
        case .missingTerminal(let id):
            return "quality case '\(id)' stream ended without a terminal event"
        case .eventAfterTerminal(let id):
            return "quality case '\(id)' emitted an event after its terminal"
        case .unexpectedTerminal(let id, let reason):
            return "quality case '\(id)' finished unexpectedly: \(reason)"
        case .tooManyTokens(let id, let expected, let actual):
            return "quality case '\(id)' emitted \(actual) tokens before its terminal; "
                + "maximum was \(expected)"
        case .unexpectedTokenCount(let id, let expected, let actual):
            return "quality case '\(id)' emitted \(actual) tokens; expected exactly \(expected)"
        case .negativeTokenID(let id):
            return "quality case '\(id)' emitted a negative token id"
        case .usageMismatch(
            let id, let expectedPrompt, let actualPrompt,
            let expectedCompletion, let actualCompletion
        ):
            return "quality case '\(id)' terminal usage mismatch: prompt "
                + "\(actualPrompt)/\(expectedPrompt), completion "
                + "\(actualCompletion)/\(expectedCompletion)"
        }
    }
}
