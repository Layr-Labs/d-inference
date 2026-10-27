import Foundation
import MLXLMCommon
import MLXLMServer

enum ProviderPromptContractPipeline {
    struct NormalizedInput: Sendable {
        let messages: [[String: any Sendable]]
        let tools: [[String: any Sendable]]?
        let additionalContext: [String: any Sendable]?
    }
    static func validateNativeControls(_ controls: ChatTemplateControls, modelType: String?) throws {
        try controls.rawMiMoControls.validate(modelType: modelType)
        try FlintRequestPolicy.validateControls(controls, modelType: modelType)
        if GLM5NextPromptPolicy.applies(modelType: modelType) {
            try controls.rawGLM5Controls.validate()
        }
    }
    /// Why `validateNativeControls` refuses `controls`, or nil when it accepts
    /// them. MiMo and Flint refuse only reasoning controls.
    static func nativeControlsRefusal(_ controls: ChatTemplateControls, modelType: String?) -> InferenceRefusalReason? {
        do {
            try validateNativeControls(controls, modelType: modelType)
            return nil
        } catch {
            guard GLM5NextPromptPolicy.applies(modelType: modelType) else { return .unsupportedReasoningControl }
            return controls.rawGLM5Controls.refusalReason ?? .unsupportedReasoningControl
        }
    }
    /// The caller declined reasoning the model still generates. It is never
    /// framed or returned as logprob entries, but it is counted as reasoning.
    static func withholdsReasoning(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) -> Bool {
        FlintRequestPolicy.withholdsReasoning(request, controls: controls, modelType: modelType)
            || GLM5NextPromptPolicy.withholdsReasoning(controls, modelType: modelType)
    }
    static func tokenizeProviderBody(
        _ body: Data,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?
    ) throws -> [Int] {
        if MiMoV26TemplateFix.applies(to: .init(modelType: modelType)) {
            try MiMoV26TemplateFix.validateRawControls(body)
        }
        let decodedRequest = try ProviderLoop.decodeOpenAIRequest(body, modelType: modelType)
        let templateControls = ProviderLoop.extractChatTemplateControls(from: body).resolvingPromptDate()
        let request = try templateControls.rawMiMoTools.restoring(decodedRequest, modelType: modelType)
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        return try tokenize(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelType: modelType,
            templateControls: templateControls)
    }


    /// `promptCacheScope` is the request's prefix-cache scope when caching is
    /// enabled for it; nil always takes the unchanged tokenizer path.
    static func tokenize(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?,
        templateControls: ChatTemplateControls,
        promptCacheScope: String? = nil
    ) throws -> [Int] {
        let input = try normalizedInput(prepared: prepared, request: request,
            modelType: modelType, templateControls: templateControls)
        if let promptCacheScope, let caching = tokenizer as? any PromptTokenCaching {
            return try caching.applyChatTemplate(messages: input.messages,
                tools: input.tools, additionalContext: input.additionalContext,
                promptCacheScope: promptCacheScope)
        }
        return try tokenizer.applyChatTemplate(messages: input.messages,
            tools: input.tools, additionalContext: input.additionalContext)
    }

    /// Where `tokenize`'s time goes: the request's normalization, and the
    /// tokenizer's one chat-template call (the Jinja render and the BPE encode
    /// of its text, inseparable from outside the tokenizer).
    struct PrepTiming: Sendable {
        let normalizeMicroseconds: Int64
        let templateTokenizeMicroseconds: Int64
    }

    /// `tokenize`, the same calls on the same inputs, timed.
    static func tokenizeMeasured(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?,
        templateControls: ChatTemplateControls,
        promptCacheScope: String? = nil
    ) throws -> (tokens: [Int], timing: PrepTiming) {
        func microseconds(_ duration: Duration) -> Int64 {
            let parts = duration.components
            return parts.seconds * 1_000_000 + parts.attoseconds / 1_000_000_000_000
        }
        let started = ContinuousClock.now
        let input = try normalizedInput(prepared: prepared, request: request,
            modelType: modelType, templateControls: templateControls)
        let normalized = ContinuousClock.now
        let tokens: [Int]
        if let promptCacheScope, let caching = tokenizer as? any PromptTokenCaching {
            tokens = try caching.applyChatTemplate(messages: input.messages,
                tools: input.tools, additionalContext: input.additionalContext,
                promptCacheScope: promptCacheScope)
        } else {
            tokens = try tokenizer.applyChatTemplate(messages: input.messages,
                tools: input.tools, additionalContext: input.additionalContext)
        }
        let rendered = ContinuousClock.now
        return (tokens, PrepTiming(normalizeMicroseconds: microseconds(normalized - started),
            templateTokenizeMicroseconds: microseconds(rendered - normalized)))
    }

