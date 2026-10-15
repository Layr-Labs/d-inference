// Copyright © 2026 Eigen Labs.
//
// The Perplexity decision request body (`POST /v1/decisions`):
//
//     {"model": "...", "state": <JSON>, "questions": {"<key>": <question>},
//      "images": ["data:image/..."]}
//
// A question is `{"type": "choice"|"noul"|"score", "instructions"?: <JSON>,
// "criteria": ...}` with the reference's `autojev.types` shapes. Validation is
// strict and content-free: messages never echo keys, values or media. The
// schema is closed, so sampling, tool and chat fields are refused rather than
// ignored; a decision is always one greedy readout of the option head.

import Foundation
import MLXLMCommon

/// A content-free 400 for decision traffic. Every message is a fixed string.
enum DecisionRequestError: Error, Equatable, LocalizedError {
    case malformedJSON
    case unknownField
    case invalidModel
    case missingState
    case invalidQuestions
    case tooManyQuestions
    case invalidQuestion
    case invalidOptionCount
    case scoreNeedsTwoLevels
    case invalidImages
    case inputTooLong(limit: Int)
    case notADecisionModel
    case decisionModelRequiresDecisionRequest

    var errorDescription: String? {
        switch self {
        case .malformedJSON: "decision request body must be one JSON object"
        case .unknownField: "decision requests accept only model, state, questions and images"
        case .invalidModel: "decision request model must be a non-empty string"
        case .missingState: "decision request state is required"
        case .invalidQuestions: "decision request questions must be a non-empty object"
        case .tooManyQuestions:
            "a decision request carries at most \(DecisionRequest.maximumQuestions) questions"
        case .invalidQuestion:
            "each question needs type choice, noul or score, matching criteria and optional instructions"
        // The reference messages, verbatim.
        case .invalidOptionCount: "Questions must have 1 to 255 options, each with an answer code."
        case .scoreNeedsTwoLevels: "Score questions require at least two levels."
        case .invalidImages: "decision request images must be an array of image URL strings"
        case .inputTooLong(let limit):
            "Question branch exceeds the \(limit)-token limit; no input was truncated."
        case .notADecisionModel: "model does not serve decision requests"
        case .decisionModelRequiresDecisionRequest:
            "decision models accept only decision requests (POST /v1/decisions)"
        }
    }
}

/// One decision question with criteria in the shape its type requires.
struct DecisionQuestion: Sendable, Equatable {
    enum Criteria: Sendable, Equatable {
        /// Ordered option key → description (`null` means "key only").
        case choice([DecisionJSON.Member])
        /// Optional descriptions of the `false` and `true` options.
        case noul(whenFalse: DecisionJSON?, whenTrue: DecisionJSON?)
        /// Ordered level descriptions; level `i` is option `"i"`.
        case score([DecisionJSON])
    }

    /// Absent or `null` instructions both fall back to the default question.
    let instructions: DecisionJSON?
    let criteria: Criteria

    var type: String {
        switch criteria {
        case .choice: "choice"
        case .noul: "noul"
        case .score: "score"
        }
    }
}

struct DecisionRequest: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let key: String
        let question: DecisionQuestion
    }

    /// Bound on one request's sequential readouts (each a full prefill).
    static let maximumQuestions = 64

    let model: String
    let state: DecisionJSON
    /// Questions in request order; answers keep the same order.
    let questions: [Entry]
    /// Image URLs shared by every question, placed before the prompt text.
    let images: [String]

    /// Parse and validate a decision body. A body with `messages` is a chat
    /// body and is refused here (`unknownField`).
    static func parse(_ data: Data) throws -> DecisionRequest {
        let root: DecisionJSON
        do {
            root = try DecisionJSON.parse(data)
        } catch {
            throw DecisionRequestError.malformedJSON
        }
        guard case .object(let members) = root else { throw DecisionRequestError.malformedJSON }
        let allowed: Set<String> = ["model", "state", "questions", "images"]
        guard members.allSatisfy({ allowed.contains($0.key) }) else {
            throw DecisionRequestError.unknownField
        }
        guard case .string(let model)? = root["model"], !model.isEmpty else {
            throw DecisionRequestError.invalidModel
        }
        guard let state = root["state"] else { throw DecisionRequestError.missingState }
        guard case .object(let questionMembers)? = root["questions"], !questionMembers.isEmpty else {
            throw DecisionRequestError.invalidQuestions
        }
        guard questionMembers.count <= maximumQuestions else {
            throw DecisionRequestError.tooManyQuestions
        }
        let questions = try questionMembers.map { member in
            Entry(key: member.key, question: try parseQuestion(member.value))
        }
        return DecisionRequest(
            model: model, state: state, questions: questions, images: try parseImages(root["images"]))
    }

    private static func parseQuestion(_ value: DecisionJSON) throws -> DecisionQuestion {
        guard case .object(let members) = value,
            members.allSatisfy({ ["type", "instructions", "criteria"].contains($0.key) }),
            case .string(let type)? = value["type"]
        else { throw DecisionRequestError.invalidQuestion }
        let instructions = value["instructions"]
        let criteria = value["criteria"]
        switch type {
        case "choice":
            guard case .object(let options)? = criteria else { throw DecisionRequestError.invalidQuestion }
            guard (1 ... PplxDeciderConfiguration.maximumOptions).contains(options.count) else {
                throw DecisionRequestError.invalidOptionCount
            }
            return DecisionQuestion(instructions: instructions, criteria: .choice(options))
        case "noul":
            switch criteria {
            case nil, .null?:
                return DecisionQuestion(
                    instructions: instructions, criteria: .noul(whenFalse: nil, whenTrue: nil))
            case .object(let options)?:
                guard options.allSatisfy({ $0.key == "true" || $0.key == "false" }) else {
                    throw DecisionRequestError.invalidQuestion
                }
                return DecisionQuestion(
                    instructions: instructions,
                    criteria: .noul(whenFalse: criteria?["false"], whenTrue: criteria?["true"]))
            default:
                throw DecisionRequestError.invalidQuestion
            }
        case "score":
            guard case .array(let levels)? = criteria else { throw DecisionRequestError.invalidQuestion }
            guard (1 ... PplxDeciderConfiguration.maximumOptions).contains(levels.count) else {
                throw DecisionRequestError.invalidOptionCount
            }
            guard levels.count >= 2 else { throw DecisionRequestError.scoreNeedsTwoLevels }
            return DecisionQuestion(instructions: instructions, criteria: .score(levels))
        default:
            throw DecisionRequestError.invalidQuestion
        }
    }

    private static func parseImages(_ value: DecisionJSON?) throws -> [String] {
        guard let value else { return [] }
        guard case .array(let items) = value else { throw DecisionRequestError.invalidImages }
        return try items.map { item in
            guard case .string(let url) = item, !url.isEmpty else { throw DecisionRequestError.invalidImages }
            return url
        }
    }
}
