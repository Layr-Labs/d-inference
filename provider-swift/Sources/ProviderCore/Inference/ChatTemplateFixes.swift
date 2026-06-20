// Copyright © 2026 Eigen Labs.
//
// Model-specific chat-template compatibility hooks. Keep the generic Jinja
// sanitizer in `JinjaSanitization.swift`; put model-family quirks in files named
// after the model family so future fixes do not bleed across templates.

import Foundation

struct ChatTemplateFixContext: Sendable {
    let modelId: String?
    let modelType: String?

    init(modelId: String? = nil, modelType: String? = nil) {
        self.modelId = modelId
        self.modelType = modelType
    }
}

enum ChatTemplateFixes {
    static func normalizeMessages(
        _ messages: [[String: any Sendable]],
        context: ChatTemplateFixContext
    ) throws -> [[String: any Sendable]] {
        let sanitized = sanitizeJinjaMessages(messages)
        try validateGenericToolHistory(sanitized)

        if GPTOSSHarmonyTemplateFix.applies(to: context) {
            return try GPTOSSHarmonyTemplateFix.normalizeMessages(sanitized)
        }
        if Gemma4TemplateFix.applies(to: context) {
            return try Gemma4TemplateFix.normalizeMessages(sanitized)
        }
        return sanitized
    }

    static func normalizeTools(
        _ tools: [[String: any Sendable]]?,
        context: ChatTemplateFixContext
    ) -> [[String: any Sendable]]? {
        guard let sanitized = sanitizeTools(tools) else { return nil }
        if GPTOSSHarmonyTemplateFix.applies(to: context) {
            return GPTOSSHarmonyTemplateFix.normalizeTools(sanitized)
        }
        if Gemma4TemplateFix.applies(to: context) {
            return Gemma4TemplateFix.normalizeTools(sanitized)
        }
        return sanitized
    }

    /// Sanitize a chat-template `tools` array (or `nil`), dropping null /
    /// `Optional` leaves from each tool spec. `nil` in => `nil` out, so the
    /// render context still omits `tools` entirely for tool-less requests.
    static func sanitizeTools(
        _ tools: [[String: any Sendable]]?
    ) -> [[String: any Sendable]]? {
        guard let tools else { return nil }
        return tools.map(sanitizeJinjaObject)
    }

    static func extraEOSTokenIds(
        context: ChatTemplateFixContext,
        base: Set<Int>,
        tokenToId: (String) -> Int?
    ) -> Set<Int> {
        var ids = base
        if GPTOSSHarmonyTemplateFix.applies(to: context) {
            ids.formUnion(GPTOSSHarmonyTemplateFix.extraEOSTokenIds(tokenToId: tokenToId))
        }
        if Gemma4TemplateFix.applies(to: context) {
            ids.formUnion(Gemma4TemplateFix.extraEOSTokenIds(tokenToId: tokenToId))
        }
        return ids
    }

    private static func validateGenericToolHistory(
        _ messages: [[String: any Sendable]]
    ) throws {
        var toolResultsAllowed = false

        for message in messages {
            switch message["role"] as? String {
            case "assistant":
                guard let toolCalls = message["tool_calls"] as? [any Sendable],
                      !toolCalls.isEmpty
                else {
                    toolResultsAllowed = false
                    continue
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

    private static func firstToolCallName(_ toolCalls: [any Sendable]) -> String? {
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
}
