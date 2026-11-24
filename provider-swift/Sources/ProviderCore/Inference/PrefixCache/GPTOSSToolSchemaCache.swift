import MLXLMServer

/// A GPT-OSS tool declaration that now renders as written
/// (`GPTOSSToolSchemaRender`), while the prompt contract the coordinator plans
/// and counts with (normalization v9) renders the repaired one. Such a request
/// is served without the coordinator's prompt cache, as
/// `ToolCallHistoryNullCache` serves its requests; every other request keeps
/// its context. A body whose tools arrive already repaired renders as before
/// and keeps its context.
enum GPTOSSToolSchemaCache {
    /// The cache context `request` is served with: `context`, or one without a
    /// scope or receipt nonce when `context` still plans a cache attempt and
    /// the request's GPT-OSS tool render changed. `servedCold` reports that case.
    static func servingContext(
        _ context: RemotePrefixCacheContext, for request: OpenAIChatCompletionRequest,
        declared: [OpenAITool]?, modelType: String?
    ) -> (context: RemotePrefixCacheContext, servedCold: Bool) {
        guard context.scope != nil || context.receiptNonce != nil,
            GPTOSSToolSchemaRender.changesRender(
                request.tools, declared: declared, modelId: request.model, modelType: modelType)
        else { return (context, false) }
        return (RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil), true)
    }
}
