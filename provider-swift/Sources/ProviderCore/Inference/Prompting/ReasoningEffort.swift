// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// A reasoning effort a client names, least reasoning first: OpenAI's and
/// OpenRouter's `none` through `xhigh`, and `max`, which Hermes sends.
///
/// On one Mac, on a pair's leader and on the coordinator's path alike:
/// - A model that reasons takes each of the seven, as `reasoning_effort` or
///   `reasoning.effort`, and never answers one with a 400: its family's table
///   (below) gives the level its template renders.
/// - A value that is none of the seven is refused before anything renders or
///   is reserved, with `MultiModelBatchSchedulerEngineError
///   .unsupportedReasoningEffort(field)`. The local API answers it with the
///   field and the seven names, never the value sent
///   (`ReasoningEffortField.refusalMessage`); the coordinator shows its own
///   closed text.
/// - Nemotron 3.5 Super reads both fields and refuses two that differ, even
///   two names, with `.conflictingReasoningEfforts`, which the local API
///   answers in the same shape, naming both fields
///   (`ReasoningEffortField.conflictMessage`).
/// - A model that doesn't reason ignores the effort, whatever it is
///   (`ReasoningEffortPolicy.reasons`).
enum ReasoningEffort: String, CaseIterable, Sendable {
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
}

/// Each family's table: the level its template renders for each of the seven
/// efforts. A family gets the effort's own level where it has one, else the
/// next one up (toward more reasoning), and its highest past them all, so
/// `minimal` gets its lowest level and `max` its highest; `none` switches
/// thinking off where the model can. Each switch names all seven efforts and
/// has no `default`, so a table that misses one doesn't build;
/// `ReasoningEffortValuesTests.everyFamilyTableCoversEveryEffort` checks
/// every row against that rule.
///
/// The other families take every effort too. Flint decides for itself whether
/// to reason and reads no effort (`FlintRequestPolicy`). Gemma 4 and Nemotron
/// 3.5 Lightning have only a thinking switch: `none` turns it off, and any
/// other effort reaches the template as sent, which keeps its default. GPT-OSS
/// gets each as sent, except `high`, which renders `medium`
/// (`GPTOSSHarmonyTemplateFix`). The coordinator's prompt sidecar plans Gemma
/// 4's and GPT-OSS's prompts, so they change only together with it.
extension ReasoningEffort {
    /// Qwen 3.8's template renders `low`, `medium` and `xhigh` (its default)
    /// and raises for any other effort while thinking. The Qwen 3.5 template
    /// family (Qwen 3.5, 3.6 and 3.8, and Bonsai 2) and the owned Flash-Next
    /// build get these levels (`ReasoningEffortPolicy.takesQwen38Levels`); the
    /// 3.5, 3.6 and Bonsai templates read only the thinking switch. `high`, the
    /// effort clients send most, renders `xhigh`, as the coordinator's
    /// first-party pool sends it. `none` gets a level only when a switch keeps
    /// thinking on.
    var qwen38Level: ReasoningEffort {
        switch self {
        case .none, .minimal, .low: .low
        case .medium: .medium
        case .high, .xhigh, .max: .xhigh
        }
    }

    /// GLM-5.3-Flash's template renders `low`, `high` and `max` (its default);
    /// nil switches thinking off. The coordinator's pool and prompt sidecar
    /// map the same way.
    var glmLevel: GLM5NextPromptPolicy.Effort? {
        switch self {
        case .none: nil
        case .minimal, .low: .low
        case .medium, .high: .high
        case .xhigh, .max: .max
        }
    }

    /// Nemotron 3.5 Super's template has two depths, `medium_effort` and its
    /// default: this is the `medium_effort` an effort sets, and nil switches
    /// thinking off.
    var nemotronSuperMediumEffort: Bool? {
        switch self {
        case .none: nil
        case .minimal, .low, .medium: true
        case .high, .xhigh, .max: false
        }
    }

    /// MiMo V2.6 and DiffusionGemma reason at one depth, so an effort only
    /// switches thinking: on for every effort but `none`.
    var oneDepthThinking: Bool {
        switch self {
        case .none: false
        case .minimal, .low, .medium, .high, .xhigh, .max: true
        }
    }
}

/// Where a request named its reasoning effort; a refusal names it.
public enum ReasoningEffortField: String, Sendable {
    case reasoningEffort = "reasoning_effort"
    case reasoningObject = "reasoning.effort"
    case templateKwargs = "chat_template_kwargs.reasoning_effort"

