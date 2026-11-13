// Copyright © 2026 Eigen Labs.
//
// Muse Glimmer's chat template renders the model's framed protocol: one
// `<|start|>role<|message|>…` message per turn part, tool calls as ATEM
// invokes, `<|eom|>` between an assistant turn's messages and `<|eot|>` at its
// end. These rules give the template the history shapes it expects.

import Foundation
import MLXLMCommon

enum MuseGlimmerTemplateFix {
    static func applies(to context: ChatTemplateFixContext) -> Bool {
        MuseGlimmerModelPolicy.isModelType(context.modelType)
    }

    /// History as the template renders it:
    /// - A replayed assistant answer or reasoning carries no protocol framing.
    /// - A tool call's arguments are a mapping, which the template requires
    ///   and raises without. Arguments that are no JSON object replay as an
    ///   empty mapping, as the reference servers render them, so one damaged
    ///   call in a conversation never makes every later turn unservable.
    /// - A `null` argument stays a value: the template writes it as `null`.
    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        messages.map { message in
            guard message["role"] as? String == "assistant" else { return sanitizeJinjaObject(message) }
            var fields = message
            let calls = fields.removeValue(forKey: "tool_calls") as? [any Sendable] ?? []
            for (key, keepsReasoning) in [("content", false), ("reasoning_content", true)] {
                if let text = fields[key] as? String {
                    fields[key] = strippingFraming(from: text, keepsReasoning: keepsReasoning)
                }
            }
            var normalized = sanitizeJinjaObject(fields)
            if !calls.isEmpty { normalized["tool_calls"] = calls.map(normalizedCall) }
            return normalized
        }
    }

    /// The answer a replayed assistant string holds once its framing is read
    /// as the model's output is: the answer channel's text, and the reasoning
    /// channel's too for a reasoning field. Text without markers is unchanged.
    static func strippingFraming(from text: String, keepsReasoning: Bool) -> String {
        guard MuseGlimmerChannelSplitter.markers.contains(where: text.contains) else { return text }
        var splitter = MuseGlimmerChannelSplitter()
        var result = ""
        for piece in splitter.parse(text) + splitter.finish() {
            switch piece {
            case .content(let part): result += part
            case .reasoning(let part): if keepsReasoning { result += part }
            case .invoke, .malformedToolFrame: break
            }
        }
        return result
    }

    /// The turn ends at `<|eot|>` or `<|end_of_text|>`. `<|eom|>` only ends
    /// one message inside a turn (reasoning before the answer, one call before
    /// the next), so it is never a stop token, whatever an artifact declares.
    static func stopTokenIds(base: Set<Int>, tokenToId: (String) -> Int?) -> Set<Int> {
        var ids = base.union([MuseGlimmerChannelSplitter.endOfTurn, MuseGlimmerChannelSplitter.endOfText]
            .compactMap(tokenToId))
        if let endOfMessage = tokenToId(MuseGlimmerChannelSplitter.endOfMessage) {
            ids.remove(endOfMessage)
        }
        return ids
    }

    /// Client stop strings end the answer: they match on the answer channel,
    /// never in reasoning, a header or a tool call.
    static let answerStopScope = CBv2StopStringScope(
        opener: "to=user", openerEnd: MuseGlimmerChannelSplitter.message,
        closers: [MuseGlimmerChannelSplitter.endOfMessage, MuseGlimmerChannelSplitter.endOfTurn,
                  MuseGlimmerChannelSplitter.start])

    private static func normalizedCall(_ value: any Sendable) -> any Sendable {
        guard var call = value as? [String: any Sendable] else { return value }
        var function = call.removeValue(forKey: "function") as? [String: any Sendable] ?? [:]
        let arguments = function.removeValue(forKey: "arguments") as? [String: any Sendable] ?? [:]
        function = sanitizeJinjaObject(function)
        // The null-preserving bridge Flint's replay uses.
        function["arguments"] = FlintTemplateNormalization.object(arguments)
        call = sanitizeJinjaObject(call)
        call["function"] = function
        return call
    }
}
