// Copyright © 2026 Eigen Labs.

import MLXLMCommon
import MLXLMServer

/// Selects the enforcement boundary for forced tool choices. Gemma keeps its
/// token-level grammar; Qwen's published XML tool format is prompt-forced and
/// then rejected fail-closed unless parsing, function selection, and schema
/// validation all succeed before any call is exposed to the client.
enum ToolChoiceEnforcementPolicy {
    enum Strategy: Equatable {
        case none
        case gemmaGrammar
        case qwenPostValidation
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
        if Qwen35TemplateFix.applies(to: modelContext) { return .qwenPostValidation }
        throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "inference-enforced tool_choice is unsupported for this model family")
    }

    /// Whether this concrete advertised model can honor required/named tool
    /// choice. Gemma's sampler grammar remains bound to its pinned template;
    /// Qwen is enforced by prompt forcing plus withheld post-validation.
    static func advertisesCapability(for model: ModelInfo) -> Bool {
        let context = ChatTemplateFixContext(
            modelId: model.id, modelType: model.modelType)
        if Gemma4TemplateFix.applies(to: context) {
            return model.toolConstraintTemplateHash
                == Gemma4ToolConstraintContract.pinnedTemplateSHA256
        }
        return Qwen35TemplateFix.applies(to: context)
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
        case .qwenPostValidation:
            guard format == .xmlFunction else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced Qwen tool_choice requires the qwen3_coder tool parser")
            }
        }
    }
}
