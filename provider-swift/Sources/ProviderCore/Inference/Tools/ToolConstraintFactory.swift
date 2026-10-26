// Copyright © 2026 Eigen Labs.
//
// Production bridge from a normalized OpenAI request to native CBv2 token
// constraints. Vocabulary decoding is cached per loaded tokenizer; schemas
// and grammar state remain per request. Qwen4 uses its rendered native channel
// boundary and opaque framed arguments; Gemma keeps its own schema automaton.

import Foundation
import ProviderCoreFoundation
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
        stopTokenIDs: Set<Int>,
        nativePromptTokens: [Int]? = nil
    ) throws -> (any CBv2TokenConstraint)? {
        // Flint's automatic reasoning protocol needs framing even for no-tool
        // and auto requests. Do not broaden another family's admission policy.
        if modelContext.modelType == "flint" {
            guard let nativePromptTokens, !nativePromptTokens.isEmpty,
                  tokenizer.inner.decode(tokenIds: Array(nativePromptTokens.suffix(32)),
                    skipSpecialTokens: false).hasSuffix("<|assistant|>") else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "Flint native protocol requires the rendered assistant boundary")
            }
            do {
                // Client stops apply to visible answer bytes only. They are
                // matched here and in the stream filter, never by the engine's
                // raw-text holdback, which cannot see reasoning or call frames.
                let stops = try validatedStops(request.stop, owner: "Flint")
                let vocabulary = try FlintNativeVocabulary.cached(for: tokenizer, stopTokenIDs: stopTokenIDs)
                let constraint = try FlintNativeProtocolConstraint(mode: prepared.mode,
                    maxTokens: request.maxTokens ?? defaultMaxTokens, vocabulary: vocabulary,
                    allowsParallel: prepared.allowsParallelCalls, allowedToolNames: prepared.allowedToolNames,
                    tools: prepared.tools?.map { $0.toolSpec() }, responseFormat: prepared.responseFormat?.grammar)
                guard !stops.isEmpty else { return constraint }
                return FlintAnswerStopConstraint(base: constraint, vocabulary: vocabulary,
                    stops: FlintAnswerStops(stops))
            } catch let error as ToolConstraintSchemaError {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(error.localizedDescription)
            }
        }
        guard prepared.mode.requiresInferenceConstraint else { return nil }
        // `.none` keeps Gemma's sampler guard when its prompt contract is
        // pinned, while every other family retains the existing prompt-only
        // behavior (the tools are removed before rendering).
        if prepared.mode == .none {
            guard Gemma4TemplateFix.applies(to: modelContext),
                tokenizer.toolConstraintContractVerified
            else { return nil }
        } else {
            let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(
                mode: prepared.mode, modelContext: modelContext)
            if strategy == .structuredPostValidation {
                if Qwen4ModelIdentity.isQualified(modelContext.modelId),
                   modelContext.modelType == "qwen4_exp" {
                    guard let nativePromptTokens, !nativePromptTokens.isEmpty,
                          let prefix = ReasoningPromptProbe.streamingPrefix(forPromptTail:
                            tokenizer.inner.decode(tokenIds: Array(nativePromptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                                skipSpecialTokens: false)) else {
                        throw ToolConstraintSchemaError.invalid("Native Qwen4 tool framing requires the rendered prompt boundary")
                    }
                    return try Qwen4NativeToolConstraint(mode: prepared.mode,
                        maxTokens: request.maxTokens ?? defaultMaxTokens,
                        vocabulary: tokenizer.qwen4FramingVocabulary(stopTokenIDs: stopTokenIDs),
                        nativePrefix: prefix, allowsParallel: prepared.allowsParallelCalls,
                        allowedToolNames: prepared.allowedToolNames)
                }
                // The structured parser withholds call bytes until finish; the
                // shared validator below the stream rejects missing, wrong,
                // undeclared, or schema-invalid calls before exposing them.
                return nil
            }
            guard tokenizer.toolConstraintContractVerified else {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    "inference-enforced tool_choice requires the pinned Gemma prompt contract")
            }
        }

        guard Gemma4TemplateFix.applies(to: modelContext) else {
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
                let stops = try validatedStops(
                    request.stop, owner: "inference-enforced tool_choice"
                ).map { Array($0.utf8) }
                if stops.isEmpty { return grammar }
                return try ForbiddenSubstringTokenConstraint(
                    base: grammar, vocabulary: vocabulary, patterns: stops)
            } catch let error as ToolConstraintSchemaError {
                throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                    error.localizedDescription)
            }
        }
    }

    /// Non-empty client stop sequences within the native constraint limits.
    private static func validatedStops(_ stops: [String]?, owner: String) throws -> [String] {
        let stops = stops?.filter { !$0.isEmpty } ?? []
        guard stops.count <= maxStopSequences, stops.allSatisfy({ $0.utf8.count <= maxStopBytes }) else {
            throw ToolConstraintSchemaError.unsupported(
                "\(owner) stop sequences exceed the \(maxStopSequences)-sequence or "
                    + "\(maxStopBytes)-byte safety limit")
        }
        return stops
    }
}
