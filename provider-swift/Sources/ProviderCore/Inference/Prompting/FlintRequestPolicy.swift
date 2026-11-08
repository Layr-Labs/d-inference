import Foundation
import MLXLMServer

/// Flint chooses whether to reason. It has no trained switch, effort level or
/// budget, and its pinned template reads none of these controls. Recognized
/// reasoning controls are accepted with no effect on the prompt; only the
/// caller's choice not to receive reasoning is honored, by withholding the
/// reasoning Flint still generates. Output length is not a reasoning effort.
enum FlintRequestPolicy {
    /// The effort names, exactly as written (`ReasoningEffort`).
    static func acceptsEffort(_ effort: String) -> Bool { ReasoningEffort(rawValue: effort) != nil }

    /// Request-local evidence from the original body, captured before the
    /// permissive extension decoder and the typed request drop wrong-typed or
    /// unmodeled values (`reasoning.exclude`, `include_reasoning`). It never
    /// leaves the request and holds no request text.
    struct RawControls: Sendable, Equatable, Decodable {
        /// A malformed value, unknown effort or unsupported reasoning key.
        var invalid = false
        /// The field of an effort that is none of the names.
        var unknownEffort: ReasoningEffortField?
        /// `reasoning.exclude` true, `include_reasoning` false or
        /// `reasoning.enabled` false.
        var withholdsReasoning = false

        private struct Key: CodingKey {
            let stringValue: String
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.init(stringValue) }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }
        private struct Malformed: Error {}

        init() {}
        init(from decoder: any Decoder) throws { self = Self.capture(from: decoder) }

        /// Chat and Responses bodies spell these controls identically.
        static func capture(from decoder: any Decoder) -> Self {
            var result = Self()
            do {
                let root = try decoder.container(keyedBy: Key.self)
                func boolean(_ values: KeyedDecodingContainer<Key>, _ name: String) throws -> Bool? {
                    guard values.contains(Key(name)) else { return nil }
                    return try values.decode(Bool.self, forKey: Key(name)) // No numeric truthiness.
                }
                func effort(_ values: KeyedDecodingContainer<Key>, _ name: String,
                            _ field: ReasoningEffortField) throws {
                    guard values.contains(Key(name)) else { return }
                    guard FlintRequestPolicy.acceptsEffort(try values.decode(String.self, forKey: Key(name))) else {
                        result.unknownEffort = field
                        throw Malformed()
                    }
                }
                if root.contains(Key("preserve_thinking")) { result.invalid = true }
                _ = try boolean(root, "enable_thinking")
                try effort(root, "reasoning_effort", .reasoningEffort)
                if try boolean(root, "include_reasoning") == false { result.withholdsReasoning = true }
                if root.contains(Key("chat_template_kwargs")) {
                    let kwargs = try root.nestedContainer(keyedBy: Key.self, forKey: Key("chat_template_kwargs"))
                    if kwargs.allKeys.contains(where: { !["enable_thinking", "thinking"].contains($0.stringValue) }) {
                        result.invalid = true
                    }
                    _ = try boolean(kwargs, "enable_thinking")
                    _ = try boolean(kwargs, "thinking")
                }
                if root.contains(Key("reasoning")), try !root.decodeNil(forKey: Key("reasoning")) {
                    let reasoning = try root.nestedContainer(keyedBy: Key.self, forKey: Key("reasoning"))
                    if reasoning.allKeys.contains(where: { !["effort", "enabled", "exclude"].contains($0.stringValue) }) {
                        result.invalid = true
                    }
                    try effort(reasoning, "effort", .reasoningObject)
                    if try boolean(reasoning, "enabled") == false { result.withholdsReasoning = true }
                    if try boolean(reasoning, "exclude") == true { result.withholdsReasoning = true }
                }
            } catch {
                result.invalid = true
            }
            return result
        }
    }

    static func validateControls(_ controls: ChatTemplateControls, modelType: String?) throws {
        guard modelType == "flint" else { return }
        // Raw evidence is authoritative; the typed fields cover programmatic
        // controls. The media-only evidence bit is unrelated.
        if let field = controls.rawFlintControls.unknownEffort
            ?? (controls.reasoningEffort.map(acceptsEffort) == false ? ReasoningEffortField.reasoningEffort : nil)
        {
            throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(field)
        }
        guard !controls.rawFlintControls.invalid, controls.preserveThinking == nil else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "Flint reasoning controls require Boolean switches and known reasoning keys")
        }
    }

    static func validate(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) throws {
        guard modelType == "flint" else { return }
        try validateControls(controls, modelType: modelType)
        if let effort = request.reasoning?.effort, !acceptsEffort(effort) {
            throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningObject)
        }
        if MediaIngest.hasMedia(request) {
            throw MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel(request.model)
        }
        try validateHistoricalArguments(request)
    }

    /// Flint cannot skip reasoning, so a caller that declines it gets the
    /// answer without the reasoning text. The reasoning is still generated and
    /// counted as completion (and reasoning) tokens.
    static func withholdsReasoning(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) -> Bool {
        modelType == "flint"
            && (controls.rawFlintControls.withholdsReasoning || request.reasoning?.enabled == false)
    }

    private static func validateHistoricalArguments(_ request: OpenAIChatCompletionRequest) throws {
        for message in request.messages {
            for call in message.toolCalls ?? [] {
                guard
                    let arguments = try? JSONSerialization.jsonObject(
                        with: Data(call.function.arguments.utf8)) as? [String: Any]
                else {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "Flint historical tool arguments must be a JSON object")
                }
                // The pinned template emits top-level strings verbatim, while
                // objects/arrays are JSON encoded and protect nested strings.
                // There is no escape for this raw delimiter. A generated frame
                // which is syntactically indistinguishable from separate args
                // cannot be disambiguated after the fact; never promise that
                // arbitrary delimiter-bearing strings round-trip.
                if arguments.values.contains(where: {
                    ($0 as? String)?.contains("</arg_value>") == true
                }) {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "Flint cannot represent a literal </arg_value> in a raw string tool argument"
                    )
                }
            }
        }
    }
}
