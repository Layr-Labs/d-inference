// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import MLXLMServer

/// How the scheduler's text path splits one request's output into reasoning,
/// text and tool calls: the channel set-up `NativeToolStreamRouter` takes.
///
/// Resolved once per request from its model, its prepared tool choice and its
/// tool parser, so the forwarder and the tests that drive it read the same
/// set-up instead of repeating the rules.
struct TextOutputRouting: Equatable, Sendable {
    /// GLM calls leave while generated (`ToolStreamPreparation.streamsGLMCalls`):
    /// the router reads their frames from the answer channel.
    let streamsGLMCalls: Bool
    /// The native channel's initial state; nil keeps the raw-text route (the
    /// tool handler first, then the downstream think parser).
    let nativeReasoningPrefix: String?
    let promotesTrailingReasoningCalls: Bool
    let preserveInnerReasoningSpans: Bool
    let nativeGemmaChannels: Bool
    let nativeMiMoChannels: Bool
    let absorbStrayThinkClose: Bool

    /// - Parameters:
    ///   - toolParser: the format of the request's tool handler, nil without one.
    ///   - jsonAnswerChannelPrefix: the channel state a constrained JSON answer
    ///     starts in (`JSONAnswerConstraint.channelPrefix`).
    ///   - reasoningPrefix: the think parser's own seed.
    ///   - promptReasoningPrefix: the prompt's think state as that parser reads it.
    ///   - promptThinkState: the think state the prompt's last tokens leave
    ///     (`ReasoningPromptProbe.streamingPrefix(forPromptTail:)`). Read only
    ///     for a family whose output is split on the native channel.
    static func resolve(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        toolParser: ToolCallFormat?,
        jsonAnswerChannelPrefix: String?,
        withholdsGLMOutput: Bool,
        glmWithholdsReasoning: Bool,
        reasoningPrefix: String?,
        promptReasoningPrefix: String?,
        promptThinkState: () -> String?
    ) -> TextOutputRouting {
        let modelContext = ChatTemplateFixContext(modelId: request.model, modelType: modelType)
        // GLM calls stream to a client that streams; the frames are read from
        // the answer channel, after its reasoning is split off.
        let streamsGLMCalls = toolParser == .glm5
            && ToolStreamPreparation.streamsGLMCalls(request: request, prepared: prepared, modelType: modelType)
        let nativeReasoningPrefix: String?
        var promotesTrailingReasoningCalls = false
        if modelType == "mimo_v2" {
            // MiMo ON/unset emits only the assistant header, not an open think
            // span. Empty initial content state keeps native splitting active
            // without fabricating prompt/seed bytes. Output permission is the
            // independently validated Boolean, never this generic probe.
            nativeReasoningPrefix = ""
        } else if let jsonAnswerChannelPrefix {
            nativeReasoningPrefix = jsonAnswerChannelPrefix
        } else if ToolChoiceEnforcementPolicy.usesNativeTextChannels(modelContext) || withholdsGLMOutput
            || glmWithholdsReasoning || streamsGLMCalls {
            nativeReasoningPrefix = promptThinkState() ?? "<think></think>"
            // An `auto` GLM call from a thought that never closed stays a
            // call, as on the raw-text route (`GLM5ToolSuffix.trailingCalls`).
            promotesTrailingReasoningCalls = streamsGLMCalls && prepared.mode == .auto
        } else if Qwen35TemplateFix.routesReasoningBeforeTools(format: toolParser,
            requiresToolCall: prepared.requiresToolCall, context: modelContext) {
            // The think parser's own seed, the prompt's think state, starts the
            // split: reasoning is classified before tool parsing, with call
            // frames found by the Qwen parser's own scanner. Without a seed, or
            // with another requested tool parser, the output keeps the raw-text
            // route.
            nativeReasoningPrefix = reasoningPrefix
            promotesTrailingReasoningCalls = true
        } else {
            nativeReasoningPrefix = QwenStrayThinkClose.nativePrefix(promptReasoningPrefix, context: modelContext)
        }
        return TextOutputRouting(
            streamsGLMCalls: streamsGLMCalls,
            nativeReasoningPrefix: nativeReasoningPrefix,
            promotesTrailingReasoningCalls: promotesTrailingReasoningCalls,
            preserveInnerReasoningSpans: ToolChoiceEnforcementPolicy.preservesInnerReasoningSpans(modelContext),
            nativeGemmaChannels: modelType == "diffusion_gemma",
            nativeMiMoChannels: modelType == "mimo_v2",
            absorbStrayThinkClose: ToolChoiceEnforcementPolicy.absorbsStrayThinkClose(modelContext))
    }
}
