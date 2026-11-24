import MLXLMServer
import ProviderCoreFoundation

/// An earlier tool call whose arguments carry a JSON null renders that null
/// on the shared chat-template path (`sanitizeMessageForJinja`), while the
/// prompt contract the coordinator plans and counts with (normalization v9)
/// renders it without. Such a request is served without the coordinator's
/// prompt cache: no lookup, no receipt, no cache usage and no checkpoint write,
/// so no receipt ever names a prompt the coordinator did not plan. Every other
/// request keeps its planned cache context.
enum ToolCallHistoryNullCache {
    /// Whether any message's tool call carries such arguments.
    static func carriesNull(_ request: OpenAIChatCompletionRequest) -> Bool {
        request.messages.contains { message in
            (message.toolCalls ?? []).contains { toolCallArgumentsCarryNull($0.function.arguments) }
        }
    }

    /// Whether `modelType` renders history through the shared chat-template
    /// sanitizer. GLM-5.3, MiMo, Flint and the managed Nemotron Super owner
    /// build their own history and already kept these nulls, so their prompts
    /// did not change.
    static func rendersThroughSharedSanitizer(modelType: String?, managedSuper: Bool) -> Bool {
        !managedSuper && !GLM5NextPromptPolicy.applies(modelType: modelType)
            && !MiMoV26TemplateFix.applies(to: .init(modelType: modelType))
            && modelType != "flint"
    }

    /// The cache context `request` is served with: `planned`, or one without a
    /// scope or receipt nonce when the coordinator planned a cache attempt,
    /// the model renders through the shared sanitizer and the request's
    /// tool-call history carries a null. `servedCold` reports that second case.
    static func servingContext(
        _ planned: RemotePrefixCacheContext, for request: OpenAIChatCompletionRequest,
        modelType: String?, managedSuper: Bool
    ) -> (context: RemotePrefixCacheContext, servedCold: Bool) {
        guard planned.scope != nil || planned.receiptNonce != nil,
            rendersThroughSharedSanitizer(modelType: modelType, managedSuper: managedSuper),
            carriesNull(request)
        else { return (planned, false) }
        return (RemotePrefixCacheContext(cacheScope: nil, cacheReceiptNonce: nil), true)
    }
}
