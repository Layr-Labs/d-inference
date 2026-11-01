// Copyright © 2026 Eigen Labs.
//
// Qwen 3.5/3.6's published chat template accepts a system message only at
// messages[0]. OpenAI-compatible clients may legally append later system turns
// to a conversation history. Fold those turns into one leading system message
// before Jinja rendering instead of letting the template throw a deterministic
// "System message must be at the beginning" error.
//
// Qwen3-VL (qwen3_vl_moe / qwen3_vl) shares that template contract: its
// system role is consumed only at messages[0], so a mid-conversation system
// turn is silently DROPPED from the rendered prompt — multi-system
// conversations lose the later instruction entirely (the OpenRouter
// multi-system failure) rather than erroring. The same leading-system fold
// fixes both families.

import Foundation
import MLXLMServer

enum Qwen35TemplateFix {
    static func applies(to context: ChatTemplateFixContext) -> Bool {
        if let modelType = context.modelType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            modelType == "qwen3_5" || modelType == "qwen3_5_moe"
                || modelType == "qwen3_vl_moe"
                || modelType == "prism_hadamard_qwen35"
        {
            return true
        }

        guard let modelId = context.modelId?.lowercased() else { return false }
        return modelId.contains("qwen3.5")
            || modelId.contains("qwen3_5")
            || modelId.contains("qwen3.6")
            || modelId.contains("qwen3_6")
            || modelId.contains("qwen3.8")
            || modelId.contains("qwen3_8")
            || modelId.contains("qwen3-vl")
            || modelId.contains("qwen3_vl")
    }

    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        LeadingSystemMessageNormalizer.normalize(messages)
    }

    /// Qwen 3.5/3.6/3.8 and Bonsai 2 templates raise "No user query found in
    /// messages." unless a user turn is more than a `<tool_response>` wrapper.
    /// Reject that history as a typed 400, not a provider 500. Gated by
    /// `model_type`: Qwen3-VL matches `applies(to:)` but not the raise.
    static func validateUserQuery(
        _ messages: [[String: any Sendable]], context: ChatTemplateFixContext
    ) throws {
        guard ["qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35"].contains(context.modelType ?? "")
        else { return }
        let hasQuery = messages.contains { message in
            guard message["role"] as? String == "user" else { return false }
            let text = (message["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return !(text.hasPrefix("<tool_response>") && text.hasSuffix("</tool_response>"))
        }
        if !hasQuery { throw MultiModelBatchSchedulerEngineError.missingUserQuery }
    }

    /// Typed counterpart used by the multimodal path before `UserInput`
    /// construction. It preserves user image/video parts byte-for-byte while
    /// enforcing the same leading-system invariant as the dictionary/Jinja path.
    static func normalizeMessages(
        _ messages: [OpenAIChatMessage]
    ) -> [OpenAIChatMessage] {
        LeadingSystemMessageNormalizer.normalize(
            messages,
            isSystem: { $0.role == .system },
            textContent: { systemTextContent($0.content) },
            replacingContent: { message, text in
                var message = message
                message.content = .text(text)
                return message
            })
    }

    private static func systemTextContent(_ content: OpenAIMessageContent) -> String? {
        switch content {
        case .text(let text):
            return text
        case .null:
            return ""
        case .parts(let parts):
            var text = ""
            for part in parts {
                guard case .text(let partText) = part else { return nil }
                text += partText
            }
            return text
        }
    }
}
