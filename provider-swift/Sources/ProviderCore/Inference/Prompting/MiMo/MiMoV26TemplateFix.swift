// Copyright © 2026 Eigen Labs.

import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer

/// Bounded request-local evidence, not a retained body or diagnostic payload.
/// Invalid values/unknown keys become one fixed flag; arbitrary strings never
/// survive capture. Other families keep their original permissive controls.
struct MiMoV26RawControlEvidence: Sendable, Equatable, Decodable {
    enum Surface: Equatable { case chat, responses }
    var invalid = false
    var unsupportedMediaRichControls = false
    var responseEnableThinking: Bool?
    var responseEffortDisablesThinking: Bool?

    private struct Key: CodingKey {
        let stringValue: String
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        var intValue: Int? { nil }
        init?(intValue: Int) { return nil }
    }
    init() {}
    init(from decoder: any Decoder) throws { self = Self.capture(from: decoder, surface: .chat) }

    static func capture(from decoder: any Decoder, surface: Surface) -> Self {
        var evidence = Self()
        do {
            let root = try decoder.container(keyedBy: Key.self)
            // These keys are omitted by the shared typed request. Keep only a
            // media-local refusal bit, not their raw values or body. Explicit
            // Boolean false / integer zero / null remain no-op controls.
            do {
                if root.contains(Key("logprobs")), try !root.decodeNil(forKey:Key("logprobs")) {
                    if try root.decode(Bool.self,forKey:Key("logprobs")) {
                        evidence.unsupportedMediaRichControls = true
                    }
                }
                if root.contains(Key("top_logprobs")), try !root.decodeNil(forKey:Key("top_logprobs")) {
                    if try root.decode(Int.self,forKey:Key("top_logprobs")) != 0 {
                        evidence.unsupportedMediaRichControls = true
                    }
                }
                if surface == .responses {
                    if root.contains(Key("include")), try !root.decodeNil(forKey:Key("include")),
                       try !root.decode([String].self,forKey:Key("include")).isEmpty {
                        evidence.unsupportedMediaRichControls = true
                    }
                    if root.contains(Key("text")), try !root.decodeNil(forKey:Key("text")) {
                        let text = try root.nestedContainer(keyedBy:Key.self,forKey:Key("text"))
                        if text.allKeys.contains(where:{ $0.stringValue != "format" }) {
                            evidence.unsupportedMediaRichControls = true
                        }
                        if text.contains(Key("format")), try !text.decodeNil(forKey:Key("format")) {
                            let format = try text.nestedContainer(keyedBy:Key.self,forKey:Key("format"))
                            if try format.decode(String.self,forKey:Key("type")) != "text"
                                || format.allKeys.contains(where:{ $0.stringValue != "type" }) {
                                evidence.unsupportedMediaRichControls = true
                            }
                        }
                    }
                }
            } catch { evidence.unsupportedMediaRichControls = true }
            func boolean(_ values: KeyedDecodingContainer<Key>, _ name: String) throws -> Bool? {
                guard values.contains(Key(name)) else { return nil }
                return try values.decode(Bool.self, forKey: Key(name)) // No numeric truthiness.
            }
            func effort(_ values: KeyedDecodingContainer<Key>, _ name: String) throws -> Bool? {
                guard values.contains(Key(name)) else { return nil }
                let value = try values.decode(String.self, forKey: Key(name))
                guard ["none", "off", "0"].contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
                else { evidence.invalid = true; return nil }
                return false
            }
            let top = try boolean(root, "enable_thinking")
            let topEffort = try effort(root, "reasoning_effort")
            if root.contains(Key("preserve_thinking")) { evidence.invalid = true }
            var alias: Bool?
            if root.contains(Key("chat_template_kwargs")) {
                let kwargs = try root.nestedContainer(keyedBy: Key.self, forKey: Key("chat_template_kwargs"))
                if kwargs.allKeys.contains(where: { $0.stringValue != "enable_thinking" }) { evidence.invalid = true }
                alias = try boolean(kwargs, "enable_thinking")
            }
            if root.contains(Key("reasoning")), try !root.decodeNil(forKey: Key("reasoning")) {
                let nested = try root.nestedContainer(keyedBy: Key.self, forKey: Key("reasoning"))
                let allowed = surface == .chat ? ["enabled", "effort"] : ["effort"]
                if nested.allKeys.contains(where: { !allowed.contains($0.stringValue) }) { evidence.invalid = true }
                _ = try boolean(nested, "enabled")
                _ = try effort(nested, "effort")
            }
            if surface == .responses {
                evidence.responseEnableThinking = top ?? alias
                evidence.responseEffortDisablesThinking = topEffort
            }
        } catch {
            evidence.invalid = true
        }
        return evidence
    }

