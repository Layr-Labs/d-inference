import MLXLMServer

/// A Gemma tool parameter whose render type changed while the prompt contract
/// the coordinator plans and counts with (normalization v9) still renders the
/// shared normalizer's: a union of `string` and one other scalar type with
/// `string` first renders as the other type, and a property declared without a
/// type renders an empty type (`Gemma4ToolSchemaEnforcement` invariants 7 and
/// 8). Such a request is served without the coordinator's prompt cache, as
/// `ToolCallHistoryNullCache` serves its requests; every other request keeps
/// its context.
enum GemmaToolUnionTypeCache {
    /// Whether the request's declared tools get a changed Gemma render type.
    /// Its tools are a superset of the rendered ones (tool choice only narrows
    /// them), so this never misses a changed prompt. `declared` are the
    /// caller's declarations as sent (`ChatTemplateControls.declaredTools`).
    static func changesRender(
        _ request: OpenAIChatCompletionRequest, modelType: String?, declared: [OpenAITool]? = nil
    ) -> Bool {
        guard let tools = request.tools, !tools.isEmpty else { return false }
        return ChatTemplateFixes.changesGemmaToolRenderType(
            tools.map { $0.toolSpec() }, context: .init(modelId: request.model, modelType: modelType),
            declared: declared)
    }

    /// The cache context `request` is served with: `context`, or one without a
    /// scope or receipt nonce when `context` still plans a cache attempt and
    /// the request's Gemma tool render changed. `servedCold` reports that case.
    static func servingContext(
        _ context: RemotePrefixCacheContext, for request: OpenAIChatCompletionRequest, modelType: String?,
        declared: [OpenAITool]? = nil
    ) -> (context: RemotePrefixCacheContext, servedCold: Bool) {
        guard context.scope != nil || context.receiptNonce != nil,
            changesRender(request, modelType: modelType, declared: declared)
        else { return (context, false) }
        return (RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil), true)
    }
}
