import MLXLMServer
import ProviderCoreFoundation

/// Decode the upstream request and provider template extensions from the same
/// JSON document. Batch items carry their own controls without reserializing
/// messages, tool schemas, or inline media.
struct LocalChatRequest: Decodable {
    var request: OpenAIChatCompletionRequest
    var templateControls: ChatTemplateControls

    init(from decoder: any Decoder) throws {
        request = try AliasedChatRequest(from: decoder).request
        templateControls = try ChatTemplateControls(from: decoder).withPromptDate(.capture())
        // Newer OpenAI clients send the output limit as `max_completion_tokens`, which the coordinator also reads;
        // the request type knows only `max_tokens`, which wins when both are sent.
        if request.maxTokens == nil {
            request.maxTokens = (try? CompletionTokensAlias(from: decoder))?.maxCompletionTokens
        }
    }

    private struct CompletionTokensAlias: Decodable {
        let maxCompletionTokens: Int?
        enum CodingKeys: String, CodingKey { case maxCompletionTokens = "max_completion_tokens" }
    }
}
