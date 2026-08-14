import Foundation
import MLXLMCommon
import MLXLMServer

enum ProviderPromptContractPipeline {
    static func tokenizeProviderBody(
        _ body: Data,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?
    ) throws -> [Int] {
        let request = try ProviderLoop.decodeOpenAIRequest(body)
        let controls = ReasoningControls.parse(from: body)
        let prepared = try ToolChoicePromptPolicy.prepare(request)
        return try tokenize(
            prepared: prepared,
            request: request,
            tokenizer: tokenizer,
            modelType: modelType,
            reasoningEffort: controls.effortForTemplate,
            controls: controls)
    }

    static func tokenize(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        tokenizer: any MLXLMCommon.Tokenizer,
        modelType: String?,
        reasoningEffort: String?,
        controls: ReasoningControls = .unspecified
    ) throws -> [Int] {
        let messages = prepared.messages.map { $0.templateMessageDict() }
        let tools = prepared.tools?.map { $0.toolSpec() }
        let context = ChatTemplateFixContext(
            modelId: request.model,
            modelType: modelType)
        return try tokenizer.applyChatTemplate(
            messages: ChatTemplateFixes.normalizeMessages(messages, context: context),
            tools: ChatTemplateFixes.normalizeTools(tools, context: context),
            additionalContext: MultiModelBatchSchedulerEngine.templateAdditionalContext(
                for: request,
                reasoningEffort: reasoningEffort,
                controls: controls))
    }
}
