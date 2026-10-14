// Copyright © 2026 Eigen Labs.
import Foundation
import MLXLMServer

/// `response_format` modes that the serving path only requests through a
/// prompt instruction (`OpenAIResponseFormatSupport`): nothing constrains
/// decoding and the streamed provider path never validates the output. Raw
/// values are the public wire spellings, so a rejection can name the mode
/// without echoing any caller-supplied value.
public enum UnenforcedResponseFormat: String, CaseIterable, Sendable, Equatable {
    case jsonObject = "json_object"
    case jsonSchema = "json_schema"
}

/// LFM2.5-24B-A2B has no enforced structured-output path (no grammar or
/// constrained decoding for `lfm2_moe`), and its catalog does not advertise
/// structured outputs or JSON mode. Accepting `json_schema`/`json_object`
/// would silently imply support, so the exact listing ids refuse them before
/// acceptance, model load or template render. `text` (the default) stays
/// accepted. Other families keep their existing behavior.
enum LFM2ResponseFormatPolicy {
    static func rejectionMessage(for format: UnenforcedResponseFormat) -> String {
        "response_format type \(format.rawValue) is not supported for this model "
            + "(structured output is not enforced). Omit response_format or use type text."
    }

    static func unenforcedFormat(_ request: OpenAIChatCompletionRequest) -> UnenforcedResponseFormat? {
        switch request.responseFormat?.type {
        case .jsonObject: .jsonObject
        case .jsonSchema: .jsonSchema
        case .text, nil: nil
        }
    }

    static func validate(request: OpenAIChatCompletionRequest) throws {
        guard EngineV2SupportedModels.isLFM25ListingModelID(request.model),
              let format = unenforcedFormat(request)
        else { return }
        throw MultiModelBatchSchedulerEngineError.responseFormatNotEnforced(format)
    }
}

/// Every exact-id LFM2.5 request refusal, in one place for the three gates
/// (pre-accept on the coordinator path, pre-acquire on the local engine, and
/// the prompt-contract pipeline). Reasoning controls are checked first.
enum LFM2RequestPolicy {
    static func validate(request: OpenAIChatCompletionRequest, controls: ChatTemplateControls) throws {
        try LFM2ReasoningControlPolicy.validate(request: request, controls: controls)
        try LFM2ResponseFormatPolicy.validate(request: request)
    }
}
