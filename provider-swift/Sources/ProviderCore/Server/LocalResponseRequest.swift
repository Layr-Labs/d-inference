import MLXLMServer
import ProviderCoreFoundation

/// Preserve the existing typed Responses translation/store contract. Only the
/// request-local native capsules see additional controls; only the actual
/// loaded model family selects them. Other families keep their prior behavior.
struct LocalResponseRequest: Decodable {
    var request: OpenAIResponseRequest
    let templateControls: ChatTemplateControls

    init(from decoder: any Decoder) throws {
        request = try OpenAIResponseRequest(from: decoder)
        templateControls = ChatTemplateControls()
            .withRawMiMoControls(MiMoV26RawControlEvidence.capture(from: decoder, surface: .responses))
            .withRawGLM5Controls(GLM5NextPromptPolicy.RawControls.capture(from: decoder))
    }
}