    func validate(modelType: String?) throws {
        guard modelType == "mimo_v2", invalid else { return }
        throw MultiModelBatchSchedulerEngineError.invalidToolPayload("MiMo: invalid or unsupported reasoning controls")
    }
    func validateMedia(modelType: String?) throws {
        guard modelType == "mimo_v2", unsupportedMediaRichControls else { return }
        throw MultiModelBatchSchedulerEngineError.invalidToolPayload("MiMo: unsupported media output controls")
    }
}

/// MiMo's pinned native template is not the Qwen XML/template contract.
/// In particular null parameters are values, strings are emitted verbatim,
/// and tool results carry no rendered IDs. Keep this ahead of the generic
/// null-dropping/Harmony sanitizer, and never infer this family from a name.
enum MiMoV26TemplateFix {
    static func applies(to context: ChatTemplateFixContext) -> Bool {
        context.modelType == "mimo_v2"
    }

    static func normalizeMessages(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        let normalized = try normalizeHistory(messages).map(preserveNulls)
        try validateValues(normalized)
        return normalized
    }

    static func normalizeTools(
        _ tools: [[String: any Sendable]]?
    ) -> [[String: any Sendable]]? {
        tools?.map(preserveNulls)
    }

    /// Validate before typed translation can hide fields. Historical calls do
    /// not have to belong to today's (possibly absent or changed) declarations.
    static func validateRequest(_ request: OpenAIChatCompletionRequest) throws {
        var names = Set<String>()
        for tool in request.tools ?? [] {
            guard tool.type == "function", ToolChoicePromptPolicy.isValidFunctionName(tool.function.name),
                names.insert(tool.function.name).inserted
            else { throw invalid("declared tools need unique valid function names and type=function") }
        }
        for message in request.messages {
            if let calls = message.toolCalls, message.role != .assistant, !calls.isEmpty {
                throw invalid("only assistant messages may carry tool_calls")
            }
            if case .parts(let parts) = message.content {
                for part in parts {
                    if case .unsupported = part { throw invalid("unsupported message content part") }
                }
            }
        }
        _ = try normalizeMessages(request.messages.map { $0.templateMessageDict() })
        if let tools = normalizeTools(request.tools?.map { $0.toolSpec() }) {
            try validateValues(tools)
        }
    }

    /// Strict API admission must run on the original body, before the shared
    /// permissive extension decoder discards wrong-typed controls. This does
    /// not rewrite body bytes or mutate another family's decoding behavior.
    static func validateRawControls(_ body: Data) throws {
        do {
            let evidence = try JSONDecoder().decode(MiMoV26RawControlEvidence.self, from: body)
            try evidence.validate(modelType: "mimo_v2")
        } catch {
            throw invalid("invalid or unsupported reasoning controls")
        }
    }

    /// API controls are projected to the native Boolean; the checkpoint itself
    /// does not consume effort. Absence retains the native ON default. Keep
    /// the existing nested > top-level > kwargs Boolean precedence. Granular
    /// effort and preserve_thinking are explicit refusals, not ignored knobs.
    static func additionalContext(
        request: OpenAIChatCompletionRequest,
        controls: ChatTemplateControls
    ) throws -> [String: any Sendable]? {
        let enabled = try nativeThinkingOverride(request: request, controls: controls)
        var context: [String: any Sendable] = controls.promptDate?.templateContext() ?? [:]
        if let enabled { context["enable_thinking"] = enabled }
        return context.isEmpty ? nil : context
    }

