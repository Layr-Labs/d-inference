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
            guard let text = textContent(message["content"]) else {
                // Moving structured media into a text-only template slot would
                // change request semantics. Leave it untouched so the model's
                // existing validation remains authoritative.
                return messages
            }
            if !text.isEmpty {
                systemTexts.append(text)
            }
        }

        var mergedSystem = systemMessages[0]
        mergedSystem["content"] = systemTexts.joined(separator: "\n\n")
        return [mergedSystem] + nonSystemMessages
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
