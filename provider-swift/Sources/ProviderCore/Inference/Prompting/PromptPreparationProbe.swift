// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Benchmark seam for the text path's prompt preparation: exactly the work
/// between the `prompt_prep_start` and `prompt_prep_end` profile stamps
/// (normalization, chat-template render and tokenization). Decoding and tool
/// policy run once at construction, as they do before the stamps.
public struct PromptPreparationProbe {
    private let prepared: ToolChoicePromptPolicy.Prepared
    private let request: OpenAIChatCompletionRequest
    private let controls: ChatTemplateControls
    private let modelType: String?

    public init(body: Data, modelType: String?) throws {
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        request = inbound.request
        controls = inbound.extensions.templateControls.resolvingPromptDate()
        prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        self.modelType = modelType
    }

    /// The admission path's body decode (`merged`), or the same reads as the
    /// strict request decode followed by per-field extractions, for timing.
    public static func decodeBody(_ body: Data, merged: Bool) throws {
        if merged {
            _ = try ProviderLoop.decodeInboundChatRequest(body)
        } else {
            _ = try ProviderLoop.decodeOpenAIRequest(body)
            _ = ProviderLoop.extractChatTemplateControls(from: body)
            _ = ProviderLoop.extractLogprobsSpec(from: body)
            _ = ProviderLoop.extractSamplingOverrides(from: body)
        }
    }

    /// Whether the merged decode reads exactly what the separate calls read.
    public static func bodyDecodesAgree(_ body: Data) throws -> Bool {
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        let logprobs = ProviderLoop.extractLogprobsSpec(from: body)
        return try inbound.request == ProviderLoop.decodeOpenAIRequest(body)
            && inbound.extensions.templateControls == ProviderLoop.extractChatTemplateControls(from: body)
            && inbound.extensions.logprobsSpec?.topLogprobs == logprobs?.topLogprobs
            && inbound.extensions.logprobsSpec?.requested == logprobs?.requested
            && inbound.extensions.samplingOverrides == ProviderLoop.extractSamplingOverrides(from: body)
    }

    /// `promptCacheScope` nil takes the unchanged tokenizer path.
    public func promptTokens(tokenizer: any MLXLMCommon.Tokenizer, promptCacheScope: String?) throws -> [Int] {
        try ProviderPromptContractPipeline.tokenize(
            prepared: prepared, request: request, tokenizer: tokenizer, modelType: modelType,
            templateControls: controls, promptCacheScope: promptCacheScope)
    }

    /// Whether this tokenizer serves scoped prompts from a prompt token cache.
    public static func promptCacheIsActive(_ tokenizer: any MLXLMCommon.Tokenizer) -> Bool {
        (tokenizer as? any PromptTokenCaching)?.promptTokenCache?.isActive == true
    }

    /// The chat-template loop rewrites the prompt token cache renders with.
    public static func templateLoopRewrites(_ tokenizer: any MLXLMCommon.Tokenizer) -> [String] {
        (tokenizer as? any PromptTokenCaching)?.promptTokenCache?.templateLoopRewrites ?? []
    }
}
