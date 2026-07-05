// Copyright © 2026 Eigen Labs.

import Foundation

/// Strip raw Harmony channel framing from replayed assistant content.
///
/// Harmony templates intentionally reject assistant `content` / `thinking`
/// values that still contain raw control-channel tags such as
/// `<|channel|>analysis<|message|>...<|end|>` and
/// `<|channel|>final<|message|>...`. At inference time, prior assistant
/// turns are replay context only: the template drops analysis / chain-of-
/// thought and renders the previous final answer. Normalize inbound replayed
/// assistant strings to that contract before Jinja sees them.
///
/// The transform is conservative: strings without Harmony channel tags are
/// returned unchanged, preserving ordinary assistant text byte-for-byte.
///
/// - Parameter text: a string value from an assistant message field.
/// - Returns: the final-answer text with Harmony control framing removed, or
///   an empty string for analysis-only channel-framed content.
public func stripHarmonyChannelFraming(fromAssistantContent text: String) -> String {
    let channelToken = "<|channel|>"
    guard text.contains(channelToken) else { return text }

    let finalMarker = "<|channel|>final<|message|>"
    let terminators = ["<|end|>", "<|return|>", "<|call|>"]
    let controlTokens = [
        "<|start|>",
        "<|end|>",
        "<|return|>",
        "<|call|>",
        "<|message|>",
        channelToken,
    ]

    var answer = ""
    if let finalRange = text.range(of: finalMarker, options: .backwards) {
        let afterFinal = text[finalRange.upperBound...]
        var firstTerminator: Range<String.Index>?
        for terminator in terminators {
            guard let range = afterFinal.range(of: terminator) else { continue }
            if firstTerminator == nil || range.lowerBound < firstTerminator!.lowerBound {
                firstTerminator = range
            }
        }

        if let firstTerminator {
            answer = String(afterFinal[..<firstTerminator.lowerBound])
        } else {
            answer = String(afterFinal)
        }
    }

    if controlTokens.contains(where: { answer.contains($0) }) {
        for token in controlTokens {
            answer = answer.replacingOccurrences(of: token, with: "")
        }
    }
    return answer
}

/// Assistant message text fields that may carry Harmony control-channel framing
/// in replayed turns. Centralized so every tokenize chokepoint strips the same
/// set (the OpenAI `content`, plus the reasoning aliases some clients replay).
public let harmonyAssistantTextFields: [String] = ["content", "thinking", "reasoning_content"]

/// Strip Harmony channel framing from an assistant message's text fields.
///
/// Operates on the `[String: Any]` chat-template message shape used by
/// `MLXLMCommon.Tokenizer.applyChatTemplate` and the scan-time render
/// self-check. Non-assistant messages and non-string field values pass through
/// unchanged. The string transform (``stripHarmonyChannelFraming(fromAssistantContent:)``)
/// remains the single source of truth; this only handles role/key selection.
public func stripHarmonyFramingFromAssistantMessage(_ message: [String: Any]) -> [String: Any] {
    guard (message["role"] as? String) == "assistant" else { return message }

    var output = message
    for key in harmonyAssistantTextFields {
        if let text = output[key] as? String {
            output[key] = stripHarmonyChannelFraming(fromAssistantContent: text)
        }
    }
    return output
}
