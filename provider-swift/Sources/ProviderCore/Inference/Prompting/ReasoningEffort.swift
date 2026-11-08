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
/// to reason and reads no effort (`FlintRequestPolicy`). Nemotron 3.5
/// Lightning has only a thinking switch: `none` turns it off, and any other
/// effort reaches the template as sent, which keeps its default (on).
///
/// The coordinator maps every effort from a copy of these tables, in its
/// ingress refusal, its first-party pool and its prompt sidecar, which plans
/// these prompts for cache-aware routing.
/// `fixtures/prompt-contract/v1/reasoning_effort_vectors.json` is the
/// contract between the two. `scripts/generate-reasoning-effort-vectors.py`
/// restates these tables and writes it, and
/// `CachePromptParityTests.reasoningEffortVectors` runs every case through
/// the production prompt pipeline; darkbloom-platform copies the file byte
/// for byte and tests its copies against it. So a change to a table, or a
/// model type that starts or stops reasoning, changes the script and the file
/// in the same commit, and the platform takes that commit's file.
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

    /// MiMo V2.6, Gemma 4 and DiffusionGemma reason at one depth, so an effort
    /// only switches thinking: on for every effort but `none`. (Gemma 4's
    /// template defaults thinking off.)
    var oneDepthThinking: Bool {
        switch self {
        case .none: false
        case .minimal, .low, .medium, .high, .xhigh, .max: true
        }
    }

    /// GPT-OSS's Harmony levels are `low`, `medium` (its default) and `high`.
    /// Harmony can't switch its reasoning off, so `none` gets `low`. The
    /// coordinator caps OpenRouter's traffic at `medium` (#703); a direct
    /// caller's `high` renders `high`.
    var harmonyLevel: ReasoningEffort {
        switch self {
        case .none, .minimal, .low: .low
        case .medium: .medium
        case .high, .xhigh, .max: .high
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
}

/// Which models reason, and the `reasoning_effort` the template context
/// `MultiModelBatchSchedulerEngine.templateAdditionalContext` builds. MiMo,
/// GLM-5.3, Flint and Nemotron 3.5 Super read the effort in their own prompt
/// policies, through their tables above.
enum ReasoningEffortPolicy {
    // The sets below are listed in `reasoning_effort_vectors.json`, and each
    // copy that keeps one checks it for equality
    // (`CachePromptParityTests.reasoningEffortVectors`), so a type added or
    // dropped on one side only fails a test on the other.

    /// Model types whose templates reason: an effort none of the seven names
    /// is refused for them. Any other model ignores the effort.
    /// `qwen3_vl_moe` is left out: it holds instruct-only Qwen3-VL builds.
    static let reasoningModelTypes: Set<String> = [
        "qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35", "qwen4_exp", "qwen4_exp_text",
        "gemma4", "gemma4_text", "gemma4_vision", "diffusion_gemma", "gpt_oss",
        "nemotron_h", "nemotron_h_omni", "mimo_v2", "glm5_next", "glm5_next_text", "glm5_next_mtp", "flint",
    ]

    /// The Qwen 3.5 template family's model types.
    static let qwen35TemplateTypes: Set<String> = ["qwen3_5", "qwen3_5_moe", "prism_hadamard_qwen35"]

    /// Model types whose template has a thinking switch and no effort level,
    /// so an effort sets the switch (`ReasoningEffort.oneDepthThinking`): Gemma
    /// 4 and DiffusionGemma.
    static let effortSwitchTypes: Set<String> = ["gemma4", "gemma4_text", "gemma4_vision", "diffusion_gemma"]

    /// Whether an effort sets a model's thinking switch, Gemma 4's and
    /// DiffusionGemma's, in the template context `templateAdditionalContext`
    /// builds.
    static func effortSetsThinkingSwitch(modelType: String?) -> Bool {
        normalized(modelType).map(effortSwitchTypes.contains) == true
    }

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
    /// GPT-OSS's Harmony level, thinking or not; otherwise the effort as sent
    /// (a Qwen template ignores it with thinking off). A value that is none of
    /// the names is passed as sent: `validate` refuses it for a model that
    /// reasons.
    static func templateEffort(
        _ effort: String, modelID: String, modelType: String?, thinking: Bool?
    ) -> String {
        guard let named = ReasoningEffort(clientValue: effort) else { return effort }
        if thinking != false, takesQwen38Levels(modelID: modelID, modelType: modelType) {
            return named.qwen38Level.rawValue
        }
        if GPTOSSHarmonyTemplateFix.applies(to: ChatTemplateFixContext(modelId: modelID, modelType: modelType)) {
            return named.harmonyLevel.rawValue
        }
        return effort
    }

    private static func normalized(_ modelType: String?) -> String? {
        modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
