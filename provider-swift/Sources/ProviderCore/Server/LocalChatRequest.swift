import MLXLMServer
import ProviderCoreFoundation

/// Decode the upstream request and provider template extensions from the same
/// JSON document. Batch items carry their own controls without reserializing
/// messages, tool schemas, or inline media.
struct LocalChatRequest: Decodable {
    var request: OpenAIChatCompletionRequest
    var templateControls: ChatTemplateControls
    /// `n` above 1, read as the coordinator reads it (`IntFromRequestValue`):
    /// an integer, or a number truncated toward zero; any other value counts
    /// no choices. The request type has no `n`, and every local engine answers
    /// one choice.
    var requestsMultipleChoices = false

    init(from decoder: any Decoder) throws {
        request = try AliasedChatRequest(from: decoder).request
        templateControls = try LocalChatTemplateControls(from: decoder).controls
        // Newer OpenAI clients send the output limit as `max_completion_tokens`, which the coordinator also reads;
        // the request type knows only `max_tokens`, which wins when both are sent.
        if request.maxTokens == nil {
            request.maxTokens = (try? CompletionTokensAlias(from: decoder))?.maxCompletionTokens
        }
        requestsMultipleChoices = (try? ChoiceCount(from: decoder))?.multiple ?? false
    }

    private struct ChoiceCount: Decodable {
        let multiple: Bool
        enum CodingKeys: String, CodingKey { case n }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let count = try? values.decode(Int.self, forKey: .n) {
                multiple = count > 1
            } else if let count = try? values.decode(Double.self, forKey: .n) {
                multiple = count >= 2
            } else {
                multiple = false
            }
        }
    }

    private struct CompletionTokensAlias: Decodable {
        let maxCompletionTokens: Int?
        enum CodingKeys: String, CodingKey { case maxCompletionTokens = "max_completion_tokens" }
    }
}

/// The provider template extensions alone. A request the local API decodes
/// again from its repaired body (`InboundChatNormalization`) takes them from
/// the body as sent, as the coordinator path does
/// (`ProviderLoop.decodeInboundChatRequest`): the repair renames `developer`
/// to `system` and re-serializes the body, which the raw captures
/// (`hasDeveloperMessage`, the MiMo, GLM and Flint controls) must not see.
struct LocalChatTemplateControls: Decodable {
    let controls: ChatTemplateControls

    init(from decoder: any Decoder) throws {
        controls = try ChatTemplateControls(from: decoder).withPromptDate(.capture())
    }
}
