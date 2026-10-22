import CoreFoundation
import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer

/// Prompt semantics of the pinned official GLM-5.3-Flash template, not a model
/// registration, raw-checkpoint repair or constrained-decoding capability.
enum GLM5NextPromptPolicy {
    /// The only recognized template: the one shipped in
    /// `EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp`. It is the official template
    /// (`0c4099f3…`, still the golden rendering authority) with its four `.0.`
    /// attribute accesses written as `[0].`, because the pinned Swift-Jinja
    /// cannot parse the official spelling.
    static let templateSHA256 = "46b2e2137e2759355b3e0e3e90cf4bd172b568437a75588af5c457cc8c095b2e"

    static func applies(modelType: String?) -> Bool {
        modelType == "glm5_next" || modelType == "glm5_next_text" || modelType == "glm5_next_mtp"
    }

    /// Fixed client text for every reasoning-exclusion request. It never
    /// echoes request content.
    static let reasoningExclusionUnsupportedMessage =
        "GLM-5.3-Flash returns the reasoning it generates; reasoning.exclude true and include_reasoning false are unsupported. To turn thinking off, send reasoning.enabled false, enable_thinking false or reasoning_effort none."

    /// Render-context key marking thinking-off (present only as `false`). The
    /// pinned template ignores it and always opens `<think>`;
    /// `GLM5NextThinkingTokenizer` reads it and closes that block with
    /// `</think>`, the empty block the template writes for an assistant turn
    /// without reasoning.
    static let thinkingOffContextKey = "enable_thinking"

    private static let contradictoryThinking =
        "thinking-off cannot be combined with a thinking-on switch, effort level or reasoning budget"

    /// The template renders low, high or max. The other OpenAI effort names map
    /// to the nearest of those, matching the platform prompt sidecar. `none`
    /// and `off` turn thinking off; other unknown values are refused.
    enum Effort: String, Sendable, Equatable {
        case low, high, max

        static let disablingRequests: Set<String> = ["none", "off"]

        init?(requested: String) {
            switch requested {
            case "minimal", "low": self = .low
            case "medium", "high": self = .high
            case "xhigh", "max": self = .max
            default: return nil
            }
        }

        /// A `reasoning.max_tokens` budget selects the nearest level using the
        /// budgets OpenAI-compatible APIs conventionally give `low` (1,024) and
        /// `medium` (8,192). The template cannot enforce a token budget.
        init(reasoningBudget tokens: Int) {
            self = tokens <= 1024 ? .low : tokens <= 8192 ? .high : .max
        }
    }

    /// Request-local original declarations survive the legacy model-blind
    /// decoder. They are used only after provider-owned metadata selects GLM;
    /// never publish them in diagnostics, telemetry, or a model advertisement.
    /// A malformed shadowed alias must not disappear in permissive decoding.
    struct RawControls: Sendable, Equatable, Decodable {
        var invalid = false
        /// A thinking-off switch or effort (`none`/`off`).
        var disablesThinking = false
        /// An explicit thinking-on switch (`true`), effort level or budget.
        var requestsThinking = false
        /// `reasoning.exclude: true` or `include_reasoning: false`. Kept apart
        /// from `invalid` so its refusal can tell the caller what to send.
        var excludesReasoning = false
        var effort: Effort?
        var clearThinking: Bool?
        var hasOriginalTools = false
        var originalTools: [OpenAITool]?

        private struct Key: CodingKey {
            let stringValue: String
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.init(stringValue) }
            var intValue: Int? { nil }
            init?(intValue: Int) { return nil }
        }

        init() {}
        init(from decoder: any Decoder) throws { self = Self.capture(from: decoder) }

