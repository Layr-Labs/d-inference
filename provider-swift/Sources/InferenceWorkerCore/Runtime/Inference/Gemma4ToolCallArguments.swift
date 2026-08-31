// Copyright © 2026 Eigen Labs.
//
// Gemma4 tool-call `arguments` hardening (E3, 2026-07-15 platform errors deep
// dive). By the time chat-template dicts reach the model fix hooks,
// `tool_calls[].function.arguments` is either a decoded JSON object or the
// RAW STRING: the engine's `decodeToolCallArguments`
// (libs/mlx-swift-lm .../ParserUtilities.swift) returns the string unchanged
// when it is empty, malformed, or valid-but-non-object JSON. The served Gemma
// template's `{%- elif function['arguments'] is string -%}` branch then dumps
// that string verbatim inside its own `call:name{…}` braces, producing the
// double-brace corruption `call:f{{"a":1}}` — which the model imitates on the
// next turn and the output parser shreds.
//
// Repair at the gemma4 hook (provider-side; the engine submodule is not
// touched):
//   • arguments missing / empty (or whitespace-only) → `{}` (renders an
//     empty argument list);
//   • arguments a String → parse as JSON; a JSON OBJECT replaces the string
//     (null leaves re-stripped — the raw string bypassed the earlier
//     sanitize pass);
//   • parse failure or JSON non-object (array / scalar / null) → throw
//     `invalidToolPayload` (deterministic 400) instead of rendering garbage.

import Foundation

enum Gemma4ToolCallArguments {

    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        try messages.map { message in
            guard (message["role"] as? String) == "assistant",
                let calls = message["tool_calls"] as? [any Sendable], !calls.isEmpty
            else { return message }
            var output = message
            output["tool_calls"] =
                try calls.map { call -> any Sendable in
                    guard var callMap = call as? [String: any Sendable],
                        var function = callMap["function"] as? [String: any Sendable]
                    else { return call }
                    function["arguments"] = try normalizedArguments(function["arguments"])
                    callMap["function"] = function
                    return callMap
                } as [any Sendable]
            return output
        }
    }

    private static func normalizedArguments(
        _ raw: (any Sendable)?
    ) throws -> [String: any Sendable] {
        guard let raw else { return [:] }
        if let mapping = raw as? [String: any Sendable] {
            return mapping
        }
        if let text = raw as? String {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [:]
            }
            guard let data = text.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(
                    with: data, options: [.fragmentsAllowed]),
                let object = decoded as? [String: any Sendable]
            else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "tool_calls[].function.arguments must be a JSON object")
            }
            // The raw string bypassed the earlier message-level null strip;
            // re-sanitize so a `{"a":null}` payload cannot re-introduce an
            // NSNull leaf the Jinja value bridge throws on.
            return sanitizeJinjaObject(object)
        }
        // A non-string non-mapping shape (array / number / bool) is not an
        // OpenAI arguments payload.
        throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "tool_calls[].function.arguments must be a JSON object")
    }
}
