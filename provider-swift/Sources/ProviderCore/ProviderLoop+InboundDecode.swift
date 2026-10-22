// Inbound chat-request decoding. Accepts the upstream OpenAI shape
// (`OpenAIChatCompletionRequest`) and, on the cold path, normalises a
// handful of valid-but-strictly-rejected OpenAI shapes (hosted/custom
// tools, content-less messages, the `developer` role) before retrying.
//
// #252: the previous implementation fell back to the legacy
// `ChatCompletionRequest` decoder inside the `catch` and threw *its*
// error, masking the real reason the primary decode failed — the classic
// "Key 'function' not found … tools[0]" red herring that comes from the
// legacy `ToolDefinition` decoder, not the parser that actually runs
// first. The legacy lift also silently dropped `tools` whenever it
// succeeded. Both problems are gone here: we surface the primary
// decoder's error, and we preserve tools/content through the
// normalisation retry (see ``InboundChatNormalization``).

import Foundation
import MLXLMServer

extension ProviderLoop {

    /// Decode an inbound chat request into the upstream
    /// `OpenAIChatCompletionRequest`.
    ///
    /// Fast path: a strict decode, unchanged for well-formed requests
    /// (zero overhead, identical behaviour). Cold path: if the strict
    /// decode fails, normalise the known valid-but-rejected OpenAI shapes
    /// and retry. We never substitute a misleading fallback error — if
    /// normalisation can't repair the body, the strict-decoder error is
    /// surfaced as-is.
    internal static func decodeOpenAIRequest(
        _ data: Data
    ) throws -> OpenAIChatCompletionRequest {
        try decodeRepairedOpenAIRequest(repairedRequestBody(data))
    }

    /// `decodeOpenAIRequest` plus the body extensions, equal to the separate
    /// calls. When the repairs leave the body untouched (requests without
    /// tools or legacy function calls), one parse serves the strict request
    /// and every extension instead of five.
    internal static func decodeInboundChatRequest(_ data: Data) throws -> InboundChatRequest {
        let repaired = try repairedRequestBody(data)
        if repaired == data,
            let decoded = try? JSONDecoder().decode(InboundChatRequest.self, from: data)
        {
            return decoded
        }
        // The extensions always come from the original bytes, like the
        // per-field extractors; the request keeps the strict and repair paths.
        return InboundChatRequest(
            request: try decodeRepairedOpenAIRequest(repaired),
            extensions: InboundChatExtensions(from: data))
    }

    private static func repairedRequestBody(_ data: Data) throws -> Data {
        // Inject default `type`s into tool parameter schemas so a Gemma-style
        // chat template's `{{ value['type'] | upper }}` can't crash on a typeless
        // property (DAR-130). No-op for requests without tools.
        let data = ToolSchemaNormalization.ensureParameterTypes(in: data)
        // Legacy assistant `function_call` is an unknown field to the upstream
        // decoder, so normalize it before the strict fast path can silently drop
        // it and leave a following tool/function result orphaned for Harmony.
        return try InboundChatNormalization.normalizeLegacyFunctionCalls(in: data)
    }

