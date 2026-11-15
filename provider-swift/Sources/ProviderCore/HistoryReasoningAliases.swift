// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// A history message's reasoning sent under another name than
/// `reasoning_content`, the only one the upstream decoder reads. OpenRouter
/// returns a turn's thought as `reasoning` and clients echo the message back
/// as received; others send `thinking`. transformers fills `reasoning_content`
/// from the first non-null of `reasoning_content`, `thinking` and `reasoning`
/// before it renders a chat template, so a template that replays past
/// thoughts shows the echoed one instead of an empty block.
///
/// Read from the same JSON document as the request; every inbound repair
/// keeps the messages and their order.
struct HistoryReasoningAliases {
    /// One entry per message: its aliased reasoning, or nil.
    private let aliases: [String?]

    init(decoder: any Decoder) {
        let messages = try? decoder.container(keyedBy: RootKey.self)
            .decode([Message].self, forKey: .messages)
        aliases = messages?.map(\.reasoning) ?? []
    }

    /// Fills `reasoningContent` only where the message sent none of its own.
    func apply(to messages: inout [OpenAIChatMessage]) {
        for (index, alias) in zip(messages.indices, aliases)
        where alias != nil && messages[index].reasoningContent == nil {
            messages[index].reasoningContent = alias
        }
    }

    private enum RootKey: String, CodingKey { case messages }

    private struct Message: Decodable {
        let reasoning: String?

        init(from decoder: any Decoder) {
            reasoning = Self.alias(in: try? decoder.container(keyedBy: Key.self))
        }

        /// The first non-null spelling wins, as in transformers. One the
        /// templates cannot render (not a string, or empty) aliases nothing.
        private static func alias(in values: KeyedDecodingContainer<Key>?) -> String? {
            guard let values else { return nil }
            for key in Key.allCases where values.contains(key) && (try? values.decodeNil(forKey: key)) == false {
                guard key != .reasoningContent,
                    let text = try? values.decode(String.self, forKey: key), !text.isEmpty
                else { return nil }
                return text
            }
            return nil
        }

        private enum Key: String, CodingKey, CaseIterable {
            case reasoningContent = "reasoning_content"
            case thinking
            case reasoning
        }
    }
}

/// The upstream request with `HistoryReasoningAliases` applied, from one parse.
struct AliasedChatRequest: Decodable {
    let request: OpenAIChatCompletionRequest

    init(from decoder: any Decoder) throws {
        var request = try OpenAIChatCompletionRequest(from: decoder)
        HistoryReasoningAliases(decoder: decoder).apply(to: &request.messages)
        self.request = request
    }
}
