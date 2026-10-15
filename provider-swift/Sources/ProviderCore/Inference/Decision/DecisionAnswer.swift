// Copyright © 2026 Eigen Labs.
//
// Answer and response objects, exactly the reference `autojev.model.answer`
// and the Perplexity response shape:
//
//     noul   {"type", "noul"}
//     choice {"type", "probabilities", "choice", "confidence"}
//     score  {"type", "probabilities", "legend", "score", "confidence"}
//     response {"id", "object": "decision", "created", "model", "answers",
//               "usage": {"input_tokens", "output_tokens"}}

import Foundation

enum DecisionAnswer {
    /// The reference's `ValueError`s, with its messages. After request
    /// validation only engine output can trigger them (a provider fault).
    enum Failure: Error, Equatable, LocalizedError {
        case missingProbability
        case invalidProbabilities
        case scoreNeedsTwoLevels

        var errorDescription: String? {
            switch self {
            case .missingProbability: "Each option must have a probability."
            case .invalidProbabilities:
                "Probabilities must be finite, nonnegative, and have positive mass."
            case .scoreNeedsTwoLevels: "Score questions require at least two levels."
            }
        }
    }

    static func answer(_ question: DecisionQuestion, probabilities: [Double]) throws -> DecisionJSON {
        let options = DecisionPrompt.options(question)
        guard probabilities.count == options.keys.count, !probabilities.isEmpty else {
            throw Failure.missingProbability
        }
        guard probabilities.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            throw Failure.invalidProbabilities
        }
        let total = probabilities.reduce(0, +)
        guard total > 0 else { throw Failure.invalidProbabilities }
        let values = probabilities.map { $0 / total }
        let type = DecisionJSON.Member(key: "type", value: .string(question.type))
        if case .noul = question.criteria {
            return .object([type, .init(key: "noul", value: .float(values[1]))])
        }
        // Python `max(range(n), key=...)`: the first index of the maximum.
        var best = 0
        for index in values.indices where values[index] > values[best] { best = index }
        let distribution = DecisionJSON.Member(key: "probabilities", value: .object(
            zip(options.keys, values).map { DecisionJSON.Member(key: $0, value: .float($1)) }))
        let count = Double(values.count)
        if case .choice = question.criteria {
            let confidence = values.count == 1 ? 1.0 : (values[best] - 1 / count) / (1 - 1 / count)
            return .object([
                type, distribution,
                .init(key: "choice", value: .string(options.keys[best])),
                .init(key: "confidence", value: .float(max(0.0, min(1.0, confidence)))),
            ])
        }
        guard values.count >= 2 else { throw Failure.scoreNeedsTwoLevels }
        var distance = 0.0
        var score = 0.0
        for (index, probability) in values.enumerated() {
            distance += probability * Double(abs(index - best))
            score += Double(index) * probability
        }
        let midpoint = (count - 1) / 2
        let baseline = values.indices.reduce(0.0) { $0 + abs(Double($1) - midpoint) } / count
        return .object([
            type, distribution,
            .init(key: "legend", value: .object(
                zip(options.keys, options.descriptions).map { DecisionJSON.Member(key: $0, value: $1) })),
            .init(key: "score", value: .float(score)),
            .init(key: "confidence", value: .float(max(0.0, 1.0 - distance / baseline))),
        ])
    }

    static func response(
        id: String, created: Int, model: String, answers: [DecisionJSON.Member],
        inputTokens: Int, outputTokens: Int
    ) -> DecisionJSON {
        .object([
            .init(key: "id", value: .string(id)),
            .init(key: "object", value: .string("decision")),
            .init(key: "created", value: .integer(String(created))),
            .init(key: "model", value: .string(model)),
            .init(key: "answers", value: .object(answers)),
            .init(key: "usage", value: .object([
                .init(key: "input_tokens", value: .integer(String(inputTokens))),
                .init(key: "output_tokens", value: .integer(String(outputTokens))),
            ])),
        ])
    }
}
