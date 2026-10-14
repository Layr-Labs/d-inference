// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMServer

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

/// LFM2.5-24B-A2B is reasoning-only: its template has no thinking switch and
/// the generation prompt always opens `<think>`. A request asking to disable
/// reasoning is refused before acceptance, model load or template render
/// rather than silently served with reasoning on. Effort hints that do not
/// disable reasoning (`low`/`medium`/`high`, or none) are accepted and have no
/// effect on the prompt. Exact listing ids only; other families are untouched.
enum LFM2ReasoningControlPolicy {
    static func rejectionMessage(for field: ThinkingDisableField) -> String {
        "Reasoning cannot be disabled for this model (offending field: \(field.rawValue)). "
            + "Omit the field; reasoning effort hints are accepted but have no effect."
    }

    /// The first disable control in the fixed `ThinkingDisableField` order,
    /// from raw-body evidence plus the typed request/controls (in-process and
    /// typed Responses callers carry no raw body).
    static func disableField(
        request: OpenAIChatCompletionRequest,
        controls: ChatTemplateControls
    ) -> ThinkingDisableField? {
        var fields = controls.thinkingDisableEvidence.fields
        if request.reasoning?.enabled == false { fields.insert(.reasoningEnabled) }
        if ChatTemplateControls(reasoningEffort: request.reasoning?.effort).effortDisablesThinking {
            fields.insert(.reasoningEffort)
        }
        if controls.enableThinking == false,
           fields.isDisjoint(with: [.enableThinking, .chatTemplateKwargsEnableThinking])
        {
            fields.insert(.enableThinking)
        }
        if controls.effortDisablesThinking { fields.insert(.topLevelReasoningEffort) }
        return ThinkingDisableField.allCases.first(where: fields.contains)
    }

    static func validate(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls) throws {
        guard EngineV2SupportedModels.isLFM25ListingModelID(request.model),
              let field = disableField(request: request, controls: controls)
        else { return }
        throw MultiModelBatchSchedulerEngineError.reasoningCannotBeDisabled(field)
    }
}
