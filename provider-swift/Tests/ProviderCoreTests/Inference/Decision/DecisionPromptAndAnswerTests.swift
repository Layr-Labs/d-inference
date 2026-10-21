// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer
import Testing

@testable import ProviderCore

@Suite("Decision prompt and answer match the reference")
struct DecisionPromptAndAnswerTests {
    private func vectors() throws -> DecisionJSON { try DecisionReferenceVectors.load() }

    private func codes() throws -> [String] {
        try #require(vectors()["codes"]?.array).map { try #require($0.string) }
    }

    @Test("options and the user text equal decision_messages for every prompt vector")
    func promptVectors() throws {
        let vectors = try vectors()
        let codes = try codes()
        #expect(codes.count == 255)
        #expect(vectors["system_prompt"]?.string == DecisionPrompt.systemPrompt)
        let prompts = try #require(vectors["prompts"]?.array)
        #expect(prompts.count == 7)
        for prompt in prompts {
            let question = try DecisionReferenceVectors.question(try #require(prompt["question"]))
            let options = DecisionPrompt.options(question)
            #expect(DecisionJSON.array(options.keys.map { DecisionJSON.string($0) }) == prompt["option_keys"])
            #expect(DecisionJSON.array(options.descriptions) == prompt["option_descriptions"])

            let messages = try #require(prompt["messages"]?.array)
            #expect(messages[0]["role"]?.string == "system")
            #expect(messages[0]["content"]?.string == DecisionPrompt.systemPrompt)
            let parts = try #require(messages[1]["content"]?.array)
            let imageCount = try #require(prompt["image_count"]?.number)
            #expect(parts.dropLast().allSatisfy { $0["type"]?.string == "image" })
            #expect(Double(parts.count - 1) == imageCount)
            let text = try DecisionPrompt.text(
                state: try #require(prompt["state"]), question: question, codes: codes)
            #expect(text == parts.last?["text"]?.string)
        }
    }

    @Test("the chat request carries images first, thinking off and no-op sampling")
    func chatRequestShape() throws {
        let request = DecisionPrompt.chatRequest(
            model: "pplx-decider-v1-27b", text: "T", images: ["data:image/png;base64,AA==", "data:image/png;base64,BB=="])
        #expect(request.messages.count == 2)
        #expect(request.messages[0].role == .system)
        #expect(request.messages[0].content == .text(DecisionPrompt.systemPrompt))
        #expect(request.messages[1].content == .parts([
            .imageURL("data:image/png;base64,AA=="), .imageURL("data:image/png;base64,BB=="), .text("T"),
        ]))
        #expect(request.reasoning?.enabled == false)
        #expect(request.maxTokens == 1)
        #expect(request.temperature == 0 && request.topP == 1 && request.topK == 0)
        #expect(request.repetitionPenalty == 1 && request.presencePenalty == 0 && request.frequencyPenalty == 0)
        #expect(request.logitBias == nil && request.seed == nil && request.tools == nil)
        let textOnly = DecisionPrompt.chatRequest(model: "m", text: "T", images: [])
        #expect(textOnly.messages[1].content == .text("T"))
    }

    @Test("a question with more options than the pack's codes is refused")
    func optionCountAgainstCodes() throws {
        let question = DecisionQuestion(
            instructions: nil,
            criteria: .choice((0 ..< 3).map { .init(key: "k\($0)", value: .null) }))
        #expect(throws: DecisionRequestError.invalidOptionCount) {
            try DecisionPrompt.text(state: .string("s"), question: question, codes: ["A", "B"])
        }
    }

    @Test("answers equal the reference answer() outputs")
    func answerVectors() throws {
        let cases = try #require(vectors()["answers"]?.array)
        #expect(cases.count == 9)
        for item in cases {
            let question = try DecisionReferenceVectors.question(try #require(item["question"]))
            let answer = try DecisionAnswer.answer(
                question, probabilities: try DecisionReferenceVectors.probabilities(item["probabilities"]))
            expectApproximatelyEqual(answer, try #require(item["answer"]))
        }
    }

    @Test("answer errors carry the reference messages")
    func answerErrorVectors() throws {
        let cases = try #require(vectors()["answer_errors"]?.array)
        #expect(cases.count == 5)
        for item in cases {
            let expected = try #require(item["error"]?.string)
            let probabilities = try DecisionReferenceVectors.probabilities(item["probabilities"])
            let questionJSON = try #require(item["question"])
            let question: DecisionQuestion
            if case .array(let levels)? = questionJSON["criteria"], levels.count < 2 {
                // A one-level score is refused at request time with the same
                // message, before any readout runs.
                #expect(throws: DecisionRequestError.scoreNeedsTwoLevels) {
                    try DecisionReferenceVectors.question(questionJSON)
                }
                #expect(DecisionRequestError.scoreNeedsTwoLevels.localizedDescription == expected)
                question = DecisionQuestion(instructions: nil, criteria: .score(levels))
            } else {
                question = try DecisionReferenceVectors.question(questionJSON)
            }
            do {
                _ = try DecisionAnswer.answer(question, probabilities: probabilities)
                Issue.record("expected the reference error: \(expected)")
            } catch let failure as DecisionAnswer.Failure {
                #expect(failure.localizedDescription == expected)
            }
        }
    }

    @Test("the response object has the Perplexity shape")
    func responseShape() throws {
        let response = DecisionAnswer.response(
            id: "decision-1", created: 1_760_000_000, model: "pplx-decider-v1-27b",
            answers: [.init(key: "q", value: .object([.init(key: "type", value: .string("noul")),
                                                      .init(key: "noul", value: .float(0.75))]))],
            inputTokens: 120, outputTokens: 1)
        #expect(response.compactJSON
            == #"{"id":"decision-1","object":"decision","created":1760000000,"model":"pplx-decider-v1-27b","answers":{"q":{"type":"noul","noul":0.75}},"usage":{"input_tokens":120,"output_tokens":1}}"#)
    }
}

