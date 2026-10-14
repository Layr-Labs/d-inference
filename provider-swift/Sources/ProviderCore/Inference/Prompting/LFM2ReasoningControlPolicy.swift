// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMServer

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
