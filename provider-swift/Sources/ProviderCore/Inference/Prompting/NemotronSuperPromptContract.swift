import CryptoKit
import Foundation
import Jinja
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation

/// Prompt contract for the exact pinned Super VL template, matching the
/// reference `apply_chat_template` plus `processing_nemotron_h_omni.py`
/// placeholder expansion. It does not admit a model, execute media, or
/// validate output.
enum NemotronSuperPromptContract {
    static let templateSHA256 = "1369e90b19976f99ce2070eb21ade8fcb4af640f008e14e82af5c5e89a9cc816"
    static let vocabularySize = 131072
    static let imageTokenID = 18
    static let imageStartTokenID = 19
    static let imageEndTokenID = 20

    enum Failure: Error {
        case templateMismatch, unsupportedControl, conflictingControls, unsupportedMedia
        case invalidToolArguments, toolDeclarationMismatch, invalidTokens, contextExceeded
    }

    /// Effective template and parser controls. Absent values take the pinned
    /// template's defaults; `forceNonemptyContent` is the ultra_v3 parser option.
    struct Controls: Equatable, Sendable {
        var enableThinking = true
        var mediumEffort = false
        var truncateHistoryThinking = true
        var forceNonemptyContent = false
    }

    /// Verified pinned template, prepared for swift-jinja: comment whitespace
    /// control is normalized and the Python `string` filter is rebound. Render
    /// it only with ``additionalContext(_:)``.
    static func verifiedTemplate(_ bytes: Data) throws -> String {
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == templateSHA256,
            let source = String(data: bytes, encoding: .utf8)
        else { throw Failure.templateMismatch }
        return NemotronSuperTemplateFilters.bind(template: normalizeSwiftJinjaTemplate(source))
    }

    private struct RawControls: Decodable {
        let enabled: Bool?
        let medium: Bool?
        let truncate: Bool?
        let forceContent: Bool?
        let effort: String?
        let nestedEnabled: Bool?
        let nestedEffort: String?
        enum Keys: String, CodingKey {
            case enabled = "enable_thinking", medium = "medium_effort"
            case truncate = "truncate_history_thinking", effort = "reasoning_effort"
            case forceContent = "force_nonempty_content", thinking
            case kwargs = "chat_template_kwargs", reasoning, preserve = "preserve_thinking"
        }
        enum ReasoningKeys: String, CodingKey { case enabled, effort }
        /// The kwargs this contract reads: the template's switches, OpenRouter's
        /// `thinking` spelling of `enable_thinking`, and the parser's
        /// `force_nonempty_content`. Any other kwarg would be dropped by the template.
        static let templateKwargs = Set([Keys.enabled, .thinking, .medium, .truncate, .forceContent].map(\.rawValue))
        /// Responses `reasoning.summary` levels; the full reasoning is returned for each.
        static let summaryLevels: Set<String> = ["auto", "concise", "detailed"]
        init(from decoder: any Decoder) throws {
            try Self.refuseUnhonoredFields(decoder)
            let values = try decoder.container(keyedBy: Keys.self)
            let kwargs = try values.nestedOptionalContainer(keyedBy: Keys.self, forKey: .kwargs)
            func boolean(_ key: Keys) throws -> Bool? {
                let top = try values.decodeIfPresent(Bool.self, forKey: key)
                let alias = try kwargs?.decodeIfPresent(Bool.self, forKey: key)
                if let top, let alias, top != alias { throw Failure.conflictingControls }
                return top ?? alias
            }
            let thinking = try kwargs?.decodeIfPresent(Bool.self, forKey: .thinking)
            let enableThinking = try boolean(.enabled)
            if let thinking, let enableThinking, thinking != enableThinking { throw Failure.conflictingControls }
            enabled = enableThinking ?? thinking
            medium = try boolean(.medium)
            truncate = try boolean(.truncate)
            forceContent = try boolean(.forceContent)
            // This generic alias has different semantics; do not silently lose it.
            guard !values.contains(.preserve) else { throw Failure.unsupportedControl }
            effort = try values.decodeIfPresent(String.self, forKey: .effort)
            let reasoning = try values.nestedOptionalContainer(keyedBy: ReasoningKeys.self, forKey: .reasoning)
            nestedEnabled = try reasoning?.decodeIfPresent(Bool.self, forKey: .enabled)
            nestedEffort = try reasoning?.decodeIfPresent(String.self, forKey: .effort)
        }

