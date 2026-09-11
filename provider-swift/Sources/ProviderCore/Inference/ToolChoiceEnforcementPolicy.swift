// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Selects the enforcement boundary for forced tool choices. Gemma keeps its
/// token-level grammar; supported native structured formats are prompt-forced and
/// then rejected fail-closed unless parsing, function selection, and schema
/// validation all succeed before any call is exposed to the client.
enum ToolChoiceEnforcementPolicy {
    enum Strategy: Equatable {
        case none
        case gemmaGrammar
        case structuredPostValidation
    }

    static let qwen38ConstrainedModelID = "EigenLabs/Qwen3.8-27B-4bit"

    static func isFramingWhitespace(_ text: String) -> Bool {
        // XML framing whitespace only. Foundation's broader character set
        // also includes invisible Unicode characters that are not framing.
        text.utf8.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
    }

    static func forcedStrategy(
        mode: ToolConstraintMode,
        modelContext: ChatTemplateFixContext
    ) throws -> Strategy {
        switch mode {
        case .required, .named:
            break
        case .none, .auto:
            return .none
        }

        if Gemma4TemplateFix.applies(to: modelContext) { return .gemmaGrammar }
        if Qwen35TemplateFix.applies(to: modelContext) || nativeStructuredTarget(modelContext) {
            return .structuredPostValidation
        }
        throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "inference-enforced tool_choice is unsupported for this model family")
    }

    /// Whether this concrete advertised model can honor required/named tool
    /// choice. Gemma's sampler grammar remains bound to its pinned template;
    /// native Qwen/Nemotron use prompt forcing plus withheld post-validation.
    static func advertisesCapability(for model: ModelInfo) -> Bool {
        let context = ChatTemplateFixContext(
            modelId: model.id, modelType: model.modelType)
        if Gemma4TemplateFix.applies(to: context) {
            return model.toolConstraintTemplateHash
                == Gemma4ToolConstraintContract.pinnedTemplateSHA256
        }
        if nativeStructuredTarget(context) {
            return true
        }
        return model.id == qwen38ConstrainedModelID
            && Qwen35TemplateFix.applies(to: context)
    }

    /// Explicit family admission is supplied by each model onboarding change.
    /// Shared tool-frame validation alone must not advertise a new model.
    static func nativeStructuredTarget(_ context: ChatTemplateFixContext) -> Bool {
        context.modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "nemotron_h"
            && EngineV2SupportedModels.isNemotron35ListingModelID(context.modelId)
    }

    static func validateParser(
        _ format: ToolCallFormat,
        strategy: Strategy
    ) throws {
        switch strategy {
        case .none:
            return
        case .gemmaGrammar:
            guard format == .gemma else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced Gemma tool_choice requires the gemma tool parser")
            }
        case .structuredPostValidation:
            guard format == .xmlFunction || format == .nemotron else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced structured tool_choice requires an XML or Nemotron tool parser")
            }
        }
    }
}
