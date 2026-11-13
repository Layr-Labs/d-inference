// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Grammar-constrained JSON `response_format` answers on Gemma 4: the API only
/// (red). Every request keeps prompt-only steering.
enum GemmaJSONAnswerPolicy {
    static let environmentKey = "DARKBLOOM_GEMMA_JSON_ANSWERS"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    static func isEnabled(_ value: String?) -> Bool { true }

    static func constraint(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        enabled: Bool = enabled
    ) -> GemmaJSONAnswerConstraint? { nil }

    static func initialPhase(promptTail tail: String) -> GemmaJSONAnswerBoundary.Phase? { nil }

    static func answerFormat(_ format: OpenAIResponseFormat) -> JSONAnswerFormat? { nil }
}

extension EngineV2Bridge {
    static func admittedConstraint(_ constraint: (any CBv2TokenConstraint)?, servesDistributedPair: Bool,
                                   tracksNativeShutdown: Bool) -> (any CBv2TokenConstraint)? {
        constraint
    }
}
