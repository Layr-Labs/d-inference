// Copyright © 2026 Eigen Labs.
//
// OpenRouter / OpenAI reasoning-request normalization.
//
// Qwen3.6's published chat template (EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8)
// pre-opens `<think>` unless `enable_thinking` is defined AND boolean false:
//
//     {%- if enable_thinking is defined and enable_thinking is false %}
//         {{- '<think>\n\n</think>\n\n' }}
//     {%- else %}
//         {{- '<think>\n' }}
//     {%- endif %}
//
// OpenRouter's disable shapes are broader than `reasoning.enabled=false`.
// This type is the single decode of every disable / exclude signal we accept
// so the template switch, the prompt-tail closer, and the response strip
// cannot drift.

import Foundation

struct ReasoningControls: Sendable, Equatable {
    /// `nil` means the caller did not choose — the template keeps its default
    /// (thinking ON for Qwen3.6).
    var thinkingEnabled: Bool?
    /// OpenRouter / OpenAI effort string (`low`/`medium`/`high`/`none`/…).
    var effort: String?
    /// Think internally but omit the trace from the response (`exclude: true`
    /// or `include_reasoning: false`).
    var excludeFromResponse: Bool

    static let unspecified = ReasoningControls()

    var thinkingDisabled: Bool { thinkingEnabled == false }

    /// Drop `reasoning` / `reasoning_content` from the consumer-visible body.
    var suppressOutput: Bool { thinkingDisabled || excludeFromResponse }

    /// Effort value that is safe to inject into a chat template. `"none"` is
    /// omitted — Harmony / gpt-oss templates do not define that level, and
    /// disable is already expressed via `enable_thinking=false`.
    var effortForTemplate: String? {
        guard let effort, !Self.isNoneEffort(effort) else { return nil }
        return effort
    }

    init(
        thinkingEnabled: Bool? = nil,
        effort: String? = nil,
        excludeFromResponse: Bool = false
    ) {
        self.thinkingEnabled = thinkingEnabled
        self.effort = effort
        self.excludeFromResponse = excludeFromResponse
    }

    func merging(requestEnabled: Bool?, effort: String?) -> ReasoningControls {
        var merged = self
        if merged.thinkingEnabled == nil {
            merged.thinkingEnabled = requestEnabled
        }
        if merged.effort == nil {
            merged.effort = Self.trimmed(effort)
        }
        if let mergedEffort = merged.effort, Self.isNoneEffort(mergedEffort) {
            merged.thinkingEnabled = false
        }
        return merged
    }

    static func parse(from data: Data) -> ReasoningControls {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unspecified
        }
        return parse(object: object)
    }

    static func parse(object: [String: Any]) -> ReasoningControls {
        var controls = ReasoningControls()

        if let flag = object["enable_thinking"] as? Bool, flag == false {
            controls.thinkingEnabled = false
        }
        if let kwargs = object["chat_template_kwargs"] as? [String: Any],
            let flag = kwargs["enable_thinking"] as? Bool, flag == false
        {
            controls.thinkingEnabled = false
        }

        if let includeReasoning = object["include_reasoning"] as? Bool, includeReasoning == false {
            controls.excludeFromResponse = true
        }

        if let effort = trimmed(object["reasoning_effort"] as? String) {
            controls.effort = effort
            if isNoneEffort(effort) {
                controls.thinkingEnabled = false
            }
        }

        applyReasoningValue(object["reasoning"], to: &controls)
        return controls
    }

    static func isNoneEffort(_ raw: String) -> Bool {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "off", "disabled":
            return true
        default:
            return false
        }
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func applyReasoningValue(_ value: Any?, to controls: inout ReasoningControls) {
        if let flag = value as? Bool {
            controls.thinkingEnabled = flag
            return
        }
        guard let object = value as? [String: Any] else { return }

        if let enabled = object["enabled"] as? Bool {
            controls.thinkingEnabled = enabled
        }
        if let effort = trimmed(object["effort"] as? String) {
            controls.effort = effort
            if isNoneEffort(effort) {
                controls.thinkingEnabled = false
            }
        }
        if let exclude = object["exclude"] as? Bool, exclude {
            controls.excludeFromResponse = true
        }
        if maxTokensIsZero(object["max_tokens"]) {
            controls.thinkingEnabled = false
        }
    }

    private static func maxTokensIsZero(_ value: Any?) -> Bool {
        switch value {
        case let number as Int:
            return number == 0
        case let number as Int64:
            return number == 0
        case let number as Double:
            return number == 0
        case let number as NSNumber:
            return number.intValue == 0 && number.doubleValue == 0
        case let text as String:
            return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) == 0
        default:
            return false
        }
    }
}
