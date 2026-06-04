// Copyright © 2026 Eigen Labs.
//
// Tolerant, dependency-free normalisation of an inbound OpenAI
// chat-completion JSON body. This runs ONLY on the cold path — after the
// strict `OpenAIChatCompletionRequest` decoder has already rejected a
// payload — to recover the *valid* OpenAI shapes that decoder is too
// strict to accept, without changing request semantics.
//
// Background (#252). The strict upstream decoder rejects several
// legitimate OpenAI requests with HTTP 400:
//   - hosted/builtin tools that carry no `function`/`name`
//     (`web_search`, `file_search`, `code_interpreter`, `computer_use`)
//     and `{"type":"custom", ...}` tools;
//   - messages that omit the `content` key (e.g. an assistant turn that
//     carries only `tool_calls`);
//   - the `developer` role (and the older `function` role spelling);
//   - a scalar `stop` string (OpenAI also allows the array form that the
//     strict decoder requires).
//
// Policy:
//   - Tools we cannot represent as the upstream `OpenAITool` are dropped.
//     The provider never invokes tools server-side (pass-through only),
//     so ignoring shapes it can't model keeps otherwise-valid requests
//     serviceable instead of failing the whole request. Function-shaped
//     tools are always preserved.
//   - Roles with a documented equivalent are aliased; anything else is
//     surfaced as a clear `invalidRole` (HTTP 400) rather than a
//     misleading decoder error.

import Foundation

/// Pure helpers that repair the small set of valid-but-strictly-rejected
/// OpenAI chat shapes described above. Stateless and side-effect free so
/// it can be unit-tested in isolation from ``ProviderLoop``.
enum InboundChatNormalization {

    /// Roles the upstream `OpenAIRole` enum can represent directly.
    static let supportedRoles: Set<String> = ["system", "user", "assistant", "tool"]

    /// Roles with a documented 1:1 equivalent in ``supportedRoles``.
    /// `developer` is OpenAI's newer spelling of `system` (developer
    /// messages replace system messages on o1+ models); `function` is the
    /// pre-`tool` spelling of a tool-result message.
    static let roleAliases: [String: String] = [
        "developer": "system",
        "function": "tool",
    ]

    /// Normalise `data` (a chat-completion request body) into a shape the
    /// strict `OpenAIChatCompletionRequest` decoder accepts.
    ///
    /// - Returns: re-serialised JSON. A body is returned even when nothing
    ///   needed changing; callers re-run the strict decoder on it.
    /// - Throws: ``MultiModelBatchSchedulerEngineError/invalidRole(_:)``
    ///   for a role with no representable equivalent, or a `DecodingError`
    ///   when the body is not a JSON object (so the caller can fall back
    ///   to the original strict-decoder error rather than masking it).
    static func normalize(_ data: Data) throws -> Data {
        guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "request body is not a JSON object")
            )
        }
        var root = parsed

        if let messages = root["messages"] as? [Any] {
            root["messages"] = try messages.map(normalizeMessage)
        }

        if let tools = root["tools"] as? [Any] {
            // Keep only tools representable as the upstream `OpenAITool`.
            // Hosted/builtin and custom tools are dropped — see the policy
            // note at the top of this file.
            root["tools"] = tools.filter(isRepresentableTool)
        }

        // OpenAI accepts a scalar `stop` string as well as an array; the
        // strict `OpenAIChatCompletionRequest` decoder only accepts
        // `[String]`. Wrap a lone string so it survives — mirrors the
        // retired legacy `StopSequences.asArray` lift (#252).
        if let stop = root["stop"] as? String {
            root["stop"] = [stop]
        }

        return try JSONSerialization.data(withJSONObject: root)
    }

    /// Normalise a single `messages[]` entry: alias known roles and
    /// materialise an explicit `null` for a missing `content` key.
    private static func normalizeMessage(_ value: Any) throws -> Any {
        guard var message = value as? [String: Any] else { return value }

        if let role = message["role"] as? String {
            if let canonical = roleAliases[role] {
                message["role"] = canonical
            } else if !supportedRoles.contains(role) {
                throw MultiModelBatchSchedulerEngineError.invalidRole(role)
            }
        }

        // A *missing* `content` key is valid OpenAI (an assistant turn may
        // carry only `tool_calls`). The strict decoder requires the key to
        // be present; an explicit null decodes to empty content. Note we
        // only inject when the key is absent — an explicit `content: null`
        // is already handled by the strict decoder and left untouched.
        if message.index(forKey: "content") == nil {
            message["content"] = NSNull()
        }

        return message
    }

    /// True when a tool entry can be decoded by the upstream `OpenAITool`
    /// — i.e. it has a `function` object or a top-level `name` (with
    /// optional `parameters`/`input_schema`). Hosted tools (`web_search`,
    /// `file_search`, …) and `{"type":"custom", ...}` tools have neither.
    private static func isRepresentableTool(_ value: Any) -> Bool {
        guard let tool = value as? [String: Any] else { return false }
        if tool["function"] is [String: Any] { return true }
        if tool["name"] is String { return true }
        return false
    }
}
