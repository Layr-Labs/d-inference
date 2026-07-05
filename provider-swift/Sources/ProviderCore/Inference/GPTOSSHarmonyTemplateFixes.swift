// Copyright © 2026 Eigen Labs.
//
// GPT-OSS uses OpenAI's Harmony template. These fixes mirror invariants in the
// upstream `openai/gpt-oss-20b` and `mlx-community/gpt-oss-20b-MXFP4-Q8`
// templates without changing other model families.

import Foundation

enum GPTOSSHarmonyTemplateFix {
    static func applies(to context: ChatTemplateFixContext) -> Bool {
        isHarmonyModelHint(context.modelId) || isHarmonyModelHint(context.modelType)
    }

    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        let bridged = bridgeReasoningContentToThinking(messages)
        return try splitParallelToolCalls(bridged)
    }

    static func normalizeTools(
        _ tools: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        tools.map(normalizeToolSpec)
    }

    static func extraEOSTokenIds(tokenToId: (String) -> Int?) -> Set<Int> {
        Set(["<|return|>", "<|endoftext|>", "<|call|>"].compactMap(tokenToId))
    }

    private static func isHarmonyModelHint(_ value: String?) -> Bool {
        guard let value else { return false }
        let normalized = value.lowercased()
        return normalized.contains("gpt-oss")
            || normalized.contains("gpt_oss")
            || normalized.contains("gptoss")
    }

    // splitParallelToolCalls rewrites Harmony-incompatible assistant turns into a
    // valid sequence instead of rejecting them. Harmony represents at most ONE tool
    // call per assistant turn and forbids content+thinking sharing a turn with a
    // tool_call, but OpenAI clients (all our traffic, via OpenRouter) legitimately
    // send an assistant message with N PARALLEL tool_calls followed by N tool
    // results. The old behavior threw a 400 — making those valid histories
    // permanently unservable on gpt-oss. Here we split such a message into N
    // sequential Harmony turns, each carrying one tool_call immediately followed by
    // its paired tool result (matched by tool_call_id, NOT position). Assistant
    // `content` rides the FIRST split turn; `thinking` (which Harmony forbids in the
    // same turn as a tool_call) is emitted as a standalone preceding assistant turn.
    //
    // The only genuinely unnormalizable shape — a following tool RESULT whose
    // tool_call_id matches none of the assistant's tool_calls — still throws a clean
    // 400 (invalidToolPayload), so we never silently drop a result.
    private static func splitParallelToolCalls(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        var out: [[String: any Sendable]] = []
        out.reserveCapacity(messages.count)
        var i = 0
        while i < messages.count {
            let message = messages[i]
            guard (message["role"] as? String) == "assistant",
                  let toolCalls = message["tool_calls"] as? [any Sendable],
                  !toolCalls.isEmpty
            else {
                out.append(message)
                i += 1
                continue
            }

            let hasContent = hasTruthyString(message["content"])
            let thinking = firstTruthyString(message["thinking"], message["reasoning_content"])
            // A single tool_call with no content+thinking conflict is already
            // Harmony-legal — pass it (and its trailing results) through untouched.
            if toolCalls.count == 1 && !(hasContent && !thinking.isEmpty) {
                out.append(message)
                i += 1
                continue
            }

            // Gather the contiguous tool-result messages that follow, keyed by id.
            var results: [String: [String: any Sendable]] = [:]
            var resultOrder: [String] = []
            var j = i + 1
            while j < messages.count, (messages[j]["role"] as? String) == "tool" {
                if let id = messages[j]["tool_call_id"] as? String {
                    results[id] = messages[j]
                    resultOrder.append(id)
                }
                j += 1
            }

            // Harmony forbids thinking in the same turn as a tool_call: emit a
            // standalone assistant thinking-turn first when present.
            if !thinking.isEmpty {
                out.append(["role": "assistant", "thinking": thinking])
            }

            var consumed = Set<String>()
            for (idx, call) in toolCalls.enumerated() {
                var turn: [String: any Sendable] = ["role": "assistant", "tool_calls": [call]]
                if idx == 0 && hasContent {
                    turn["content"] = message["content"]
                }
                out.append(turn)
                if let callMap = call as? [String: any Sendable],
                   let id = callMap["id"] as? String,
                   let result = results[id] {
                    out.append(result)
                    consumed.insert(id)
                }
            }

            // A trailing tool result that pairs with none of THIS turn's tool_calls
            // cannot be placed — reject cleanly rather than drop it.
            for id in resultOrder where !consumed.contains(id) {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "tool result for tool_call_id \(id) has no matching assistant tool_call")
            }
            i = j
        }
        return out
    }

    private static func firstTruthyString(_ values: (any Sendable)?...) -> String {
        for value in values {
            if let s = value as? String, !s.isEmpty {
                return s
            }
        }
        return ""
    }

    private static func bridgeReasoningContentToThinking(
        _ messages: [[String: any Sendable]]
    ) -> [[String: any Sendable]] {
        messages.map { message in
            guard (message["role"] as? String) == "assistant" else { return message }
            guard message["thinking"] == nil,
                  let reasoning = message["reasoning_content"] as? String,
                  !reasoning.isEmpty
            else { return message }
            var output = message
            output["thinking"] = reasoning
            return output
        }
    }

    private static func normalizeToolSpec(
        _ tool: [String: any Sendable]
    ) -> [String: any Sendable] {
        var output = tool
        guard var function = output["function"] as? [String: any Sendable] else {
            return output
        }

        function["description"] = stringValue(function["description"]) ?? ""
        if let parameters = function["parameters"] as? [String: any Sendable] {
            function["parameters"] = normalizeSchemaObject(parameters)
        }
        output["function"] = function
        return output
    }

    private static func normalizeSchemaValue(_ value: any Sendable) -> any Sendable {
        if let object = value as? [String: any Sendable] {
            return normalizeSchemaObject(object)
        }
        if let array = value as? [any Sendable] {
            return array.map(normalizeSchemaValue)
        }
        return value
    }

    private static func normalizeSchemaObject(
        _ object: [String: any Sendable]
    ) -> [String: any Sendable] {
        var output = object

        if let description = output["description"] {
            output["description"] = stringValue(description) ?? ""
        }

        if let properties = output["properties"] as? [String: any Sendable] {
            output["properties"] = properties.mapValues(normalizeSchemaValue)
        } else if output["properties"] != nil {
            output.removeValue(forKey: "properties")
        }

        if let items = output["items"] as? [String: any Sendable] {
            output["items"] = normalizeSchemaObject(items)
        } else if output["items"] != nil {
            output.removeValue(forKey: "items")
        }

        if let required = output["required"] as? [any Sendable] {
            output["required"] = required.compactMap { $0 as? String }
        } else if output["required"] != nil {
            output.removeValue(forKey: "required")
        }

        if let enumValues = output["enum"] as? [any Sendable] {
            output["enum"] = enumValues.map(normalizeSchemaValue)
        } else if output["enum"] != nil {
            output.removeValue(forKey: "enum")
        }

        for unionKey in ["oneOf", "anyOf", "allOf"] {
            if let variants = output[unionKey] as? [any Sendable] {
                output[unionKey] = variants.compactMap { variant -> (any Sendable)? in
                    guard let object = variant as? [String: any Sendable] else { return nil }
                    return normalizeSchemaObject(object)
                }
            } else if output[unionKey] != nil {
                output.removeValue(forKey: unionKey)
            }
        }

        if let defaultValue = output["default"],
           (hasNonEmptyArray(output["enum"]) || hasNonEmptyArray(output["oneOf"])),
           !(defaultValue is String)
        {
            output["default"] = stringValue(defaultValue) ?? ""
        }

        return output
    }

    private static func hasTruthyString(_ value: (any Sendable)?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.isEmpty
    }

    private static func hasNonEmptyArray(_ value: (any Sendable)?) -> Bool {
        guard let array = value as? [any Sendable] else { return false }
        return !array.isEmpty
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if value is NSNull { return nil }
        return String(describing: value)
    }
}
