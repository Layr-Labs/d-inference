import Foundation
import MLXLMServer

/// The Qwen types take the native splitter's existing close-marker handling,
/// on by default. An off word in `DARKBLOOM_QWEN_ABSORB_STRAY_THINK_CLOSE`
/// (`off`, `false`, `0`, `none`, `no` or `disabled`, in any case, surrounding
/// space ignored) is the kill switch: the close stays literal, as in 0.10.12.
enum QwenStrayThinkClose {
    static let environmentKey = "DARKBLOOM_QWEN_ABSORB_STRAY_THINK_CLOSE"
    /// Qwen3-VL (`qwen3_vl`, `qwen3_vl_moe`) keeps its existing route: its
    /// Instruct builds never reason, and `qwen3_vl_moe`'s bare prompt tail gets
    /// a synthetic content seed (`ReasoningPromptProbe.plainTailContentModelTypes`),
    /// not a thought the template closed, so there is no stray close to absorb.
    static let modelTypes: Set<String> = [
        "qwen3", "qwen3_moe", "qwen3_next",
        "qwen3_5", "qwen3_5_moe", "qwen4_exp", "qwen4_exp_text",
    ]

    static func applies(_ context: ChatTemplateFixContext,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let type = context.modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            modelTypes.contains(type) else { return false }
        return enabled(environment[environmentKey])
    }

    static func enabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "false", "0", "none", "no", "disabled"].contains(value)
    }

    /// A missing/disabled reasoning parser stays untouched. Only a prompt
    /// already classified as thinking-off may opt a plain stream into native
    /// splitting; never guess the state of a close-only reasoning model.
    static func nativePrefix(_ prefix: String?, context: ChatTemplateFixContext) -> String? {
        prefix == "<think></think>" && applies(context) ? prefix : nil
    }

    /// Legacy media leaves calls for the downstream parser. When a closed
    /// Qwen prompt opts into native splitting, move its parser alongside the
    /// splitter so literal markers in arguments stay protected. Unknown or
    /// open thought state retains the existing media route.
    static func mediaToolHandler(existing: BatchedToolStreamHandler?, prefix: String?,
        request: OpenAIChatCompletionRequest, prepared: ToolChoicePromptPolicy.Prepared,
        context: ChatTemplateFixContext) throws -> BatchedToolStreamHandler? {
        guard existing == nil, nativePrefix(prefix, context: context) != nil else { return existing }
        return try ToolStreamPreparation.makeHandler(request: request, prepared: prepared,
            modelType: context.modelType)
    }

}