    /// Exposes the SAME production normalization result. The default path is
    /// byte/ordering-equivalent to tokenize's original inputs. Only the native
    /// decoded-media adapter supplies structured content: it is carried through
    /// the existing history/result ordering before URLs become owned pixels,
    /// never rendered as prompt text or repaired as tool arguments.
    static func normalizedInput(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        modelType: String?,
        templateControls: ChatTemplateControls,
        preserveMiMoMediaParts: Bool = false
    ) throws -> NormalizedInput {
        try validateNativeControls(templateControls, modelType: modelType)
        try FlintRequestPolicy.validate(request, controls: templateControls, modelType: modelType)
        if GLM5NextPromptPolicy.applies(modelType: modelType) {
            guard !preserveMiMoMediaParts else {
                throw MultiModelBatchSchedulerEngineError.multimodalRejected("native media owner required")
            }
            return try GLM5NextPromptPolicy.normalizedTextInput(
                request: request, prepared: prepared, controls: templateControls)
        }
        try MediaIngest.rejectUnsupportedAudio(request,
            modelType: preserveMiMoMediaParts ? modelType : nil)
        try DiffusionGemmaReasoningControl.validate(
            request: request, controls: templateControls, modelType: modelType)
        let isMiMo = MiMoV26TemplateFix.applies(to: .init(modelType: modelType))
        if isMiMo { try MiMoV26TemplateFix.validateRequest(request) }
        guard preserveMiMoMediaParts || !MediaIngest.hasAudio(request) else {
            // Text-only token/count callers cannot price audio by dropping its
            // bytes. Exact tokens come from the admitted native media plan.
            throw MultiModelBatchSchedulerEngineError.multimodalRejected("encoded audio requires native media preparation")
        }
        guard !preserveMiMoMediaParts || isMiMo else {
            throw MultiModelBatchSchedulerEngineError.multimodalRejected("native media owner required")
        }
        let messages = prepared.messages.map { message in
            var value = message.templateMessageDict()
            if preserveMiMoMediaParts, case .parts(let parts) = message.content {
                value["content"] = parts.map { part -> [String: any Sendable] in
                    switch part {
                    case .text(let text): return ["type":"text", "text":text]
                    case .imageURL(let uri): return ["type":"image_url", "image_url":uri]
                    case .videoURL(let uri): return ["type":"video_url", "video_url":uri]
                    case .inputAudio(let audio):
                        return ["type":"input_audio", "input_audio":["data":audio.data,"format":audio.format.rawValue]]
                    case .unsupported: return ["type":"unsupported"]
                    }
                }
            }
            return value
        }
        let tools = prepared.tools?.map { $0.toolSpec() }
        let context = ChatTemplateFixContext(
            modelId: request.model,
            modelType: modelType)
        let additionalContext: [String: any Sendable]?
        if isMiMo {
            additionalContext = try MiMoV26TemplateFix.additionalContext(request: request, controls: templateControls)
        } else {
            additionalContext = MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request,
                controls: templateControls,
                modelType: modelType,
                hasMedia: MediaIngest.hasMedia(request),
                requiresToolCall: prepared.requiresToolCall)
        }
        try Qwen4SupportPolicy.validateReasoningContext(
            modelID: request.model, modelType: modelType, additionalContext: additionalContext)
        return try NormalizedInput(
            messages: ChatTemplateFixes.normalizeMessages(messages, context: context),
            tools: ChatTemplateFixes.normalizeTools(tools, context: context),
            additionalContext: additionalContext)
    }
}