        static func capture(from decoder: any Decoder) -> Self {
            var result = Self()
            do {
                let root = try decoder.container(keyedBy: Key.self)
                result.hasOriginalTools = root.contains(Key("tools"))
                if result.hasOriginalTools {
                    _ = try root.decode(ExactSchemaValues.self, forKey: Key("tools"))
                }
                result.originalTools = try root.decodeIfPresent([OpenAITool].self, forKey: Key("tools"))
                try ToolConstraintValidation.rejectReservedSchemaMetadata(
                    result.originalTools, allowInternalSchemaMetadata: false)
                func effort(_ values: KeyedDecodingContainer<Key>, _ key: String) throws -> Effort? {
                    guard values.contains(Key(key)) else { return nil }
                    let requested = try values.decode(String.self, forKey: Key(key))
                    if Effort.disablingRequests.contains(requested) {
                        result.disablesThinking = true
                        return nil
                    }
                    guard let effort = Effort(requested: requested) else {
                        throw GLM5NextPromptPolicy.invalid("unsupported reasoning effort")
                    }
                    result.requestsThinking = true
                    return effort
                }
                func clear(_ values: KeyedDecodingContainer<Key>) throws -> Bool? {
                    guard values.contains(Key("clear_thinking")) else { return nil }
                    return try values.decode(Bool.self, forKey: Key("clear_thinking"))
                }
                // OpenRouter and template-kwargs thinking switches.
                func thinkingSwitch(_ values: KeyedDecodingContainer<Key>, _ key: String) throws {
                    guard values.contains(Key(key)) else { return }
                    if try values.decode(Bool.self, forKey: Key(key)) {
                        result.requestsThinking = true
                    } else {
                        result.disablesThinking = true
                    }
                }
                // Hidden reasoning: the value that returns reasoning is a no-op.
                func exclusionSwitch(
                    _ values: KeyedDecodingContainer<Key>, _ key: String, excludingValue: Bool
                ) throws {
                    guard values.contains(Key(key)) else { return }
                    if try values.decode(Bool.self, forKey: Key(key)) == excludingValue {
                        result.excludesReasoning = true
                    }
                }
                if ["preserve_thinking", "thinking"].contains(where: { root.contains(Key($0)) }) {
                    result.invalid = true
                }
                try thinkingSwitch(root, "enable_thinking")
                try exclusionSwitch(root, "include_reasoning", excludingValue: false)
                let topEffort = try effort(root, "reasoning_effort")
                let topClear = try clear(root)
                var nestedEffort: Effort?
                var budgetEffort: Effort?
                if root.contains(Key("reasoning")) {
                    let reasoning = try root.nestedContainer(keyedBy: Key.self, forKey: Key("reasoning"))
                    if reasoning.allKeys.contains(where: {
                        !["effort", "enabled", "exclude", "max_tokens"].contains($0.stringValue)
                    }) { result.invalid = true }
                    nestedEffort = try effort(reasoning, "effort")
                    try thinkingSwitch(reasoning, "enabled")
                    try exclusionSwitch(reasoning, "exclude", excludingValue: true)
                    if reasoning.contains(Key("max_tokens")) {
                        let budget = try reasoning.decode(Int.self, forKey: Key("max_tokens"))
                        guard budget > 0 else {
                            throw GLM5NextPromptPolicy.invalid("reasoning budget must be positive")
                        }
                        budgetEffort = Effort(reasoningBudget: budget)
                        result.requestsThinking = true
                    }
                }
                var kwargsEffort: Effort?
                var kwargsClear: Bool?
                if root.contains(Key("chat_template_kwargs")) {
                    let kwargs = try root.nestedContainer(keyedBy: Key.self, forKey: Key("chat_template_kwargs"))
                    if kwargs.allKeys.contains(where: {
                        !["reasoning_effort", "clear_thinking", "enable_thinking", "thinking"]
                            .contains($0.stringValue)
                    }) { result.invalid = true }
                    kwargsEffort = try effort(kwargs, "reasoning_effort")
                    kwargsClear = try clear(kwargs)
                    try thinkingSwitch(kwargs, "enable_thinking")
                    try thinkingSwitch(kwargs, "thinking")
                }
                // An explicit effort, under any alias, wins over a budget.
                result.effort = nestedEffort ?? topEffort ?? kwargsEffort ?? budgetEffort
                result.clearThinking = topClear ?? kwargsClear
            } catch {
                result.invalid = true
            }
            return result
        }

