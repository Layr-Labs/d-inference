// Copyright © 2026 Eigen Labs.
//
// Qwen 3.5/3.6's published chat template accepts a system message only at
// messages[0]. OpenAI-compatible clients may legally append later system turns
// to a conversation history. Fold those turns into one leading system message
// before Jinja rendering instead of letting the template throw a deterministic
// "System message must be at the beginning" error.

import Foundation
import MLXLMServer

enum Qwen35TemplateFix {
    static func applies(to context: ChatTemplateFixContext) -> Bool {
        if let modelType = context.modelType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            modelType == "qwen3_5_moe"
        {
            return true
        }

        guard let modelId = context.modelId?.lowercased() else { return false }
        return modelId.contains("qwen3.5")
            || modelId.contains("qwen3_5")
            || modelId.contains("qwen3.6")
            || modelId.contains("qwen3_6")
    }

    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        let systemIndices = messages.indices.filter {
            (messages[$0]["role"] as? String) == "system"
        }
        guard let firstSystemIndex = systemIndices.first else { return messages }
        guard systemIndices.count > 1 || firstSystemIndex != messages.startIndex else {
            return messages
        }

        let nonSystemMessages = messages.filter {
            ($0["role"] as? String) != "system"
        }
        if systemIndices.count == 1 {
            return [messages[firstSystemIndex]] + nonSystemMessages
        }

        let systemMessages = systemIndices.map { messages[$0] }
        var systemTexts: [String] = []
        systemTexts.reserveCapacity(systemMessages.count)
        for message in systemMessages {
            guard let text = systemTextContent(message["content"]) else {
                // Images, video, and unknown structured content are not safe to
                // move into Qwen's leading system slot. Preserve the template's
                // deterministic rejection instead of changing their semantics.
                return messages
            }
            if !text.isEmpty { systemTexts.append(text) }
        }

        var mergedSystem = systemMessages[0]
        mergedSystem["content"] = systemTexts.joined(separator: "\n\n")
        return [mergedSystem] + nonSystemMessages
    }

    /// Typed counterpart used by the multimodal path before `UserInput`
    /// construction. It preserves user image/video parts byte-for-byte while
    /// enforcing the same leading-system invariant as the dictionary/Jinja path.
    static func normalizeMessages(
        _ messages: [OpenAIChatMessage]
    ) -> [OpenAIChatMessage] {
        let systemIndices = messages.indices.filter {
            messages[$0].role == .system
        }
        guard let firstSystemIndex = systemIndices.first else { return messages }
        guard systemIndices.count > 1 || firstSystemIndex != messages.startIndex else {
            return messages
        }

        let nonSystemMessages = messages.filter { $0.role != .system }
        if systemIndices.count == 1 {
            return [messages[firstSystemIndex]] + nonSystemMessages
        }

        let systemMessages = systemIndices.map { messages[$0] }
        var systemTexts: [String] = []
        systemTexts.reserveCapacity(systemMessages.count)
        for message in systemMessages {
            guard let text = systemTextContent(message.content) else {
                return messages
            }
            if !text.isEmpty { systemTexts.append(text) }
        }

        var mergedSystem = systemMessages[0]
        mergedSystem.content = .text(systemTexts.joined(separator: "\n\n"))
        return [mergedSystem] + nonSystemMessages
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

    private static func systemTextContent(_ content: (any Sendable)?) -> String? {
        guard let content else { return "" }
        if let text = content as? String { return text }
        guard let parts = content as? [any Sendable] else { return nil }

        var text = ""
        for part in parts {
            guard let object = part as? [String: any Sendable],
                  object["image"] == nil,
                  object["image_url"] == nil,
                  object["video"] == nil,
                  object["video_url"] == nil,
                  let partText = object["text"] as? String
            else {
                return nil
            }
            text += partText
        }
        return text
    }
}
