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
        try validateHarmonyToolInvariants(bridged)
        return bridged
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

    private static func validateHarmonyToolInvariants(
        _ messages: [[String: any Sendable]]
    ) throws {
        for message in messages where (message["role"] as? String) == "assistant" {
            guard let toolCalls = message["tool_calls"] as? [any Sendable],
                  !toolCalls.isEmpty
            else { continue }

            guard toolCalls.count == 1 else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "assistant message contains multiple tool_calls; Harmony supports one tool call per assistant message")
            }

            if hasTruthyString(message["content"])
                && (hasTruthyString(message["thinking"])
                    || hasTruthyString(message["reasoning_content"]))
            {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "assistant message with tool_calls cannot include both content and thinking")
            }
        }
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
