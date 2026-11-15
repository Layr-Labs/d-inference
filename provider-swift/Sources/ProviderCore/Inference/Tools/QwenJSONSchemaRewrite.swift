// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Qwen JSON answers for the `json_schema`s outside the shared subset that
/// clients send every day. The request's schema is tried as written, then
/// rewritten exactly (`ResponseSchemaRewrite`: Pydantic, OpenAI strict, zod),
/// then with its value assertions dropped (`minimum`, `pattern`, `format`, …:
/// the grammar enforces the structure and the values stay the model's), then,
/// for an object root, as a JSON object. A widened answer is best effort, as
/// these requests were unconstrained before: it is never checked after
/// generation (`JSONAnswerFormat.unchecked`), so never refused. Anything else
/// keeps today's prompt-only decline. Only the Qwen profile widens; Bonsai and
/// Lightning keep declining.
enum QwenJSONSchemaRewrite {
    /// On by default; `off`, `0`, `false` or `no` restores declining these
    /// schemas. Read once at launch.
    static let environmentKey = "DARKBLOOM_QWEN_JSON_SCHEMA_REWRITE"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    /// How a constrained format departs from the request's schema.
    enum Widening: Equatable, Sendable {
        /// Rewritten exactly into the subset.
        case rewritten
        /// Value assertions dropped: the structure is exact, the values free.
        case relaxed
        /// Held to a JSON object.
        case object

        var note: StaticString {
            switch self {
            case .rewritten: "rewritten into the constrained subset"
            case .relaxed: "constrained without its value assertions"
            case .object: "held to a JSON object"
            }
        }
    }

    static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "0", "false", "no"].contains(value)
    }

    /// The format to constrain, and how it widens the request's, or nil.
    static func answerFormat(_ format: OpenAIResponseFormat, profile: JSONAnswerProfile, widens: Bool)
        -> (format: JSONAnswerFormat, widening: Widening?)? {
        func compiled(_ candidate: OpenAIResponseFormat) -> JSONAnswerFormat? {
            try? JSONAnswerFormat(candidate, forbidding: profile.contentMarkers, family: profile.family)
        }
        if let exact = compiled(format) { return (exact, nil) }
        guard widens, profile.family == JSONAnswerProfile.qwen35.family, format.type == .jsonSchema,
              var payload = format.jsonSchema else { return nil }
        let schema = payload.schema
        for (relaxing, widening) in [(false, Widening.rewritten), (true, .relaxed)] {
            guard let rewritten = ResponseSchemaRewrite.subset(schema, relaxingAssertions: relaxing) else { continue }
            payload.schema = rewritten
            if let answer = compiled(.jsonSchema(payload)) { return (answer.unchecked(), widening) }
        }
        // The fallback reads the request's own root.
        guard case .object(let root) = schema, root["type"] == .string("object"), root["$ref"] == nil,
              let object = compiled(.jsonObject()) else { return nil }
        return (object.unchecked(), .object)
    }
}
