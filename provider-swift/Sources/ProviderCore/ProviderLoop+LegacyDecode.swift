// Inbound chat-request decoding. Accepts the upstream OpenAI shape
// first, with a fallback to the legacy `ChatCompletionRequest` payload
// for pre-MLXLMServer consumers. Split out of `ProviderLoop.swift`
// because the legacy lift is a self-contained mapping with its own
// well-defined error contract (P2 #5 — invalid roles).

import Foundation
import MLXLMServer

extension ProviderLoop {

    /// Decode an inbound chat request. Tries the upstream
    /// `OpenAIChatCompletionRequest` first; on failure, falls back to
    /// the legacy `ChatCompletionRequest` shape and lifts it. The two
    /// share JSON keys on the common path, so the fallback is rare.
    internal static func decodeOpenAIRequest(
        _ data: Data
    ) throws -> OpenAIChatCompletionRequest {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(OpenAIChatCompletionRequest.self, from: data)
        } catch {
            let legacy = try decoder.decode(ChatCompletionRequest.self, from: data)
            return try liftLegacyRequest(legacy)
        }
    }

    /// Lift the legacy `ChatCompletionRequest` into the upstream type
    /// so the rest of the pipeline only deals with one shape.
    ///
    /// P2 #5: an unrecognised role (anything outside
    /// `system`/`user`/`assistant`/`tool`) now throws
    /// `MultiModelBatchSchedulerEngineError.invalidRole(role)` instead
    /// of being silently coerced to `.user`. Silent coercion changed
    /// prompt semantics for tool/developer-shaped roles and produced
    /// materially different model outputs; throwing surfaces it as 400
    /// so the caller can fix the role rather than debug a behavioural
    /// drift downstream.
    internal static func liftLegacyRequest(
        _ legacy: ChatCompletionRequest
    ) throws -> OpenAIChatCompletionRequest {
        let messages = try legacy.messages.map { msg -> OpenAIChatMessage in
            guard let role = OpenAIRole(rawValue: msg.role) else {
                throw MultiModelBatchSchedulerEngineError.invalidRole(msg.role)
            }
            return OpenAIChatMessage(role: role, content: .text(msg.content))
        }
        return OpenAIChatCompletionRequest(
            model: legacy.model,
            messages: messages,
            stream: legacy.stream,
            temperature: legacy.temperature,
            topP: legacy.top_p,
            topK: legacy.top_k,
            maxTokens: legacy.max_tokens,
            presencePenalty: legacy.presence_penalty,
            frequencyPenalty: legacy.frequency_penalty,
            repetitionPenalty: legacy.repetition_penalty,
            stop: legacy.stop?.asArray
        )
    }
}
