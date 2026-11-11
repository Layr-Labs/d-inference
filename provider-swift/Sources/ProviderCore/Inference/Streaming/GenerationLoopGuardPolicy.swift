// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Which text chat requests get a loop guard (`GenerationLoopGuard`).
///
/// On by default for the families whose answers were seen repeating verbatim
/// to their cap: Gemma 4, Qwen 3.5/3.6/3.8 (and Flash-Next), GPT-OSS,
/// Nemotron 3.5 Lightning and Super, GLM-5.3 and MiMo. Off for every other
/// family (diffusion Gemma, exact Flint, Bonsai, Qwen3-VL), for media requests
/// (only the text path passes a guard), and for any request whose output is a
/// constrained or JSON value: a token constraint, a forced tool call, or a JSON
/// `response_format`.
///
/// `DARKBLOOM_LOOP_GUARD`: unset, `1` or `on` keeps the default list; `0` or
/// `off` turns the guard off; any other value is the comma-separated list of
/// `model_type`s to guard instead.
enum GenerationLoopGuardPolicy {
    static let environmentKey = "DARKBLOOM_LOOP_GUARD"

    static let defaultModelTypes: Set<String> = [
        "gemma4", "gemma4_text",
        "qwen3_5", "qwen3_5_moe", "qwen4_exp", "qwen4_exp_text",
        "gpt_oss",
        "nemotron_h", "nemotron_h_omni",
        "glm5_next",
        "mimo_v2",
    ]

    /// Text that opens a tool call in any served family's output (Qwen, GLM,
    /// MiMo, Nemotron, Gemma 4, Harmony). The request's own parser adds its tags.
    static let genericToolCallMarkers = [
        "<tool_call>", "<|tool_call>", "<function=", "to=functions.", "<start_function_call>",
    ]

    enum Setting: Sendable, Equatable {
        case off
        case modelTypes(Set<String>)
    }

    static let current = setting(environment: ProcessInfo.processInfo.environment)

    static func setting(environment: [String: String]) -> Setting {
        .modelTypes(defaultModelTypes)
    }

    /// The guard for one text request, or nil when it must not have one.
    static func resolve(
        modelType: String?,
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        tokenConstraint: (any CBv2TokenConstraint)?,
        setting: Setting = current,
        thresholds: GenerationLoopDetector.Thresholds = .init()
    ) -> GenerationLoopGuard? {
        nil
    }
}
