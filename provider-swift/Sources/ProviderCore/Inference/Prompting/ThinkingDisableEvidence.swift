// Copyright © 2026 Eigen Labs.
import Foundation

/// Request fields that ask a chat template to stop reasoning. Raw values are
/// the public wire spellings, so a rejection can name the field without
/// echoing any caller-supplied value.
public enum ThinkingDisableField: String, CaseIterable, Sendable, Equatable {
    case enableThinking = "enable_thinking"
    case chatTemplateKwargsEnableThinking = "chat_template_kwargs.enable_thinking"
    case reasoningEnabled = "reasoning.enabled"
    case reasoningEffort = "reasoning.effort"
    case topLevelReasoningEffort = "reasoning_effort"
    /// Top-level `thinking: false` (an OpenRouter-forwarded alias).
    case thinking = "thinking"
    /// Anthropic Messages `thinking: {"type": "disabled"}`; the coordinator
    /// lowers `/v1/messages` to the chat shape with this key kept.
    case thinkingType = "thinking.type"
    /// `chat_template_kwargs.thinking: false` (the alias MiMo honors).
    case chatTemplateKwargsThinking = "chat_template_kwargs.thinking"
}

/// Every disable control present in the raw body, captured before the
/// existing precedence merge (top-level `enable_thinking` over its kwargs
/// alias, typed `reasoning` over both) can hide a shadowed one.
struct ThinkingDisableEvidence: Sendable, Equatable {
    private(set) var fields: Set<ThinkingDisableField>

    init(fields: Set<ThinkingDisableField> = []) { self.fields = fields }

    private struct RawKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ name: String) { stringValue = name }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Type mismatches stay ignored, matching the permissive control decode:
    /// only a Boolean `false`, an effort the provider treats as "off"
    /// (`none`/`off`/`0`) or an Anthropic `thinking.type` of `disabled`
    /// counts as a disable request.
    static func capture(from decoder: any Decoder) -> Self {
        var evidence = Self()
        guard let root = try? decoder.container(keyedBy: RawKey.self) else { return evidence }
        func isFalse(_ values: KeyedDecodingContainer<RawKey>, _ name: String) -> Bool {
            (try? values.decode(Bool.self, forKey: RawKey(name))) == false
        }
        func disablesThinking(_ values: KeyedDecodingContainer<RawKey>, _ name: String) -> Bool {
            ChatTemplateControls(reasoningEffort: try? values.decode(String.self, forKey: RawKey(name)))
                .effortDisablesThinking
        }
        if isFalse(root, "enable_thinking") { evidence.fields.insert(.enableThinking) }
        if disablesThinking(root, "reasoning_effort") { evidence.fields.insert(.topLevelReasoningEffort) }
        if isFalse(root, "thinking") { evidence.fields.insert(.thinking) }
        if let thinking = try? root.nestedContainer(keyedBy: RawKey.self, forKey: RawKey("thinking")),
           let type = try? thinking.decode(String.self, forKey: RawKey("type")),
           type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "disabled"
        {
            evidence.fields.insert(.thinkingType)
        }
        if let kwargs = try? root.nestedContainer(keyedBy: RawKey.self, forKey: RawKey("chat_template_kwargs")) {
            if isFalse(kwargs, "enable_thinking") { evidence.fields.insert(.chatTemplateKwargsEnableThinking) }
            if isFalse(kwargs, "thinking") { evidence.fields.insert(.chatTemplateKwargsThinking) }
        }
        if let reasoning = try? root.nestedContainer(keyedBy: RawKey.self, forKey: RawKey("reasoning")) {
            if isFalse(reasoning, "enabled") { evidence.fields.insert(.reasoningEnabled) }
            if disablesThinking(reasoning, "effort") { evidence.fields.insert(.reasoningEffort) }
        }
        return evidence
    }
}

extension ChatTemplateControls {
    func withThinkingDisableEvidence(_ evidence: ThinkingDisableEvidence) -> Self {
        var copy = self
        copy.thinkingDisableEvidence = evidence
        return copy
    }
}