    /// The refusal of an effort that is none of the names: the field and the
    /// seven names, fixed text, never the value sent.
    var refusalMessage: String { "\(rawValue) must be one of: \(ReasoningEffort.acceptedNames)." }

    /// The refusal of `reasoning_effort` and `reasoning.effort` that differ,
    /// where a model reads both rather than letting one win (Nemotron 3.5
    /// Super): its `param` names both fields, and its message names both and
    /// the seven names, fixed text, never the values sent.
    static let conflictParam = "\(Self.reasoningEffort.rawValue), \(Self.reasoningObject.rawValue)"
    static let conflictMessage = "\(Self.reasoningEffort.rawValue) and \(Self.reasoningObject.rawValue) must be "
        + "the same when both are sent, one of: \(ReasoningEffort.acceptedNames)."
}

/// Which models reason, and the `reasoning_effort` the template context
/// `MultiModelBatchSchedulerEngine.templateAdditionalContext` builds. MiMo,
/// GLM-5.3, Flint and Nemotron 3.5 Super read the effort in their own prompt
/// policies, through their tables above.
enum ReasoningEffortPolicy {
    /// Model types whose templates reason: an effort none of the seven names
    /// is refused for them. Any other model ignores the effort.
    /// `qwen3_vl_moe` is left out: it holds instruct-only Qwen3-VL builds.
    private static let reasoningModelTypes: Set<String> = [
        "qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35", "qwen4_exp", "qwen4_exp_text",
        "gemma4", "gemma4_text", "gemma4_vision", "diffusion_gemma", "gpt_oss",
        "nemotron_h", "nemotron_h_omni", "mimo_v2", "glm5_next", "glm5_next_text", "glm5_next_mtp", "flint",
    ]

    /// The Qwen 3.5 template family's model types.
    private static let qwen35TemplateTypes: Set<String> = ["qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35"]

    /// Whether a model's template gets Qwen 3.8's levels
    /// (`ReasoningEffort.qwen38Level`): the Qwen 3.5 template family, and the
    /// owned Flash-Next build (`Qwen4SupportPolicy.ownsEffortTemplate`).
    static func takesQwen38Levels(modelID: String, modelType: String?) -> Bool {
        normalized(modelType).map(qwen35TemplateTypes.contains) == true
            || Qwen4SupportPolicy.ownsEffortTemplate(modelID: modelID, modelType: modelType)
    }

    /// Whether a model reasons, by its template family.
    static func reasons(modelID: String, modelType: String?) -> Bool {
        takesQwen38Levels(modelID: modelID, modelType: modelType)
            || normalized(modelType).map(reasoningModelTypes.contains) == true
    }

    /// Refuses an effort that is none of the seven names, on a model that
    /// reasons, naming the field it came in. The typed `reasoning.effort` wins
    /// over the top-level spelling, as in the template context. A model that
    /// doesn't reason ignores the effort.
    static func validate(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) throws {
        guard reasons(modelID: request.model, modelType: modelType) else { return }
        if let effort = request.reasoning?.effort {
            guard ReasoningEffort(clientValue: effort) != nil else {
                throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningObject)
            }
        } else if let effort = controls.reasoningEffort, ReasoningEffort(clientValue: effort) == nil {
            throw MultiModelBatchSchedulerEngineError.unsupportedReasoningEffort(.reasoningEffort)
        }
    }

    /// The `reasoning_effort` a template receives for `effort`: while
    /// thinking, Qwen 3.8's level for it where the model takes those levels;
    /// otherwise the effort as sent (a Qwen template ignores it with thinking
    /// off), except that GPT-OSS's Harmony policy renders `high` as `medium`.
    static func templateEffort(
        _ effort: String, modelID: String, modelType: String?, thinking: Bool?
    ) -> String {
        if thinking != false, takesQwen38Levels(modelID: modelID, modelType: modelType),
            let named = ReasoningEffort(clientValue: effort)
        {
            return named.qwen38Level.rawValue
        }
        let context = ChatTemplateFixContext(modelId: modelID, modelType: modelType)
        return GPTOSSHarmonyTemplateFix.effectiveReasoningEffort(effort, context: context) ?? effort
    }

    private static func normalized(_ modelType: String?) -> String? {
        modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
