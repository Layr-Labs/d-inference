import MLXLMServer

/// A Gemma tool parameter whose union of `string` and one other scalar type
/// used to render as STRING renders as the other type
/// (`Gemma4ToolSchemaEnforcement` invariant 7), while the prompt contract the
/// coordinator plans and counts with (normalization v9) still renders STRING.
/// Such a request is served without the coordinator's prompt cache, as
/// `ToolCallHistoryNullCache` serves its requests; every other request keeps
/// its context.
enum GemmaToolUnionTypeCache {
    /// Whether the request's declared tools get a changed Gemma render type.
    /// Declared tools are a superset of the rendered ones (tool choice only
    /// narrows them), so this never misses a changed prompt.
    static func changesRender(_ request: OpenAIChatCompletionRequest, modelType: String?) -> Bool {
        guard let tools = request.tools, !tools.isEmpty else { return false }
        return ChatTemplateFixes.changesGemmaToolUnionType(
            tools.map { $0.toolSpec() }, context: .init(modelId: request.model, modelType: modelType))
    }

    /// The cache context `request` is served with: `context`, or one without a
    /// scope or receipt nonce when `context` still plans a cache attempt and
    /// the request's Gemma tool render changed. `servedCold` reports that case.
    static func servingContext(
        _ context: RemotePrefixCacheContext, for request: OpenAIChatCompletionRequest, modelType: String?
    ) -> (context: RemotePrefixCacheContext, servedCold: Bool) {
        guard context.scope != nil || context.receiptNonce != nil,
            changesRender(request, modelType: modelType)
        else { return (context, false) }
        return (RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil), true)
    }
}
