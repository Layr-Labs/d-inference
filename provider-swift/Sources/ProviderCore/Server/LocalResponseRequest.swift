import MLXLMServer
import ProviderCoreFoundation

/// Preserve the existing typed Responses translation/store contract. Only the
/// bounded MiMo capsule sees additional native controls; other families keep
/// the default service's prior template-control behavior.
struct LocalResponseRequest: Decodable {
    let request: OpenAIResponseRequest
    let templateControls: ChatTemplateControls

    init(from decoder: any Decoder) throws {
        request = try OpenAIResponseRequest(from: decoder)
        templateControls = ChatTemplateControls()
            .withRawMiMoControls(MiMoV26RawControlEvidence.capture(from: decoder, surface: .responses))
    }
}
