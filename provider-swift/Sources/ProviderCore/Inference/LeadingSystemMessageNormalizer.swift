// Copyright © 2026 Eigen Labs.
//
// Some published chat templates accept a system message only in the first
// position. OpenAI-compatible clients may legally insert system messages later
// in a conversation, so affected model adapters fold all text-only system
// turns into one leading instruction before rendering.

import Foundation

enum LeadingSystemMessageNormalizer {
    static func normalize(
        _ messages: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        normalize(
            messages,
            isSystem: { ($0["role"] as? String) == "system" },
            textContent: { textContent($0["content"]) },
            replacingContent: { message, text in
                var message = message
                message["content"] = text
                return message
            })
    }

    /// Fold either typed or dictionary messages without converting the other
    /// turns. Keep the first system message's metadata and abandon a multi-turn
    /// fold if any system content cannot be represented as text.
    static func normalize<Message>(
        _ messages: [Message],
        isSystem: (Message) -> Bool,
        textContent: (Message) -> String?,
        replacingContent: (Message, String) -> Message
    ) -> [Message] {
        let systemIndices = messages.indices.filter { isSystem(messages[$0]) }
        guard let firstSystemIndex = systemIndices.first else { return messages }
        guard systemIndices.count > 1 || firstSystemIndex != messages.startIndex else {
            return messages
        }

        let nonSystemMessages = messages.filter { !isSystem($0) }
        if systemIndices.count == 1 {
            return [messages[firstSystemIndex]] + nonSystemMessages
        }

        var systemTexts: [String] = []
        systemTexts.reserveCapacity(systemIndices.count)
        for index in systemIndices {
            guard let text = textContent(messages[index]) else { return messages }
            if !text.isEmpty { systemTexts.append(text) }
        }
        let merged = replacingContent(messages[firstSystemIndex], systemTexts.joined(separator: "\n\n"))
        return [merged] + nonSystemMessages
    }

    private static func textContent(_ content: (any Sendable)?) -> String? {
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
