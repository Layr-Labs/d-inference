// Copyright © 2026 Eigen Labs.
//
// Tool-specific chat-template normalization layered on top of the generic
// Jinja null/Harmony sanitizer. GPT-OSS/Harmony's template intentionally raises
// on malformed tool histories and performs several string concatenations over
// tool-schema fields, so normalize those invariants before render.

import Foundation

/// Sanitize and validate messages before rendering a chat template. Harmony's
/// template intentionally raises on malformed tool histories; catching those
/// invariants here lets the provider return a client 400 instead of surfacing a
/// model-specific `Jinja.TemplateException` as a provider 500.
func normalizeJinjaMessagesForTemplate(
    _ messages: [[String: any Sendable]],
    modelId: String? = nil,
    modelType: String? = nil
) throws -> [[String: any Sendable]] {
    let sanitized = sanitizeJinjaMessages(messages)
    let harmonyStrict = isHarmonyModelHint(modelId) || isHarmonyModelHint(modelType)
    let templateMessages = harmonyStrict ? bridgeHarmonyReasoningFields(sanitized) : sanitized
    try validateToolMessageHistory(templateMessages, harmonyStrict: harmonyStrict)
    return templateMessages
}

/// Sanitize a chat-template `tools` array (or `nil`), dropping null /
/// `Optional` leaves from each tool spec (e.g. `"default": null`,
/// `"const": null`, or a `null` enum element inside a `function.parameters`
/// JSON schema). `nil` in ⇒ `nil` out, so the render context still omits
/// the `tools` key entirely for tool-less requests.
func sanitizeJinjaTools(
    _ tools: [[String: any Sendable]]?
) -> [[String: any Sendable]]? {
    guard let tools else { return nil }
    return tools.map(sanitizeJinjaObject)
}

func normalizeJinjaToolsForTemplate(
    _ tools: [[String: any Sendable]]?,
    modelId: String? = nil,
    modelType: String? = nil
) -> [[String: any Sendable]]? {
    guard let sanitized = sanitizeJinjaTools(tools) else { return nil }
    guard isHarmonyModelHint(modelId) || isHarmonyModelHint(modelType) else {
        return sanitized
    }
    return sanitized.map(normalizeJinjaToolSpec)
}

private func validateToolMessageHistory(
    _ messages: [[String: any Sendable]],
    harmonyStrict: Bool
) throws {
    var toolResultsAllowed = false

    for message in messages {
        let role = message["role"] as? String
        switch role {
        case "assistant":
            guard let toolCalls = message["tool_calls"] as? [any Sendable],
                  !toolCalls.isEmpty
            else {
                toolResultsAllowed = false
                continue
            }
            guard !harmonyStrict || toolCalls.count == 1 else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "assistant message contains multiple tool_calls; Harmony supports one tool call per assistant message")
            }

            if harmonyStrict
                && hasTruthyString(message["content"])
                && (hasTruthyString(message["thinking"])
                    || hasTruthyString(message["reasoning_content"]))
            {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "assistant message with tool_calls cannot include both content and thinking")
            }

            guard firstToolCallName(toolCalls) != nil else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "assistant tool_calls[0] is missing function.name")
            }
            toolResultsAllowed = true

        case "tool":
            guard toolResultsAllowed else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "tool message has no preceding assistant tool_calls")
            }

        default:
            toolResultsAllowed = false
        }
    }
}

private func bridgeHarmonyReasoningFields(
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

private func hasTruthyString(_ value: (any Sendable)?) -> Bool {
    guard let text = value as? String else { return false }
    return !text.isEmpty
}

private func firstToolCallName(_ toolCalls: [any Sendable]) -> String? {
    guard let first = toolCalls.first as? [String: any Sendable] else { return nil }
    if let function = first["function"] as? [String: any Sendable],
       let name = function["name"] as? String,
       !name.isEmpty
    {
        return name
    }
    if let name = first["name"] as? String, !name.isEmpty {
        return name
    }
    return nil
}

private func normalizeJinjaToolSpec(
    _ tool: [String: any Sendable]
) -> [String: any Sendable] {
    var output = tool
    guard var function = output["function"] as? [String: any Sendable] else {
        return output
    }

    function["description"] = stringValue(function["description"]) ?? ""
    if let parameters = function["parameters"] as? [String: any Sendable] {
        function["parameters"] = normalizeJinjaSchemaObject(parameters)
    }
    output["function"] = function
    return output
}

private func normalizeJinjaSchemaValue(_ value: any Sendable) -> any Sendable {
    if let object = value as? [String: any Sendable] {
        return normalizeJinjaSchemaObject(object)
    }
    if let array = value as? [any Sendable] {
        return array.map(normalizeJinjaSchemaValue)
    }
    return value
}

private func normalizeJinjaSchemaObject(
    _ object: [String: any Sendable]
) -> [String: any Sendable] {
    var output = object

    if let description = output["description"] {
        output["description"] = stringValue(description) ?? ""
    }

    if let properties = output["properties"] as? [String: any Sendable] {
        output["properties"] = properties.mapValues(normalizeJinjaSchemaValue)
    } else if output["properties"] != nil {
        output.removeValue(forKey: "properties")
    }

    if let items = output["items"] as? [String: any Sendable] {
        output["items"] = normalizeJinjaSchemaObject(items)
    } else if output["items"] != nil {
        output.removeValue(forKey: "items")
    }

    if let required = output["required"] as? [any Sendable] {
        output["required"] = required.compactMap { $0 as? String }
    } else if output["required"] != nil {
        output.removeValue(forKey: "required")
    }

    if let enumValues = output["enum"] as? [any Sendable] {
        output["enum"] = enumValues.map(normalizeJinjaSchemaValue)
    } else if output["enum"] != nil {
        output.removeValue(forKey: "enum")
    }

    for unionKey in ["oneOf", "anyOf", "allOf"] {
        if let variants = output[unionKey] as? [any Sendable] {
            output[unionKey] = variants.compactMap { variant -> (any Sendable)? in
                guard let object = variant as? [String: any Sendable] else { return nil }
                return normalizeJinjaSchemaObject(object)
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

private func hasNonEmptyArray(_ value: (any Sendable)?) -> Bool {
    guard let array = value as? [any Sendable] else { return false }
    return !array.isEmpty
}

private func stringValue(_ value: Any?) -> String? {
    guard let value else { return nil }
    if let string = value as? String { return string }
    if value is NSNull { return nil }
    return String(describing: value)
}
