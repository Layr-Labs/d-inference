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

extension MultiModelBatchSchedulerEngine {

    /// Translate an upstream `OpenAIChatCompletionRequest` into the
    /// internal `ChatCompletionRequest` that `BatchScheduler.submit`
    /// expects.
    ///
    /// Multimodal content parts are collapsed to text (image URLs are
    /// dropped) because the BatchScheduler is text-only. This matches
    /// the existing behavior of `ChatPromptFormatter`.
    ///
    /// KNOWN DEVIATION (P1 #3): `seed` is dropped on this path because
    /// the upstream `OpenAIChatCompletionRequest` does not expose a
    /// `seed` field today (see
    /// `libs/mlx-swift-lm/Libraries/MLXLMServer/Protocol/OpenAIProtocol.swift`).
    /// The legacy `ChatCompletionRequest` shape (used by some pre-
    /// MLXLMServer clients) does carry `seed`, but once it has been
    /// lifted into the upstream type the field is unreachable here.
    /// The wire-level result is that seeded reproducibility is not
    /// available in OpenAI-compatible mode and the engine's default
    /// sampler RNG is used. Tracking upstream:
    /// https://github.com/Layr-Labs/mlx-swift-lm/issues — add `seed`
    /// to `OpenAIChatCompletionRequest` and then plumb it through here.
    /// We intentionally do NOT smuggle `seed` through the OpenAI `user`
    /// field (the other free-form caller field) because we may need to
    /// repurpose `user` for cancellation / request-id correlation in
    /// the future and double-booking that field would be a layering
    /// trap.
    static func translate(
        openAIRequest request: OpenAIChatCompletionRequest,
        defaultMaxTokens: Int
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
            seed: nil, // P1 #3: see KNOWN DEVIATION on `translate(...)`.
            tools: nil,
            tool_choice: nil,
            response_format: nil,
            user: nil
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
