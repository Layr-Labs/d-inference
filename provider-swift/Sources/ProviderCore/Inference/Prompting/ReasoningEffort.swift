// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// A reasoning effort a client names, least reasoning first: OpenAI's and
/// OpenRouter's `none` through `xhigh`, and `max`. Every model that reasons
/// takes all seven, as `reasoning_effort` or `reasoning.effort`; its template
/// receives a level it renders.
enum ReasoningEffort: String, CaseIterable, Comparable, Sendable {
    case none, minimal, low, medium, high, xhigh, max

    /// The names a refusal lists.
    static let acceptedNames = allCases.map(\.rawValue).joined(separator: ", ")

    /// A client's value, trimmed and in any case: one of the seven names, or
    /// `off` or `0`, which mean `none`. GLM-5.3-Flash and Flint read the
    /// names exactly as written (`init(rawValue:)`).
    init?(clientValue value: String) {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name == "off" || name == "0" {
            self = Self.none
        } else if let effort = Self(rawValue: name) {
            self = effort
        } else {
            return nil
        }
    }

    /// Whether a client's value switches thinking off: `none`, `off` or `0`.
    static func switchesThinkingOff(_ value: String) -> Bool {
        Self(clientValue: value) == ReasoningEffort.none
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The level of a model's own `levels` (lowest first) this effort selects:
    /// its own where the model has it, else the next one up (an effort between
    /// two levels rounds up, toward more reasoning), and the highest past them
    /// all. So `minimal` selects the lowest level and `max` the highest, and
    /// `none` the lowest where thinking can't be switched off.
    func level(in levels: [ReasoningEffort]) -> ReasoningEffort {
        precondition(!levels.isEmpty, "a model with named levels has at least one")
        return levels.first { $0 >= self } ?? levels[levels.count - 1]
    }
}

/// Where a request named its reasoning effort; a refusal names it.
public enum ReasoningEffortField: String, Sendable {
    case reasoningEffort = "reasoning_effort"
    case reasoningObject = "reasoning.effort"
    case templateKwargs = "chat_template_kwargs.reasoning_effort"

    /// The refusal of an effort that is none of the names: fixed text, never
    /// the value sent.
    var refusalMessage: String { "\(rawValue) must be one of: \(ReasoningEffort.acceptedNames)." }
}

/// The reasoning effort of the families whose template context
/// `MultiModelBatchSchedulerEngine.templateAdditionalContext` builds. MiMo,
/// GLM-5.3, Flint and Nemotron 3.5 Super resolve theirs in their own prompt
/// policies, with the same names and rounding.
enum ReasoningEffortPolicy {
    /// The levels of the Qwen 3.8 template, which raises for any other effort
    /// while thinking: `xhigh` is its default. The Qwen 3.5 template family
    /// (Qwen 3.5, 3.6 and 3.8, and Bonsai 2) and the owned Qwen 3.8 Flash-Next
    /// build receive one of them; the 3.5 and 3.6 templates and Bonsai's read
    /// only the thinking switch. `high`, the effort clients send most, renders
    /// as `xhigh`, as the coordinator's first-party pool sends it.
    static let qwen38Levels: [ReasoningEffort] = [.low, .medium, .xhigh]

    /// Model types whose templates reason: an effort none of the seven names
    /// is refused for them. Any other model ignores the effort.
    /// `qwen3_vl_moe` is left out: it holds instruct-only Qwen3-VL builds.
    private static let reasoningModelTypes: Set<String> = [
        "qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35", "qwen4_exp", "qwen4_exp_text",
        "gemma4", "gemma4_text", "gemma4_vision", "diffusion_gemma", "gpt_oss",
        "nemotron_h", "nemotron_h_omni", "mimo_v2", "glm5_next", "glm5_next_text", "glm5_next_mtp", "flint",
    ]

    /// The levels a model's template renders through `reasoning_effort`, lowest
    /// first; nil when its template reads no effort this policy maps.
    static func namedLevels(modelID: String, modelType: String?) -> [ReasoningEffort]? {
        if ["qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35"].contains(normalized(modelType))
            || Qwen4SupportPolicy.ownsEffortTemplate(modelID: modelID, modelType: modelType)
        {
            return qwen38Levels
        }
        return nil
    }

    /// Whether a model reasons, by its template family.
    static func reasons(modelID: String, modelType: String?) -> Bool {
        namedLevels(modelID: modelID, modelType: modelType) != nil
            || normalized(modelType).map { reasoningModelTypes.contains($0) } == true
    }

    /// Refuses the effort a request names when a model that reasons can't take
    /// it, with the field it came in; the typed `reasoning.effort` wins over the
    /// top-level spelling, as in the template context. A model that doesn't
    /// reason ignores it.
    static func validate(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) throws {
        guard reasons(modelID: request.model, modelType: modelType) else { return }
        let named = request.reasoning?.effort.map { ($0, ReasoningEffortField.reasoningObject) }
            ?? controls.reasoningEffort.map { ($0, ReasoningEffortField.reasoningEffort) }
        if case let (effort, field)? = named, ReasoningEffort(clientValue: effort) == nil {
            throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(field)
        }
    }

    private static func normalized(_ modelType: String?) -> String? {
        modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// The `reasoning_effort` a template receives for `effort`: while thinking,
    /// the model's level for it (`namedLevels`); otherwise, and for a model
    /// without named levels, the effort as sent, which such a template ignores.
    /// GPT-OSS keeps its Harmony serving policy (`high` renders as `medium`).
    static func templateEffort(
        _ effort: String, modelID: String, modelType: String?, thinking: Bool?
    ) -> String {
        if thinking != false, let levels = namedLevels(modelID: modelID, modelType: modelType),
            let named = ReasoningEffort(clientValue: effort)
        {
            return named.level(in: levels).rawValue
        }
        let context = ChatTemplateFixContext(modelId: modelID, modelType: modelType)
        return GPTOSSHarmonyTemplateFix.effectiveReasoningEffort(effort, context: context) ?? effort
    }
}
