// Copyright © 2026 Eigen Labs.
//
// A decision head emits option logits, not vocabulary logits: chat on a
// decision model would sample head rows as token ids, and a decision on any
// other model would read vocabulary logits as options. The loaded slot's
// `model_type` (never a caller-supplied name) selects exactly one path.

import Foundation

enum DecisionServingGate {
    /// Refuse a chat request to a decision model, or a decision to any other.
    static func validate(modelType: String?, servesDecision: Bool) throws {
        let decisionModel = EngineV2SupportedModels.isPplxDeciderModelType(modelType)
        if decisionModel, !servesDecision {
            throw DecisionRequestError.decisionModelRequiresDecisionRequest
        }
        if !decisionModel, servesDecision {
            throw DecisionRequestError.notADecisionModel
        }
    }

    /// The pack's `max_input_tokens`, checked on the exact tokenized prompt
    /// (image tokens included) before engine admission. Nothing is truncated.
    static func checkInputTokens(_ promptTokens: Int, limit: Int?) throws {
        guard let limit, promptTokens > limit else { return }
        throw DecisionRequestError.inputTooLong(limit: limit)
    }
}
