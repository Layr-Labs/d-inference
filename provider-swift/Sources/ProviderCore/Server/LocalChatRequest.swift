import MLXLMServer
import ProviderCoreFoundation

/// Decode the upstream request and provider template extensions from the same
/// JSON document. Batch items carry their own controls without reserializing
/// messages, tool schemas, or inline media.
struct LocalChatRequest: Decodable {
    let request: OpenAIChatCompletionRequest
    let templateControls: ChatTemplateControls

    init(from decoder: any Decoder) throws {
        request = try OpenAIChatCompletionRequest(from: decoder)
        templateControls = try ChatTemplateControls(from: decoder).withPromptDate(.capture())
    }
}
