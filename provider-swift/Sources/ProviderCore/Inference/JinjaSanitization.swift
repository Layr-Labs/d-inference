// Copyright © 2026 Eigen Labs.
//
// Chat-template-shaped adapters over the recursive Jinja sanitizer
// (`sanitizeForJinja`, defined in ProviderCoreFoundation).
//
// These wrap the `messages: [[String: any Sendable]]` /
// `tools: [[String: any Sendable]]?` shapes that
// `MLXLMCommon.Tokenizer.applyChatTemplate(messages:tools:additionalContext:)`
// consumes, and are applied at every provider chokepoint that builds a
// chat-template context from an inbound OpenAI request:
//
//   • `MultiModelBatchSchedulerEngine.streamChatCompletion` (the OpenAI
//     production inference path),
//   • `MultiModelBatchSchedulerEngine.applyTemplate` (the `/apply-template`
//     utility endpoint),
//   • `ProviderLoop.promptTokenFloor` (the prompt-token recount for usage
//     chunks that never arrived).
//
// See `ProviderCoreFoundation/JinjaSanitization.swift` for the root cause
// and the recursive null/Optional-stripping policy. The core
// lives in the lower target so the scan-time render self-check
// (`TemplateRenderCheck`) shares the exact same normalization.

import Foundation
import ProviderCoreFoundation

/// Sanitize a single chat-template object (one message or one tool spec),
/// dropping null / `Optional` leaves and re-typing the result back into the
/// `[String: any Sendable]` shape `applyChatTemplate` requires.
///
/// `sanitizeForJinja` returns `Any?` (it cannot produce `any Sendable`
/// directly — `Sendable` is a marker protocol). The `as?` here re-wraps the
/// already-`Sendable` values without reconstructing them, so dynamic leaf
/// types — and thus Jinja's rendering — are unchanged. A non-dictionary
/// result is impossible for a dictionary input, but we fall back to an
/// empty object rather than trap.
func sanitizeJinjaObject(
    _ object: [String: any Sendable]
) -> [String: any Sendable] {
    sanitizeForJinja(object) as? [String: any Sendable] ?? [:]
}

/// Sanitize a chat-template `messages` array: strip raw Harmony channel tags
/// from assistant string fields, then drop null / `Optional` leaves from each
/// message dictionary (e.g. a `null` value inside an assistant tool call's
/// decoded `arguments`). Behavior-preserving for messages that carry neither
/// null leaves nor Harmony channel framing.
func sanitizeJinjaMessages(
    _ messages: [[String: any Sendable]]
) -> [[String: any Sendable]] {
    messages.map { sanitizeJinjaObject(stripHarmonyFramingFromMessage($0)) }
}

/// Strip raw Harmony channel framing from assistant string fields before the
/// null sanitizer runs. Non-assistant messages and non-string values (for
/// example multimodal content arrays) pass through unchanged.
private func stripHarmonyFramingFromMessage(
    _ message: [String: any Sendable]
) -> [String: any Sendable] {
    guard (message["role"] as? String) == "assistant" else { return message }

    var output = message
    for key in ["content", "thinking", "reasoning_content"] {
        if let text = output[key] as? String {
            output[key] = stripHarmonyChannelFraming(fromAssistantContent: text)
        }
    }
    return output
}

/// Sanitize a chat-template `tools` array (or `nil`), dropping null /
/// `Optional` leaves from each tool spec (e.g. `"default": null`,
/// `"const": null`, or a `null` enum element inside a `function.parameters`
/// JSON schema). `nil` in ⇒ `nil` out, so the render context still omits
/// the `tools` key entirely for tool-less requests.
func sanitizeJinjaTools(
    _ tools: [[String: any Sendable]]?
) -> [[String: any Sendable]]? {
    guard let tools else { return nil }
    return tools.map(sanitizeJinjaObject)
}