    /// Output permission is independent of parser starting state. Native ON/
    /// unset has a header-only suffix; it does not pre-open a reasoning span.
    static func effectiveThinkingEnabled(
        request: OpenAIChatCompletionRequest, controls: ChatTemplateControls
    ) throws -> Bool {
        try nativeThinkingOverride(request: request, controls: controls) ?? true
    }

    private static func nativeThinkingOverride(
        request: OpenAIChatCompletionRequest, controls: ChatTemplateControls
    ) throws -> Bool? {
        try controls.rawMiMoControls.validate(modelType: "mimo_v2")
        guard controls.preserveThinking == nil else {
            throw invalid("preserve_thinking is unsupported; native history always preserves reasoning_content")
        }
        let rawEffort = try controls.reasoningEffort.map(thinkingFromEffort)
        let nestedEffort = try request.reasoning?.effort.map(thinkingFromEffort)
        return request.reasoning?.enabled ?? controls.rawMiMoControls.responseEnableThinking
            ?? controls.enableThinking ?? nestedEffort
            ?? controls.rawMiMoControls.responseEffortDisablesThinking ?? rawEffort
    }

    private static func thinkingFromEffort(_ effort: String) throws -> Bool {
        switch effort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "off", "0": return false
        default: throw invalid("native MiMo supports binary thinking, not granular reasoning effort")
        }
    }

    private static func validateValues(_ values: any Sendable) throws {
        // Real Jinja is the conversion authority; do not claim an unsupported
        // input succeeded by replacing it with an empty object or string.
        let value: Jinja.Value
        do { value = try Jinja.Value(any: values) }
        catch { throw invalid("unsupported native template value") }
        var remaining = 1_000_000
        func visit(_ value: Jinja.Value, depth: Int) throws {
            guard depth <= 128, remaining > 0 else { throw invalid("template value exceeds nesting/node bounds") }
            remaining -= 1
            switch value {
            case .array(let values):
                for value in values { try visit(value, depth: depth + 1) }
            case .object(let values):
                for value in values.values { try visit(value, depth: depth + 1) }
            case .double(let value):
                guard value.isFinite else { throw invalid("nonfinite template number") }
            case .null, .boolean, .int, .string: break
            default: throw invalid("native template values must be JSON data")
            }
        }
        try visit(value, depth: 0)
    }

    /// This bridge does not drop array slots or object keys. Keep other values
    /// unchanged (including unsupported values, which real Jinja must reject).
    /// MLXLMServer.toolSpec() uses a private JSONNull type; match that module
    /// and terminal type name, not every user type containing "JSONNull".
    private static func preserveNulls(_ object: [String: any Sendable]) -> [String: any Sendable] {
        object.mapValues(preserveNullValue)
    }

    private static func preserveNullValue(_ value: any Sendable) -> any Sendable {
        let typeName = String(reflecting: type(of: value))
        if value is NSNull || (typeName.hasPrefix("MLXLMServer.")
            && typeName.split(separator: ".").last == "JSONNull")
        {
            return Jinja.Value.null
        }
        if let object = value as? [String: any Sendable] {
            return preserveNulls(object)
        }
        if let array = value as? [any Sendable] {
            return array.map(preserveNullValue)
        }
        return value
    }

    /// A direct primitive argument array is not the HTTP string "[1,null]".
    /// The latter intentionally takes the template's raw-string branch; the
    /// former makes `items` silently empty in Swift-Jinja and is rejected here.
    static func normalizeHistory(
        _ messages: [[String: any Sendable]]
    ) throws -> [[String: any Sendable]] {
        var output: [[String: any Sendable]] = []
        var seenIDs = Set<Data>()
        var pending: [(id: String, name: String)] = []
        var results: [Data: [String: any Sendable]] = [:]

        func orderedResults() throws -> [[String: any Sendable]] {
            guard results.count == pending.count else {
                throw invalid("all tool results must precede the next non-tool message or end of history")
            }
            return try pending.map { call in
                guard let result = results[Data(call.id.utf8)] else {
                    throw invalid("history is missing a tool result")
                }
                return result
            }
        }

        for (index, message) in messages.enumerated() {
            guard let role = message["role"] as? String,
                ["system", "user", "assistant", "tool"].contains(role)
            else { throw invalid("messages[\(index)].role is unsupported") }
            if let content = message["content"], !(content is String), !(content is NSNull),
                !(content is [any Sendable]), (content as? Jinja.Value)?.isNull != true
            {
                throw invalid("message content must be a string, part array, or null")
            }
            if let reasoning = message["reasoning_content"], !(reasoning is String),
                !(reasoning is NSNull), (reasoning as? Jinja.Value)?.isNull != true
            {
                throw invalid("reasoning_content must be a string or null")
            }

            if role == "tool" {
                guard let id = message["tool_call_id"] as? String,
                    let call = pending.first(where: { sameBytes($0.id, id) }),
                    results[Data(id.utf8)] == nil
                else { throw invalid("tool results must match each preceding call ID exactly once") }
                if let name = message["name"] {
                    guard let name = name as? String, sameBytes(name, call.name) else {
                        throw invalid("tool result name does not match its call")
                    }
                }
                guard message["tool_calls"] == nil else {
                    throw invalid("only assistant messages may carry tool_calls")
                }
                results[Data(id.utf8)] = message
                continue
            }

            // The native prompt does not render result IDs. A complete result
            // batch can arrive out of order at the API; order the entire
            // untouched messages by call ID without crossing another turn.
            output.append(contentsOf: try orderedResults())
            pending = []
            results = [:]
            output.append(message)
            guard let rawCalls = message["tool_calls"] else { continue }
            guard role == "assistant", let calls = rawCalls as? [any Sendable] else {
                throw invalid("tool_calls must be an assistant array")
            }
            for call in calls {
                guard let call = call as? [String: any Sendable],
                    let id = call["id"] as? String, !id.isEmpty,
                    seenIDs.insert(Data(id.utf8)).inserted,
                    (call["type"] as? String) == "function",
                    let function = call["function"] as? [String: any Sendable],
                    let name = function["name"] as? String,
                    ToolChoicePromptPolicy.isValidFunctionName(name)
                else { throw invalid("history calls need unique nonempty IDs and named function payloads") }
                guard let arguments = function["arguments"],
                    arguments is String || arguments is [String: any Sendable]
                else { throw invalid("history function.arguments must be a raw string or object") }
                // Native XML has no escaping for parameter names or closing
                // delimiters. Do not silently emit a different call structure.
                if let arguments = arguments as? [String: any Sendable] {
                    for (key, value) in arguments {
                        guard !key.isEmpty, !key.contains(">"), !key.contains("<"),
                            !key.contains("\n"), !key.contains("\r")
                        else { throw invalid("history parameter name cannot be represented by native MiMo framing") }
                        if let raw = value as? String,
                            raw.contains("</parameter>")
                        {
                            throw invalid("history string contains an ambiguous native parameter delimiter")
                        }
                    }
                }
                if let raw = arguments as? String,
                    ["</function>", "</tool_call>"].contains(where: raw.contains)
                {
                    throw invalid("raw history arguments contain an ambiguous native call delimiter")
                }
                pending.append((id, name))
            }
        }
        output.append(contentsOf: try orderedResults())
        return output
    }

    private static func sameBytes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.elementsEqual(rhs.utf8)
    }

    private static func invalid(_ message: String) -> MultiModelBatchSchedulerEngineError {
        .invalidToolPayload("MiMo: " + message)
    }
}
