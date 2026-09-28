import MLXLMCommon
import MLXLMServer

/// Resolve one request-owned parser before text or qualified native media
/// submission. Existing forced-tool validation remains fail-closed.
enum ToolStreamPreparation {
    static func makeHandler(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?
    ) throws -> BatchedToolStreamHandler? {
        guard prepared.tools?.isEmpty == false else { return nil }
        let format = try ServerToolParser.resolve(
            requested: request.toolCallParser, modelType: modelType)
        let context = ChatTemplateFixContext(modelId: request.model, modelType: modelType)
        let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(
            mode: prepared.mode, modelContext: context)
        try ToolChoiceEnforcementPolicy.validateParser(
            format, strategy: strategy, modelContext: context)
        return BatchedToolStreamHandler(format: format, tools: prepared.tools?.map { $0.toolSpec() },
            strictGemma: modelType == "diffusion_gemma")
    }
}