        /// Fields the pinned template cannot honor are refused, never dropped:
        /// `chat_template_kwargs` beyond `templateKwargs`, and `reasoning` members
        /// beyond `effort` and `enabled` unless null, `exclude: false` (its default
        /// meaning) or a `summary` level. The coordinator's sidecar applies the same rule.
        private static func refuseUnhonoredFields(_ decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: AnyKey.self)
            if let kwargs = try values.nestedOptionalContainer(keyedBy: AnyKey.self,
                    forKey: AnyKey(Keys.kwargs.rawValue)),
                !kwargs.allKeys.allSatisfy({ templateKwargs.contains($0.stringValue) }) {
                throw Failure.unsupportedControl
            }
            guard let reasoning = try values.nestedOptionalContainer(keyedBy: AnyKey.self,
                forKey: AnyKey(Keys.reasoning.rawValue)) else { return }
            for key in reasoning.allKeys where ReasoningKeys(stringValue: key.stringValue) == nil {
                if try reasoning.decodeNil(forKey: key) { continue }
                switch key.stringValue {
                case "exclude" where (try? reasoning.decode(Bool.self, forKey: key)) == false: continue
                case "summary" where summaryLevels.contains((try? reasoning.decode(String.self, forKey: key)) ?? ""):
                    continue
                default: throw Failure.unsupportedControl
                }
            }
        }
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// The official template defaults thinking on even for images. Medium effort
    /// is a separate template boolean, not the generic reasoning_effort key.
    /// Contradictory spellings of one control are refused, never reconciled.
    static func controls(body: Data) throws -> Controls {
        let raw = try JSONDecoder().decode(RawControls.self, from: body)
        func normalized(_ value: String?) -> String? {
            value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let effort = normalized(raw.nestedEffort ?? raw.effort)
        if let effort, !["none", "off", "0", "medium", "high"].contains(effort) {
            throw Failure.unsupportedControl
        }
        if let top = normalized(raw.effort), let nested = normalized(raw.nestedEffort), top != nested {
            throw Failure.conflictingControls
        }
        if let top = raw.enabled, let nested = raw.nestedEnabled, top != nested {
            throw Failure.conflictingControls
        }
        let disabled = ["none", "off", "0"].contains(effort ?? "")
        let enabled = raw.nestedEnabled ?? raw.enabled ?? !disabled
        if let explicit = raw.nestedEnabled ?? raw.enabled, effort != nil,
            explicit == disabled { throw Failure.conflictingControls }
        if let medium = raw.medium, effort == "medium" || effort == "high",
            medium != (effort == "medium") { throw Failure.conflictingControls }
        let medium = raw.medium ?? (effort == "medium")
        guard !(medium && !enabled) else { throw Failure.conflictingControls }
        return Controls(enableThinking: enabled, mediumEffort: medium,
            truncateHistoryThinking: raw.truncate ?? true,
            forceNonemptyContent: raw.forceContent ?? false)
    }

    static func additionalContext(body: Data) throws -> [String: any Sendable] {
        additionalContext(try controls(body: body))
    }

    /// Template variables plus the Python-compatible filters bound by
    /// ``verifiedTemplate(_:)``.
    static func additionalContext(_ controls: Controls) -> [String: any Sendable] {
        var context = NemotronSuperTemplateFilters.context
        context["enable_thinking"] = controls.enableThinking
        context["medium_effort"] = controls.mediumEffort
        context["truncate_history_thinking"] = controls.truncateHistoryThinking
        return context
    }

    /// Reference prompt tokens. `messages` must already carry the provider's
    /// tool-choice and response-format instructions; tool declarations are
    /// taken from the raw body in request order and filtered to `declared`.
    static func render(messages: [OpenAIChatMessage], body: Data, declared: [OpenAITool]?,
        controls: Controls, templateBytes: Data, tokenizer: any MLXLMCommon.Tokenizer,
        addGenerationPrompt: Bool = true) throws -> [Int] {
        let template = try verifiedTemplate(templateBytes)
        var context = additionalContext(controls)
        if let tools = try toolValues(body: body, declared: declared) { context["tools"] = tools }
        // swift-transformers applies additional context after its own default.
        context["add_generation_prompt"] = addGenerationPrompt
        let tokens = try tokenizer.applyChatTemplate(messages: self.messages(messages),
            chatTemplate: template, tools: nil, additionalContext: context)
        guard !tokens.isEmpty, tokens.allSatisfy({ (0..<vocabularySize).contains($0) }) else {
            throw Failure.invalidTokens
        }
        return tokens
    }

    /// Template messages with request-order tool-call arguments. Image slots
    /// keep their positions; URLs stay opaque and are never fetched here.
    static func messages(_ messages: [OpenAIChatMessage]) throws -> [[String: any Sendable]] {
        try messages.map { message in
            var value: [String: any Sendable] = ["role": message.role.rawValue,
                                                 "content": try content(message.content)]
            if let name = message.name { value["name"] = name }
            if let id = message.toolCallID { value["tool_call_id"] = id }
            if let calls = message.toolCalls, !calls.isEmpty {
                value["tool_calls"] = Value.array(try calls.map(toolCall))
            }
            if let reasoning = message.reasoningContent { value["reasoning_content"] = reasoning }
            return value
        }
    }

    private static func content(_ content: OpenAIMessageContent) throws -> Value {
        switch content {
        case .null: return .null
        case .text(let text): return .string(text)
        case .parts(let parts):
            return .array(try parts.map { part -> Value in
                switch part {
                case .text(let text): return .object(["type": "text", "text": .string(text)])
                case .imageURL(let uri):
                    return .object(["type": "image_url", "image_url": .object(["url": .string(uri)])])
                case .videoURL, .inputAudio, .unsupported: throw Failure.unsupportedMedia
                }
            })
        }
    }

    /// vLLM decodes OpenAI's JSON-string arguments before rendering; empty
    /// arguments become an empty mapping.
    private static func toolCall(_ call: OpenAIToolCall) throws -> Value {
        let arguments: Value
        if call.function.arguments.isEmpty {
            arguments = .object([:])
        } else {
            do { arguments = try NemotronSuperOrderedJSON.parse(call.function.arguments) }
            catch { throw Failure.invalidToolArguments }
        }
        return .object(["id": .string(call.id), "type": .string(call.type),
            "function": .object(["name": .string(call.function.name), "arguments": arguments])])
    }

    private static func toolValues(body: Data, declared: [OpenAITool]?) throws -> Value? {
        guard let declared, !declared.isEmpty else { return nil }
        guard case .object(let root) = try NemotronSuperOrderedJSON.parse(body),
            case .array(let raw)? = root["tools"] else { throw Failure.toolDeclarationMismatch }
        let names = Set(declared.map(\.function.name))
        let selected = raw.filter { tool in
            guard case .object(let object) = tool else { return false }
            let function: Value? = object["function"] ?? tool
            guard case .object(let fields)? = function, case .string(let name)? = fields["name"] else {
                return false
            }
            return names.contains(name)
        }
        guard selected.count == declared.count else { throw Failure.toolDeclarationMismatch }
        return .array(selected)
    }

    /// Reference image prompt: the pinned template over the request's messages
    /// and controls, then each `<image>` slot expanded with its image's feature
    /// count. The image owner refuses tools and structured output beforehand.
    static func imagePrompt(messages: [OpenAIChatMessage], body: Data, templateBytes: Data,
        tokenizer: any MLXLMCommon.Tokenizer, featureCounts: [Int], contextLength: Int) throws -> [Int] {
        let tokens = try render(messages: messages, body: body, declared: nil,
            controls: controls(body: body), templateBytes: templateBytes, tokenizer: tokenizer)
        return try expandImagePlaceholders(tokens, featureCounts: featureCounts,
                                           contextLength: contextLength)
    }

    /// processing_nemotron_h_omni.py replaces each `<image>` with `<img>`, one
    /// `<image>` per visual feature, and `</img>`; feature counts are in order.
    static func expandImagePlaceholders(_ tokens: [Int], featureCounts: [Int],
        contextLength: Int) throws -> [Int] {
        guard tokens.filter({ $0 == imageTokenID }).count == featureCounts.count,
            featureCounts.allSatisfy({ $0 > 0 }) else { throw Failure.unsupportedMedia }
        var expanded: [Int] = []
        var image = 0
        for token in tokens {
            let span = token == imageTokenID ? featureCounts[image] + 2 : 1
            guard span <= contextLength - expanded.count else { throw Failure.contextExceeded }
            if token == imageTokenID {
                expanded.append(imageStartTokenID)
                expanded.append(contentsOf: repeatElement(imageTokenID, count: featureCounts[image]))
                expanded.append(imageEndTokenID)
                image += 1
            } else {
                expanded.append(token)
            }
        }
        return expanded
    }
}

private extension KeyedDecodingContainer {
    func nestedOptionalContainer<NestedKey: CodingKey>(
        keyedBy type: NestedKey.Type, forKey key: Key
    ) throws -> KeyedDecodingContainer<NestedKey>? {
        guard contains(key), try !decodeNil(forKey: key) else { return nil }
        return try nestedContainer(keyedBy: type, forKey: key)
    }
}
