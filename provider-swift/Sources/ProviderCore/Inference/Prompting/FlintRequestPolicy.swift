import Foundation
import MLXLMServer

/// Flint chooses whether to reason. Output length is not a reasoning effort.
enum FlintRequestPolicy {
    static func validateControls(_ controls: ChatTemplateControls, modelType: String?) throws {
        guard modelType == "flint" else { return }
        let raw = controls.rawMiMoControls
        // Reuse request-local evidence captured before permissive decoding drops
        // wrong-typed controls and kwargs.thinking. Do not change its capture or
        // another family's policy. The media-only evidence bit is unrelated.
        guard
            controls.hasExplicitThinkingControl || controls.preserveThinking != nil
                || raw.invalid || raw.templateThinkingAlias != nil
                || raw.responseEnableThinking != nil || raw.responseEffortDisablesThinking != nil
        else { return }
        throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
            "Flint selects reasoning automatically; explicit or malformed thinking controls are unsupported"
        )
    }

    static func validate(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) throws {
        guard modelType == "flint" else { return }
        try validateControls(controls, modelType: modelType)
        if request.reasoning?.enabled != nil || request.reasoning?.effort != nil {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "Flint selects reasoning automatically; explicit reasoning controls are unsupported"
            )
        }
        if request.responseFormat?.requiresJSONOutput == true, !(request.tools?.isEmpty ?? true) {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "Flint does not support combining JSON response_format with tools")
        }
        if MediaIngest.hasMedia(request) {
            throw MultiModelBatchSchedulerEngineError.mediaUnsupportedByModel(request.model)
        }
        try validateHistoricalArguments(request)
    }

    private static func validateHistoricalArguments(_ request: OpenAIChatCompletionRequest) throws {
        for message in request.messages {
            for call in message.toolCalls ?? [] {
                guard
                    let arguments = try? JSONSerialization.jsonObject(
                        with: Data(call.function.arguments.utf8)) as? [String: Any]
                else {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "Flint historical tool arguments must be a JSON object")
                }
                // The pinned template emits top-level strings verbatim, while
                // objects/arrays are JSON encoded and protect nested strings.
                // There is no escape for this raw delimiter. A generated frame
                // which is syntactically indistinguishable from separate args
                // cannot be disambiguated after the fact; never promise that
                // arbitrary delimiter-bearing strings round-trip.
                if arguments.values.contains(where: {
                    ($0 as? String)?.contains("</arg_value>") == true
                }) {
                    throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                        "Flint cannot represent a literal </arg_value> in a raw string tool argument"
                    )
                }
            }
        }
    }
}
