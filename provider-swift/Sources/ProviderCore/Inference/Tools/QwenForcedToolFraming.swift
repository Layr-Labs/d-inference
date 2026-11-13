// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Red stub: the API the framing tests read, with today's behavior (no framing).
enum QwenForcedToolFraming {
    static let environmentKey = "DARKBLOOM_QWEN_FORCED_TOOL_FRAMING"

    static func isEnabled(environment: [String: String]) -> Bool { true }

    static func appliesToStream(prepared: ToolChoicePromptPolicy.Prepared, parser: ToolCallFormat?) -> Bool { false }

    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        tokenizer: TokenizerHandle,
        maxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        enabled: Bool = true
    ) -> Qwen4NativeToolConstraint? { nil }
}
