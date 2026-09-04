// Copyright © 2026 Eigen Labs.
//
// OpenAI ⇄ internal `ChatCompletionRequest` translation, plus the
// dict-shape renderer that feeds `MLXLMCommon.Tokenizer.applyChatTemplate`.
//
// Split out of `MultiModelBatchSchedulerEngine.swift` because the
// shape mapping is mechanical and benefits from being navigable in
// isolation when adding new OpenAI fields (e.g. a future `seed`
// plumbing fix — see the KNOWN DEVIATION comment below).

import Foundation
import MLXLMCommon
import MLXLMServer

/// Template-only controls recovered from the sealed OpenAI body. They remain
/// out-of-band because the upstream request type does not model the top-level
/// Qwen3.8 fields. `enableThinking` is already resolved across top-level and
/// `chat_template_kwargs`; the typed request's nested `reasoning.enabled`
/// remains authoritative when the template context is built.
public struct ChatTemplateControls: Sendable, Equatable {
    public let reasoningEffort: String?
    public let enableThinking: Bool?
    public let preserveThinking: Bool?

    public init(
        reasoningEffort: String? = nil,
        enableThinking: Bool? = nil,
        preserveThinking: Bool? = nil
    ) {
        self.reasoningEffort = reasoningEffort
        self.enableThinking = enableThinking
        self.preserveThinking = preserveThinking
    }

    var effortDisablesThinking: Bool {
        guard let value = reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return ["none", "off", "0"].contains(value)
    }

    var hasExplicitThinkingControl: Bool {
        enableThinking != nil || reasoningEffort != nil
    }
}

extension MultiModelBatchSchedulerEngine {

    static func templateAdditionalContext(
        for request: OpenAIChatCompletionRequest,
        controls: ChatTemplateControls,
        modelType: String? = nil,
        hasMedia: Bool = false,
        requiresToolCall: Bool = false
    ) -> [String: any Sendable]? {
        var context: [String: any Sendable] = [:]
        let fixContext = ChatTemplateFixContext(
            modelId: request.model,
            modelType: modelType)
        if let effectiveEffort = GPTOSSHarmonyTemplateFix.effectiveReasoningEffort(
            controls.reasoningEffort,
            context: fixContext)
        {
            context["reasoning_effort"] = effectiveEffort
        }

        // Reviewed precedence: the typed nested control wins over both raw-body
        // aliases; explicit booleans win over effort shorthands; only the exact
        // none/off/0 spellings disable through reasoning_effort. `minimal` is
        // preserved as an effort value and intentionally is not rewritten to
        // false.
        if requiresToolCall && Qwen35TemplateFix.applies(to: fixContext) {
            // Qwen's XML tool parser treats reasoning before <tool_call> as
            // visible prose. Required/named tool_choice cannot expose prose,
            // so the forced-tool contract takes precedence over thinking
            // controls and renders a tool-only prompt.
            context["enable_thinking"] = false
        } else if let nested = request.reasoning?.enabled {
            context["enable_thinking"] = nested
        } else if let explicit = controls.enableThinking {
            context["enable_thinking"] = explicit
        } else if controls.effortDisablesThinking {
            context["enable_thinking"] = false
        } else if hasMedia && !controls.hasExplicitThinkingControl {
            // Qwen templates default thinking on. Grounded media defaults off
            // only when the caller supplied no thinking control at all.
            context["enable_thinking"] = false
        }
        if let preserveThinking = controls.preserveThinking {
            context["preserve_thinking"] = preserveThinking
        }
        return context.isEmpty ? nil : context
    }

    /// Translate an upstream `OpenAIChatCompletionRequest` into the
    /// internal `ChatCompletionRequest` submitted through EngineV2.
    ///
    /// This text translator collapses multimodal parts; production media
    /// requests are intercepted and prepared before reaching it.
    ///
    /// KNOWN DEVIATION (P1 #3, narrowed): the upstream
    /// `OpenAIChatCompletionRequest` does not expose `seed` or `logit_bias`
    /// fields today (see
    /// `libs/mlx-swift-lm/Libraries/MLXLMServer/Protocol/OpenAIProtocol.swift`),
    /// so a translation from the upstream shape ALONE always yields
    /// `seed == nil` / `logit_bias == nil`. On the coordinator serving path
    /// they are recovered the same way `logprobs`/`top_logprobs` are: decoded
    /// straight from the sealed body
    /// (`ProviderLoop.extractSamplingOverrides`) and overlaid here via the
    /// `logitBias`/`seed` parameters. The standalone
    /// `--local` path still drops both — it decodes inside the upstream
    /// Hummingbird router with no provider seam — pending the upstream shape
    /// gaining the fields.
    /// We intentionally do NOT smuggle `seed` through the OpenAI `user`
    /// field (the other free-form caller field) because we may need to
    /// repurpose `user` for cancellation / request-id correlation in
    /// the future and double-booking that field would be a layering
    /// trap.
    /// `logprobs`/`topLogprobs` overlay the OpenAI knobs of the same names
    /// onto the internal shape; on the coordinator path they arrive via
    /// `EngineV2LogprobsPlumbing`.
    static func translate(
        openAIRequest request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int,
        logprobs: Bool? = nil,
        topLogprobs: Int? = nil,
        logitBias: [String: Float]? = nil,
        seed: UInt64? = nil
    ) -> ChatCompletionRequest {
        let stop: StopSequences? = {
            guard let stops = request.stop, !stops.isEmpty else { return nil }
            return .multiple(stops)
        }()
        return ChatCompletionRequest(
            model: request.model,
            messages: request.messages.map { msg in
                ChatMessage(role: msg.role.rawValue, content: msg.content.text)
            },
            temperature: request.temperature,
            top_p: request.topP,
            top_k: request.topK,
            max_tokens: request.maxTokens,
            repetition_penalty: request.repetitionPenalty,
            presence_penalty: request.presencePenalty,
            frequency_penalty: request.frequencyPenalty,
            stream: request.stream,
            stop: stop,
            // Sealed-body overlay (nil unless the coordinator handler decoded
            // one) — see KNOWN DEVIATION on `translate(...)`.
            seed: seed,
            tools: nil,
            tool_choice: nil,
            response_format: nil,
            user: nil,
            logit_bias: logitBias,
            logprobs: logprobs,
            top_logprobs: topLogprobs,
            min_p: request.minP
        )
    }
}

extension OpenAIChatMessage {
    /// Render this message in the dict shape expected by
    /// ``MLXLMCommon.Tokenizer/applyChatTemplate(messages:tools:additionalContext:)``.
    /// Mirrors the helper used by ``MLXBatchedEngineServerEngine`` so the
    /// chat template sees the same fields regardless of which path the
    /// request takes.
    func templateMessageDict() -> [String: any Sendable] {
        var entry: [String: any Sendable] = [
            "role": role.rawValue,
            "content": textContent,
        ]
        if let name { entry["name"] = name }
        if let toolCallID { entry["tool_call_id"] = toolCallID }
        if let toolCalls, !toolCalls.isEmpty {
            entry["tool_calls"] = toolCalls.map { call -> [String: any Sendable] in
                [
                    "id": call.id,
                    "type": call.type,
                    "function": [
                        "name": call.function.name,
                        // Decode to an object so the chat template renders tool calls correctly (#249).
                        "arguments": decodeToolCallArguments(call.function.arguments),
                    ] as [String: any Sendable],
                ]
            }
        }
        if let reasoningContent { entry["reasoning_content"] = reasoningContent }
        return entry
    }
}
