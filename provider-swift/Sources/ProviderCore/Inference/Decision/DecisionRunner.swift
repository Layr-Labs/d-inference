// Copyright © 2026 Eigen Labs.
//
// Runs a decision request on a loaded pplx-decider slot through the ordinary
// v2 engine path, one question at a time.
//
// The pack installs the trained readout as the model's output head (one row
// per option), so the engine's first-token logprobs ARE the option logits'
// log-softmax at T=1. A question is one chat submission with `max_tokens 1`
// and `top_logprobs` equal to the head width; the first token's alternatives
// (head rows, carried as `SSETokenLogprob.Top.tokenID`) are ordered by option,
// tempered with the pack's temperature and turned into the reference answer.
// The sampled token itself is discarded.

import Foundation
import MLXLMCommon
import MLXLMServer

/// What one question asks of the caller's engine view.
struct DecisionQuestionSubmission: Sendable {
    /// Position in the request; callers bind once-per-request lifecycle
    /// signals (the prefix-cache receipt) to question 0 only.
    let index: Int
    let logprobs: EngineV2LogprobsPlumbing
    let inputTokenLimit: Int
}

struct DecisionRunner: Sendable {
    /// Builds a single-model `MultiModelBatchSchedulerEngine` over the
    /// acquired slot with the submission's logprobs plumbing and
    /// `decisionInputTokenLimit`. Coordinator and local callers bind their own
    /// deadline, cache scope and reservation lifecycle.
    typealias EngineFactory = @Sendable (DecisionQuestionSubmission) -> MultiModelBatchSchedulerEngine

    struct Outcome: Sendable {
        let response: DecisionJSON
        /// Prompt tokens summed over every question.
        let inputTokens: Int
        /// One sampled token per question.
        let outputTokens: Int
    }

    let configuration: PplxDeciderConfiguration
    let makeEngine: EngineFactory

    static func responseID() -> String {
        "decision-" + UUID().uuidString.lowercased()
    }

    func run(
        _ request: DecisionRequest,
        id: String = DecisionRunner.responseID(),
        created: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> Outcome {
        var answers: [DecisionJSON.Member] = []
        answers.reserveCapacity(request.questions.count)
        var inputTokens = 0
        for (index, entry) in request.questions.enumerated() {
            try Task.checkCancellation()
            let text = try DecisionPrompt.text(
                state: request.state, question: entry.question, codes: configuration.codes)
            let optionCount = DecisionPrompt.options(entry.question).keys.count
            let readout = try await readOptionLogprobs(
                index: index, request: request, text: text, optionCount: optionCount)
            let probabilities = PplxDecision.probabilities(
                optionLogprobs: readout.optionLogprobs, temperature: configuration.temperature)
            let answer: DecisionJSON
            do {
                answer = try DecisionAnswer.answer(
                    entry.question, probabilities: probabilities.map(Double.init))
            } catch {
                throw Self.readoutFailure
            }
            answers.append(.init(key: entry.key, value: answer))
            inputTokens += readout.promptTokens
        }
        let outputTokens = request.questions.count
        return Outcome(
            response: DecisionAnswer.response(
                id: id, created: created, model: request.model, answers: answers,
                inputTokens: inputTokens, outputTokens: outputTokens),
            inputTokens: inputTokens,
            outputTokens: outputTokens)
    }

    /// Content-free provider fault: the engine finished without a usable
    /// option distribution (missing rows, non-finite values).
    static let readoutFailure = MultiModelBatchSchedulerEngineError.generationFailed(
        "decision readout produced no option distribution")

    private func readOptionLogprobs(
        index: Int, request: DecisionRequest, text: String, optionCount: Int
    ) async throws -> (optionLogprobs: [Float], promptTokens: Int) {
        let channel = EngineV2LogprobsChannel()
        let headWidth = configuration.options
        let engine = makeEngine(DecisionQuestionSubmission(
            index: index,
            logprobs: EngineV2LogprobsPlumbing(
                topLogprobs: headWidth, channel: channel, maximumTopLogprobs: headWidth),
            inputTokenLimit: configuration.maxInputTokens))
        let chat = DecisionPrompt.chatRequest(model: request.model, text: text, images: request.images)
        var promptTokens: Int?
        for try await event in try await engine.streamChatCompletion(request: chat) {
            if case .info(let info) = event { promptTokens = info.promptTokens }
        }
        // A cancelled stream may still end cleanly with partial usage.
        try Task.checkCancellation()
        guard let promptTokens, let first = channel.drain().first else { throw Self.readoutFailure }
        let rows = first.topLogprobs.compactMap { top in
            top.tokenID.map { (token: $0, logprob: top.logprob) }
        }
        do {
            return (try PplxDecision.optionLogprobs(topLogprobs: rows, count: optionCount), promptTokens)
        } catch {
            throw Self.readoutFailure
        }
    }
}

extension DecisionRunner {
    /// Read the loaded pack's `decision` block from its `config.json`. The
    /// fork's `PplxDeciderConfiguration` decoder validates it.
    static func configuration(modelType: String?, container: ModelContainer?) async throws
        -> PplxDeciderConfiguration
    {
        guard EngineV2SupportedModels.isPplxDeciderModelType(modelType) else {
            throw DecisionRequestError.notADecisionModel
        }
        guard let container, case .directory(let directory) = await container.configuration.id else {
            throw MultiModelBatchSchedulerEngineError.generationFailed(
                "decision model directory is unavailable")
        }
        struct Declaration: Decodable {
            let decision: PplxDeciderConfiguration
        }
        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("config.json"))
            return try JSONDecoder().decode(Declaration.self, from: data).decision
        } catch {
            throw MultiModelBatchSchedulerEngineError.generationFailed(
                "decision model configuration is unreadable")
        }
    }
}
