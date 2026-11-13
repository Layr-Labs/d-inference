// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Muse Glimmer's request controls.
///
/// Its template reads one reasoning control, `reasoning_strength` (`low`,
/// `medium`, `high` or `xhigh`; `high` when absent), and nothing switches its
/// reasoning off. A caller that declines reasoning gets the lowest strength
/// and, like Flint's, the answer without the reasoning text.
enum MuseGlimmerRequestPolicy {
    static let strengthKey = "reasoning_strength"

    /// The reasoning part of one request's template context.
    ///
    /// - A thinking switch set to off (`reasoning.enabled`, else
    ///   `enable_thinking`) selects `low`, whatever effort came with it: the
    ///   same precedence the other families give an explicit Boolean.
    /// - Otherwise an effort selects its strength
    ///   (`ReasoningEffort.museGlimmerStrength`).
    /// - Otherwise nothing is set and the template keeps its default.
    ///
    /// An effort that is none of the names was refused before this
    /// (`ReasoningEffortPolicy.validate`).
    static func templateContext(
        effort: String?, request: OpenAIChatCompletionRequest, controls: ChatTemplateControls
    ) -> [String: any Sendable] {
        if (request.reasoning?.enabled ?? controls.enableThinking) == false {
            return [strengthKey: ReasoningEffort.low.rawValue]
        }
        guard let strength = effort.flatMap(ReasoningEffort.init(clientValue:))?.museGlimmerStrength else {
            return [:]
        }
        return [strengthKey: strength.rawValue]
    }

    /// The caller declined reasoning the model still writes
    /// (`reasoning.exclude`, `include_reasoning: false` or
    /// `reasoning.enabled: false`). It is generated and counted as reasoning
    /// tokens, never framed.
    static func withholdsReasoning(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) -> Bool {
        MuseGlimmerModelPolicy.isModelType(modelType)
            && (controls.rawFlintControls.withholdsReasoning || request.reasoning?.enabled == false)
    }

    /// The model's tool calls are ATEM invokes on a tool channel, read by the
    /// ATEM parser alone. Nil for any other model.
    static func toolCallFormat(requested: String?, modelType: String?) throws -> ToolCallFormat? {
        guard MuseGlimmerModelPolicy.isModelType(modelType) else { return nil }
        let name = requested?.lowercased().replacingOccurrences(of: "-", with: "_")
        guard name.map(["auto", "atem", "muse", MuseGlimmerModelPolicy.modelType].contains) ?? true else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "Muse Glimmer requires its native ATEM tool parser")
        }
        return .atem
    }
}
