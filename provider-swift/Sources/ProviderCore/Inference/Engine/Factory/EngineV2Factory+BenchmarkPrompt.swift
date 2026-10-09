import Foundation
import MLXLMCommon
import ProviderCoreFoundation

extension EngineV2Factory {
    @_spi(Benchmarking)
    public struct BenchmarkPrompt: Sendable {
        public let tokens: [Int]
        public let renderDate: String
        public let sampling: CBv2SamplingParams
        /// Verified header boundary before the first user content, when the
        /// model's normalized template provides a supported structural audit.
        public let instructionPrefixTokens: Int?
    }

    /// Preserve request-owned date and the HTTP body's production normalization.
    /// Raw token probes do not ingest media or exercise HTTP tool constraints.
    @_spi(Benchmarking)
    public static func benchmarkPrompt(
        body: Data, tokenizer: any MLXLMCommon.Tokenizer, modelType: String?,
        defaultDate: PromptRenderDate
    ) throws -> BenchmarkPrompt {
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        guard !MediaIngest.hasMedia(request) else {
            throw BenchmarkPromptError.mediaRequiresHTTP
        }
        let supplied = ProviderLoop.extractChatTemplateControls(from: body)
        let controls = supplied.promptDate == nil ? supplied.withPromptDate(defaultDate) : supplied
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        let overrides = ProviderLoop.extractSamplingOverrides(from: body)
        let logprobs = ProviderLoop.extractLogprobsSpec(from: body)
        let translated = MultiModelBatchSchedulerEngine.translate(
            openAIRequest: request, defaultMaxTokens: request.maxTokens ?? 1,
            logprobs: logprobs?.requested, topLogprobs: logprobs?.topLogprobs,
            logitBias: overrides?.logitBias, seed: overrides?.seed)
        let sampling = EngineV2Translation.samplingParams(from: translated)
        guard request.stop?.isEmpty != false, request.responseFormat == nil else {
            throw BenchmarkPromptError.outputControlsRequireHTTP
        }
        // Preserve existing greedy tool-template diagnostics; they make no
        // HTTP enforcement claim. Sampled throughput inputs cannot silently
        // bypass a forced tool constraint.
        guard sampling.temperature == 0 || !prepared.requiresToolCall else {
            throw BenchmarkPromptError.outputControlsRequireHTTP
        }
        let normalized = try ProviderPromptContractPipeline.normalizedInput(
            prepared: prepared, request: request,
            modelType: modelType, templateControls: controls)
        let tokens = try tokenizer.applyChatTemplate(messages: normalized.messages,
            tools: normalized.tools, additionalContext: normalized.additionalContext)
        let prefix = BenchmarkInstructionPrefix.count(input: normalized, fullTokens: tokens,
            tokenizer: tokenizer, modelType: modelType)
        return BenchmarkPrompt(tokens: tokens, renderDate: controls.promptDate!.value,
                               sampling: sampling, instructionPrefixTokens: prefix)
    }

    @_spi(Benchmarking)
    public static func benchmarkRuntimeIdentity() -> [String: String] {
        var result = [
            "normalization": PromptContractIdentity.normalizationVersion,
            "renderer": PromptContractIdentity.rendererVersion,
            "tokenizer": PromptContractIdentity.tokenizerVersion,
        ]
        result["binary_sha256"] = PrefixCachePolicy.checkpointBinaryHash
        result["metallib_sha256"] = metallibHash()
        return result
    }

    enum BenchmarkPromptError: Error { case mediaRequiresHTTP, outputControlsRequireHTTP }
}
