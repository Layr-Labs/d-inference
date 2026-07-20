// Copyright © 2026 Eigen Labs.
//
// Production bridge from a normalized OpenAI request to the Gemma token
// automaton installed on CBv2. Vocabulary decoding is cached per loaded
// tokenizer; schemas and grammar state remain per request.

import Foundation
import MLXLMCommon
import MLXLMServer

enum ToolConstraintFactory {
    private static let maxStopSequences = 4
    private static let maxStopBytes = 256

    static func make(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelContext: ChatTemplateFixContext,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>
    ) throws -> (any CBv2TokenConstraint)? {
        guard prepared.mode.requiresInferenceGrammar else { return nil }
        guard Gemma4TemplateFix.applies(to: modelContext),
            tokenizer.toolConstraintContractVerified
        else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "inference-enforced tool_choice requires the pinned Gemma prompt contract")
        }
        let maxTokens = request.maxTokens ?? defaultMaxTokens
        guard maxTokens > 0 else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "max_tokens must be positive for inference-enforced tool_choice")
        }
        let vocabulary: GemmaTokenVocabulary
        do {
            vocabulary = try tokenizer.gemmaVocabulary(
                stopTokenIDs: stopTokenIDs)
        } catch let error as ToolConstraintSchemaError {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                error.localizedDescription)
        }

        switch prepared.mode {
        case .auto:
            return nil
        case .none:
            return GemmaNoToolTokenConstraint(
                maxTokens: maxTokens, vocabulary: vocabulary)
        case .required, .named:
            guard let tools = prepared.compiledTools else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "required tool_choice schema was not compiled")
            }
            do {
                let grammar = try GemmaToolCallTokenConstraint(
                    mode: prepared.mode,
                    tools: tools,
                    allowsParallel: prepared.allowsParallelCalls,
                    maxTokens: maxTokens,
                    vocabulary: vocabulary)
                let stops = request.stop?
                    .filter { !$0.isEmpty }
                    .map { Array($0.utf8) } ?? []
                guard stops.count <= maxStopSequences,
                    stops.allSatisfy({ $0.count <= maxStopBytes })
                else {
                    throw ToolConstraintSchemaError.unsupported(
                        "inference-enforced tool_choice stop sequences exceed "
                            + "the \(maxStopSequences)-sequence or "
                            + "\(maxStopBytes)-byte safety limit")
                }
                if stops.isEmpty { return grammar }
                return try ForbiddenSubstringTokenConstraint(
                    base: grammar, vocabulary: vocabulary, patterns: stops)
            } catch let error as ToolConstraintSchemaError {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    error.localizedDescription)
            }
        }
    }

}