@Suite("Decision request validation is strict and content-free")
struct DecisionRequestValidationTests {
    private func parse(_ body: String) throws -> DecisionRequest {
        try DecisionRequest.parse(Data(body.utf8))
    }

    @Test("the README routing body parses in order")
    func readmeBody() throws {
        let request = try parse(#"""
            {"model": "pplx-decider-v1-27b",
             "state": "My Stripe integration keeps failing. I'm losing sales. Please help ASAP.",
             "questions": {
               "team": {"type": "choice", "instructions": "Which team should handle this request?",
                        "criteria": {"billing": "Charges and refunds", "technical_support": "Integration errors",
                                     "sales": "Questions about buying a product"}},
               "urgent": {"type": "noul", "instructions": "Does this message express urgency?"}},
             "images": ["data:image/png;base64,AA=="]}
            """#)
        #expect(request.model == "pplx-decider-v1-27b")
        #expect(request.questions.map(\.key) == ["team", "urgent"])
        #expect(request.questions[1].question.criteria == .noul(whenFalse: nil, whenTrue: nil))
        #expect(request.images == ["data:image/png;base64,AA=="])
    }

    @Test("refusals map to fixed errors", arguments: [
        (#"[]"#, DecisionRequestError.malformedJSON),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "noul"}}, "messages": []}"#, .unknownField),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "noul"}}, "temperature": 1}"#, .unknownField),
        (#"{"model": "", "state": 1, "questions": {"q": {"type": "noul"}}}"#, .invalidModel),
        (#"{"model": "m", "questions": {"q": {"type": "noul"}}}"#, .missingState),
        (#"{"model": "m", "state": 1, "questions": {}}"#, .invalidQuestions),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "rank"}}}"#, .invalidQuestion),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "noul", "extra": 1}}}"#, .invalidQuestion),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "noul", "criteria": {"maybe": "x"}}}}"#, .invalidQuestion),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "choice", "criteria": {}}}}"#, .invalidOptionCount),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "choice", "criteria": ["a"]}}}"#, .invalidQuestion),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "score", "criteria": ["a"]}}}"#, .scoreNeedsTwoLevels),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "noul"}}, "images": "x"}"#, .invalidImages),
        (#"{"model": "m", "state": 1, "questions": {"q": {"type": "noul"}}, "images": [1]}"#, .invalidImages),
    ] as [(String, DecisionRequestError)])
    func refusals(body: String, expected: DecisionRequestError) {
        #expect(throws: expected) { try parse(body) }
    }

    @Test("question count and option count are bounded")
    func bounds() throws {
        let questions = (0 ... DecisionRequest.maximumQuestions).map { #""q\#($0)": {"type": "noul"}"# }
        #expect(throws: DecisionRequestError.tooManyQuestions) {
            try parse(#"{"model": "m", "state": 1, "questions": {\#(questions.joined(separator: ","))}}"#)
        }
        let levels = (0 ... 255).map { #""l\#($0)""# }.joined(separator: ",")
        #expect(throws: DecisionRequestError.invalidOptionCount) {
            try parse(#"{"model": "m", "state": 1, "questions": {"q": {"type": "score", "criteria": [\#(levels)]}}}"#)
        }
    }

    @Test("error messages never echo request content")
    func messagesAreFixed() {
        let errors: [DecisionRequestError] = [
            .malformedJSON, .unknownField, .invalidModel, .missingState, .invalidQuestions,
            .tooManyQuestions, .invalidQuestion, .invalidOptionCount, .scoreNeedsTwoLevels,
            .invalidImages, .inputTooLong(limit: 8192), .notADecisionModel,
            .decisionModelRequiresDecisionRequest,
        ]
        for error in errors {
            #expect(!(error.errorDescription ?? "").isEmpty)
        }
        #expect(DecisionRequestError.inputTooLong(limit: 8192).localizedDescription
            == "Question branch exceeds the 8192-token limit; no input was truncated.")
    }
}