        /// `admitsReasoningExclusion`: a cluster pair serves `reasoning.exclude`
        /// and `include_reasoning: false` by withholding the reasoning it
        /// generates (`ToolChoicePromptPolicy.Prepared.glm5PairExcludesReasoning`).
        func validate(admitsReasoningExclusion: Bool = false) throws {
            guard !invalid else {
                throw GLM5NextPromptPolicy.invalid(
                    "controls require reasoning_effort none/off/minimal/low/medium/high/xhigh/max, a positive integer reasoning.max_tokens, and Boolean clear_thinking and reasoning switches")
            }
            guard !excludesReasoning || admitsReasoningExclusion else {
                throw MultiModelBatchSchedulerEngineError.reasoningExclusionUnsupported
            }
            // Contradictory spellings are refused, never reconciled.
            guard !(disablesThinking && requestsThinking) else {
                throw GLM5NextPromptPolicy.invalid(GLM5NextPromptPolicy.contradictoryThinking)
            }
        }
    }

    static func additionalContext(
        request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, admitsReasoningExclusion: Bool = false
    ) throws -> [String: any Sendable] {
        let raw = controls.rawGLM5Controls
        try raw.validate(admitsReasoningExclusion: admitsReasoningExclusion)
        guard controls.preserveThinking == nil else { throw invalid("preserve_thinking is unsupported") }
        var thinkingOff = raw.disablesThinking
        var thinkingOn = raw.requestsThinking
        func checked(_ value: String?) throws -> Effort? {
            guard let value else { return nil }
            if Effort.disablingRequests.contains(value) {
                thinkingOff = true
                return nil
            }
            guard let effort = Effort(requested: value) else {
                throw invalid("reasoning_effort must be none, minimal, low, medium, high, xhigh or max")
            }
            thinkingOn = true
            return effort
        }
        let nested = try checked(request.reasoning?.effort)
        let top = try checked(controls.reasoningEffort)
        for enabled in [request.reasoning?.enabled, controls.enableThinking].compactMap({ $0 }) {
            if enabled { thinkingOn = true } else { thinkingOff = true }
        }
        guard !(thinkingOff && thinkingOn) else {
            throw invalid(contradictoryThinking)
        }
        var context: [String: any Sendable] = [
            "reasoning_effort": (nested ?? top ?? raw.effort ?? .max).rawValue,
            "clear_thinking": controls.clearThinking ?? raw.clearThinking ?? false,
        ]
        if thinkingOff { context[thinkingOffContextKey] = false }
        return context
    }

    /// This is the text-contract path, not a family-wide media capability
    /// predicate. The media path (`EngineV2VisionPrefill.glm5NextUserInput`)
    /// normalizes a text-only copy through it, then restores symbolic media
    /// parts in its own owned preparation.
    static func normalizedTextInput(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        controls: ChatTemplateControls
    ) throws -> ProviderPromptContractPipeline.NormalizedInput {
        let context = try additionalContext(request: request, controls: controls,
            admitsReasoningExclusion: prepared.glm5PairPostValidation)
        // On a cluster pair these are prompt-forced and validated before any
        // call or JSON content is exposed (`ToolChoiceEnforcementPolicy`,
        // `OpenAIResponseFormatSupport`); the single-Mac path refuses them.
        guard !prepared.requiresToolCall || prepared.glm5PairPostValidation else {
            throw invalid("required/named tool_choice is not qualified by the native prompt format")
        }
        guard request.responseFormat?.requiresJSONOutput != true || prepared.glm5PairPostValidation else {
            throw invalid("JSON output mode and constrained JSON schemas are not qualified")
        }
        guard !MediaIngest.hasMedia(request) else { throw invalid("native media is not qualified") }
        for message in request.messages {
            if case .parts(let parts) = message.content {
                for part in parts {
                    guard case .text = part else { throw invalid("non-text content requires a verified native media owner") }
                }
            }
        }
        let originalTools = controls.rawGLM5Controls.hasOriginalTools
            ? controls.rawGLM5Controls.originalTools : request.tools
        try ToolConstraintValidation.rejectReservedSchemaMetadata(
            originalTools, allowInternalSchemaMetadata: false)
        guard (originalTools ?? []).allSatisfy({ $0.type == "function" }) else {
            throw invalid("only function tool declarations are supported")
        }
        guard !(originalTools ?? []).contains(where: { $0.function.strict == true }) else {
            throw invalid("strict tool decoding is not qualified")
        }
        try validateHistory(request.messages)

        // Unlike the generic sanitizer, this bridge keeps null object members
        // and array positions. The official template performs result ordering;
        // preserving the original messages also preserves their correlation IDs.
        let messages: [[String: any Sendable]] = try prepared.messages.map { message in
            var value = message.templateMessageDict()
            if let calls = message.toolCalls {
                value["tool_calls"] = try calls.map { call -> [String: any Sendable] in
                    let arguments = try decodeHistoryArguments(call.function.arguments)
                    for (key, value) in arguments {
                        guard !key.isEmpty, !key.contains("<"), !key.contains(">") else {
                            throw invalid("history argument names must not contain native delimiters")
                        }
                        if case .string(let raw) = value,
                            ["<tool_call>", "</tool_call>", "<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>"]
                                .contains(where: raw.contains) {
                            throw invalid("history string contains an ambiguous native delimiter")
                        }
                    }
                    return [
                        "id": call.id, "type": call.type,
                        "function": [
                            "name": call.function.name,
                            "arguments": jinjaObject(arguments.mapValues(jinjaValue)),
                        ] as [String: any Sendable],
                    ]
                }
            }
            return try value.mapValues { try templateValue($0) as any Sendable }
        }
        let visibleTools = prepared.mode == .none ? nil : originalTools
        let tools: [[String: any Sendable]]? = try visibleTools?.map {
            try $0.toolSpec().mapValues { try templateValue($0) as any Sendable }
        }
        return .init(messages: messages, tools: tools, additionalContext: context)
    }

    private static func validateHistory(_ messages: [OpenAIChatMessage]) throws {
        var pending: [Data: String] = [:]
        var completed = Set<Data>()
        for message in messages {
            if message.role == .tool {
                guard message.toolCalls?.isEmpty != false,
                    let id = message.toolCallID, let name = pending[Data(id.utf8)],
                    completed.insert(Data(id.utf8)).inserted
                else { throw invalid("tool results must match a preceding call ID exactly once") }
                if let suppliedName = message.name, !suppliedName.utf8.elementsEqual(name.utf8) {
                    throw invalid("tool result name does not match its call")
                }
                continue
            }
            guard Set(pending.keys) == completed else { throw invalid("history is missing a tool result") }
            pending = [:]
            completed = []
            if let calls = message.toolCalls, !calls.isEmpty {
                guard message.role == .assistant else { throw invalid("only assistant messages may carry tool_calls") }
                for call in calls {
                    guard !call.id.isEmpty, pending[Data(call.id.utf8)] == nil,
                        call.type == "function", ToolChoicePromptPolicy.isValidFunctionName(call.function.name)
                    else { throw invalid("history calls require unique IDs and named function payloads") }
                    pending[Data(call.id.utf8)] = call.function.name
                }
            }
        }
        guard Set(pending.keys) == completed else { throw invalid("history is missing a tool result") }
    }

    /// Reuse the native codec's strict JSON value parser rather than introduce
    /// a second parser with different duplicate-key or numeric-rounding rules.
    /// The fixed outer frame is internal data plumbing, never a model prompt.
    private static func decodeHistoryArguments(_ raw: String) throws -> [String: MLXLMCommon.JSONValue] {
        let frame = "<tool_call>_glm5_history<arg_key>arguments</arg_key><arg_value>"
            + raw + "</arg_value></tool_call>"
        let argumentSchema: [String: any Sendable] = ["type": "object"]
        let properties: [String: any Sendable] = ["arguments": argumentSchema]
        let parameters: [String: any Sendable] = ["type": "object", "properties": properties]
        let function: [String: any Sendable] = ["name": "_glm5_history", "parameters": parameters]
        let tools: [[String: any Sendable]] = [["function": function]]
        guard let call = GLM5ToolCallParser().parse(content: frame, tools: tools),
            case .object(let arguments)? = call.function.arguments["arguments"]
        else { throw invalid("history arguments require a complete, exactly representable JSON object") }
        return arguments
    }

    /// Validate numbers against the original decoder before the typed tool
    /// schema can erase precision. No schema values are retained by this probe.
    private struct ExactSchemaValues: Decodable {
        init(from decoder: any Decoder) throws {
            guard decoder.codingPath.count <= 128 else { throw invalid("tool schema exceeds nesting bound") }
            let value = try decoder.singleValueContainer()
            if value.decodeNil() || (try? value.decode(Bool.self)) != nil
                || (try? value.decode(String.self)) != nil { return }
            if (try? value.decode([String: Self].self)) != nil { return }
            if (try? value.decode([Self].self)) != nil { return }
            let original = try value.decode(Decimal.self)
            let typed = try value.decode(MLXLMCommon.JSONValue.self)
            let encoded = try JSONEncoder().encode(typed)
            guard try JSONDecoder().decode(Decimal.self, from: encoded) == original else {
                throw invalid("tool schema contains an inexact number")
            }
        }
    }

    private static func jinjaValue(_ value: MLXLMCommon.JSONValue) -> Jinja.Value {
        switch value {
        case .null: .null
        case .bool(let value): .boolean(value)
        case .int(let value): .int(value)
        case .double(let value): .double(value)
        case .string(let value): .string(value)
        case .array(let values): .array(values.map(jinjaValue))
        case .object(let values): jinjaObject(values.mapValues(jinjaValue))
        }
    }

    private static func jinjaObject(_ values: [String: Jinja.Value]) -> Jinja.Value {
        .object(.init(uniqueKeysWithValues: values.sorted { $0.key < $1.key }))
    }

    private static func templateValue(_ value: any Sendable) throws -> Jinja.Value {
        if let value = value as? Jinja.Value { return value }
        let typeName = String(reflecting: type(of: value))
        if value is NSNull || (typeName.hasPrefix("MLXLMServer.") && typeName.split(separator: ".").last == "JSONNull") {
            return .null
        }
        if let value = value as? String { return .string(value) }
        if let value = value as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .boolean(value.boolValue) }
            if let integer = value as? Int { return .int(integer) }
            guard value.doubleValue.isFinite else { throw invalid("nonfinite template number") }
            return .double(value.doubleValue)
        }
        if let values = value as? [String: any Sendable] { return jinjaObject(try values.mapValues(templateValue)) }
        if let values = value as? [any Sendable] { return .array(try values.map(templateValue)) }
        throw invalid("unsupported native template value")
    }

    private static func invalid(_ detail: String) -> MultiModelBatchSchedulerEngineError {
        .invalidToolPayload("GLM5: " + detail)
    }
}
