// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Grammar-constrained arguments for `strict` tool calls on the Qwen
/// 3.5-family text route. The API only: no request is constrained yet.
enum QwenStrictToolGrammar {
    static let environmentKey = "DARKBLOOM_STRICT_TOOL_GRAMMAR"
    static let allToolsEnvironmentKey = "DARKBLOOM_STRICT_TOOL_GRAMMAR_ALL_TOOLS"

    enum Setting: Sendable, Equatable {
        case off
        case models(Set<String>)
    }

    static func setting(environment: [String: String]) -> Setting { .off }
    static func allTools(environment: [String: String]) -> Bool { false }
    static func isEnabled(modelId: String, modelType: String?, setting: Setting) -> Bool { false }

    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        parser: ToolCallFormat?,
        tokenizer: TokenizerHandle,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        runsTokenConstraints: Bool,
        setting: Setting,
        allTools: Bool
    ) -> QwenStrictToolConstraint? {
        nil
    }
}
