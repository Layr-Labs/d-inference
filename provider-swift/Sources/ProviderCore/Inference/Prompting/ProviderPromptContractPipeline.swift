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
    }
    static func tokenizeProviderBody(
        _ body: Data,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?
    ) throws -> [Int] {
        if MiMoV26TemplateFix.applies(to: .init(modelType: modelType)) {
            try MiMoV26TemplateFix.validateRawControls(body)
        }
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let templateControls = ProviderLoop.extractChatTemplateControls(from: body).resolvingPromptDate()
        let prepared = try ToolChoicePromptPolicy.prepare(request, modelType: modelType)
        return try tokenize(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelType: modelType,
            templateControls: templateControls)
    }


    static func tokenize(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?,
        templateControls: ChatTemplateControls
    ) throws -> [Int] {
        let input = try normalizedInput(prepared: prepared, request: request,
            modelType: modelType, templateControls: templateControls)
        return try tokenizer.applyChatTemplate(messages: input.messages,
            tools: input.tools, additionalContext: input.additionalContext)
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
