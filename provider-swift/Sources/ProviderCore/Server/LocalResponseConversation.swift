import Foundation
import MLXLMServer

/// `previous_response_id` continues a stored conversation, as OpenAI defines it: the earlier request's input
/// items, then that response's output, then this request's input. The fork's typed request has no such field,
/// so the provider rewrites the raw body before it is decoded and keeps the conversations itself.
enum LocalResponseConversation {
    enum Preparation: Equatable {
        /// Not a JSON object with a string or array `input`: decode it as sent (its error stays the decoder's)
        /// and remember nothing.
        case opaque
        /// `body` is nil when the request names no previous response, so the original bytes are decoded
        /// unchanged. `inputItems` is the conversation so far in input-item form, as a JSON array.
        case prepared(body: Data?, inputItems: Data)
        case previousResponseNotFound
    }

    /// The terminal response a stream carries, reduced to what a later request continues from. Decoding only
    /// these fields keeps usage and timestamps (numbers re-encoded through `JSONValue`) out of the way.
    struct FinalResponse: Decodable, Equatable {
        let id: String
        let output: [OpenAIResponseOutputItem]
    }

    static func prepare(body: Data, conversation: (String) -> Data?) -> Preparation {
        guard var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              var items = inputItems(object["input"])
        else { return .opaque }
        guard let previousValue = object["previous_response_id"], !(previousValue is NSNull) else {
            guard let inputItems = encoded(items) else { return .opaque }
            return .prepared(body: nil, inputItems: inputItems)
        }
        // The typed SDK request ignores this field. Reuse the responder's early
        // 400 refusal for non-null values that cannot name a stored response.
        guard let previousID = previousValue as? String else { return .previousResponseNotFound }
        guard let stored = conversation(previousID),
              let earlier = (try? JSONSerialization.jsonObject(with: stored)) as? [Any]
        else { return .previousResponseNotFound }
        items = earlier + items
        object["input"] = items
        object.removeValue(forKey: "previous_response_id")
        guard let rewritten = try? JSONSerialization.data(withJSONObject: object),
              let inputItems = encoded(items)
        else { return .opaque }
        return .prepared(body: rewritten, inputItems: inputItems)
    }

    /// The conversation a later request continues: `inputItems`, then the response's output as ONE assistant
    /// message. Separate message and function_call items would lower to consecutive assistant turns, which is
    /// not what the model produced; one message with `tool_calls` (and its reasoning, for templates that keep
    /// it on a tool-calling turn) is.
    static func conversation(inputItems: Data, output: [OpenAIResponseOutputItem]) -> Data? {
        guard let earlier = (try? JSONSerialization.jsonObject(with: inputItems)) as? [Any] else { return nil }
        var text = ""
        var reasoning = ""
        var calls: [[String: Any]] = []
        for item in output {
            switch item.type {
            case "message":
                text += (item.content ?? []).map(\.text).joined()
            case "reasoning":
                reasoning += (item.summary ?? item.content ?? []).map(\.text).joined()
            case "function_call":
                guard let name = item.name else { continue }
                calls.append([
                    "id": item.callID ?? item.id, "type": "function",
                    "function": ["name": name, "arguments": item.arguments ?? ""],
                ])
            default:
                continue
            }
        }
        // Content is "" rather than absent on a tool-only turn, as the fork lowers function_call items.
        var turn: [String: Any] = ["role": "assistant", "content": text]
        if !calls.isEmpty { turn["tool_calls"] = calls }
        if !reasoning.isEmpty { turn["reasoning_content"] = reasoning }
        return encoded(earlier + [turn])
    }

    /// The response in a `response.completed` or `response.incomplete` SSE frame (an incomplete response can
    /// still be continued, as with OpenAI); nil for every other frame, including `response.failed`.
    static func finalResponse(inFrame frame: String) -> FinalResponse? {
        guard frame.hasPrefix("event: response.completed\n") || frame.hasPrefix("event: response.incomplete\n"),
              let line = frame.split(separator: "\n").first(where: { $0.hasPrefix("data: ") })
        else { return nil }
        struct Event: Decodable { let response: FinalResponse }
        return (try? JSONDecoder().decode(Event.self, from: Data(line.dropFirst("data: ".count).utf8)))?.response
    }

    /// A request's own input in item form: a string is one user message; a missing input continues with nothing.
    private static func inputItems(_ input: Any?) -> [Any]? {
        guard let input else { return [] }
        switch input {
        case let text as String: return [["role": "user", "content": text]]
        case let items as [Any]: return items
        default: return nil
        }
    }

    private static func encoded(_ items: [Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: items)
    }
}