    private static func decodeRepairedOpenAIRequest(
        _ data: Data
    ) throws -> OpenAIChatCompletionRequest {
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(OpenAIChatCompletionRequest.self, from: data)
        } catch let primaryError {
            let normalized: Data
            do {
                normalized = try InboundChatNormalization.normalize(data)
            } catch let roleError as MultiModelBatchSchedulerEngineError {
                // A clear, typed 400 (e.g. an unsupported role naming the
                // offending value) is more useful than the raw decoder
                // error — surface it directly.
                throw roleError
            } catch {
                // The body isn't a JSON object we can repair. Surface the
                // genuine strict-decoder error, never a masked fallback.
                throw primaryError
            }
            // Re-run the strict decoder on the repaired body. If it still
            // fails, that error is the real, unmasked problem: hosted
            // tools, content-less messages, and role aliases have already
            // been handled, so it cannot be the #252 `tools[0].function`
            // red herring.
            return try decoder.decode(OpenAIChatCompletionRequest.self, from: normalized)
        }
    }

    /// Recover Qwen3.8 template controls that intentionally are not protocol
    /// fields. Each optional field is decoded independently so one malformed
    /// value never discards another valid control. The top-level
    /// `enable_thinking` spelling wins over the equivalent
    /// `chat_template_kwargs` spelling; the typed nested `reasoning.enabled`
    /// is applied later and wins over both.
    internal static func extractChatTemplateControls(
        from data: Data
    ) -> ChatTemplateControls {
        (try? JSONDecoder().decode(ChatTemplateControls.self, from: data)) ?? .init()
    }

    /// OpenAI `logprobs` / `top_logprobs` for this request. Like
    /// `reasoning_effort` and the cache scope, neither field is on the
    /// upstream `OpenAIChatCompletionRequest`, so decode them straight from
    /// the sealed body. Returns nil unless `logprobs == true` (per the
    /// OpenAI contract `top_logprobs` is only meaningful alongside it);
    /// `topLogprobs` passes through un-clamped — the engine translation
    /// (`EngineV2Translation.topLogprobs`) owns the 1...20 clamp policy.
    /// Consumed by the v2 engine path only; legacy serving ignores it.
    internal static func extractLogprobsSpec(
        from data: Data
    ) -> (topLogprobs: Int?, requested: Bool)? {
        InboundChatExtensions(from: data).logprobsSpec
    }

    /// OpenAI `logit_bias` / `seed` for this request. Like `reasoning_effort`,
    /// the cache scope, and the logprobs spec, neither field is on the upstream
    /// `OpenAIChatCompletionRequest`, so decode them straight from the sealed
    /// body. Returns nil when the request carries neither field (the common
    /// case — zero allocation downstream). The two fields are probed
    /// independently so a malformed value for one (e.g. a negative `seed`,
    /// which cannot decode as UInt64) never discards the other. Consumed by
    /// the v2 engine path only; legacy serving ignores both (unchanged
    /// behavior).
    internal static func extractSamplingOverrides(
        from data: Data
    ) -> EngineV2SamplingOverrides? {
        InboundChatExtensions(from: data).samplingOverrides
    }

    /// Prompt-token floor for requests whose usage chunk never arrived (cancelled
    /// stream / upstream regression). Re-runs the engine's exact applyChatTemplate
    /// path so the count matches what was prefilled; VLM parts aren't in the text
    /// template so vision under-counts (a floor, never an overcharge). 0 on failure.

    internal static func promptTokenFloor(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelType: String?,
        templateControls: ChatTemplateControls
    ) -> Int {
        guard let prepared = try? ToolChoicePromptPolicy.prepare(request, modelType: modelType) else { return 0 }
        if modelType == "mimo_v2" {
            return (try? ProviderPromptContractPipeline.tokenize(
                prepared: prepared, request: request, tokenizer: tokenizer.inner,
                modelType: modelType, templateControls: templateControls).count) ?? 0
        }
        let messages = prepared.messages.map { $0.templateMessageDict() }
        let toolSpecs = prepared.tools?.map { $0.toolSpec() }
        let additionalContext = MultiModelBatchSchedulerEngine.templateAdditionalContext(
            for: request, controls: templateControls, modelType: modelType,
            hasMedia: MediaIngest.hasMedia(request),
            requiresToolCall: prepared.requiresToolCall)
        // Must mirror the production tokenize path (sanitize JSON
        // null / Optional leaves) so this recount matches what was prefilled
        // and doesn't itself throw on a null-bearing request.
        let fixContext = ChatTemplateFixContext(
            modelId: request.model, modelType: modelType)
        guard let ids = try? tokenizer.inner.applyChatTemplate(
            messages: ChatTemplateFixes.normalizeMessages(messages, context: fixContext),
            tools: ChatTemplateFixes.normalizeTools(toolSpecs, context: fixContext),
            additionalContext: additionalContext
        ) else { return 0 }
        return ids.count
    }

    /// The engine admission view of a request's token envelope: the templated
    /// prompt recount (``promptTokenFloor`` — the same applyChatTemplate path
    /// the engine prefills) plus the output reservation the scheduler applies
    /// (`max_tokens`, or ``schedulerDefaultMaxTokens`` when the request omits
    /// one). Feeds the busy-wait forecast on enriched token-budget rejections
    /// (`CapacityRejectionEnrichment.enrich`). nil when the recount fails
    /// (e.g. the failure WAS a render error) — no honest envelope exists, so
    /// no forecast is invented.
    internal static func admissionTokenEnvelope(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelType: String?,
        templateControls: ChatTemplateControls
    ) -> Int64? {
        let promptFloor = promptTokenFloor(
            request: request,
            tokenizer: tokenizer,
            modelType: modelType,
            templateControls: templateControls)
        guard promptFloor > 0 else { return nil }
        let (envelope, overflow) = promptFloor.addingReportingOverflow(
            max(0, request.maxTokens ?? schedulerDefaultMaxTokens))
        guard !overflow else { return nil }
        return Int64(exactly: envelope)
    }
}

/// The admission path's reads of one decrypted chat body.
struct InboundChatRequest: Decodable {
    let request: OpenAIChatCompletionRequest
    let extensions: InboundChatExtensions

    init(request: OpenAIChatCompletionRequest, extensions: InboundChatExtensions) {
        self.request = request
        self.extensions = extensions
    }

    /// The strict request and its extensions from the same parse.
    init(from decoder: any Decoder) throws {
        request = try OpenAIChatCompletionRequest(from: decoder)
        extensions = InboundChatExtensions(decoder: decoder)
    }
}

/// Sealed-body fields outside the upstream request shape. Each decodes
/// independently, so one malformed value never discards another.
struct InboundChatExtensions {
    private struct LogprobsProbe: Decodable {
        let logprobs: Bool?
        let top_logprobs: Int?
    }
    private struct BiasProbe: Decodable { let logit_bias: [String: Float]? }
    private struct SeedProbe: Decodable { let seed: UInt64? }

    private(set) var templateControls = ChatTemplateControls()
    private(set) var logprobsSpec: (topLogprobs: Int?, requested: Bool)?
    private(set) var samplingOverrides: EngineV2SamplingOverrides?

    init(from data: Data) {
        struct Whole: Decodable {
            let extensions: InboundChatExtensions
            init(from decoder: any Decoder) throws { extensions = InboundChatExtensions(decoder: decoder) }
        }
        if let whole = try? JSONDecoder().decode(Whole.self, from: data) { self = whole.extensions }
    }

    init(decoder: any Decoder) {
        templateControls = (try? ChatTemplateControls(from: decoder)) ?? .init()
        if let probe = try? LogprobsProbe(from: decoder), probe.logprobs == true {
            logprobsSpec = (topLogprobs: probe.top_logprobs, requested: true)
        }
        let rawBias = (try? BiasProbe(from: decoder))?.logit_bias
        let bias = (rawBias?.isEmpty == false) ? rawBias : nil
        let seed = (try? SeedProbe(from: decoder))?.seed
        if bias != nil || seed != nil {
            samplingOverrides = EngineV2SamplingOverrides(logitBias: bias, seed: seed)
        }
    }
}
