import Foundation
import MLXLMCommon
import MLXLMServer

/// One Super chat request resolved once: reference reasoning controls, the
/// shared tool-choice policy and the response-format instruction. Prompt
/// rendering and output parsing both consume this plan, so they cannot
/// disagree about thinking, tools or structured output.
struct NemotronSuperRequestPlan: Sendable {
    enum Failure: Error, Equatable { case unsupportedControl }

    /// Messages carry the provider's tool-choice and response-format text.
    let request: OpenAIChatCompletionRequest
    let toolPolicy: ToolChoicePromptPolicy.Prepared
    let controls: NemotronSuperPromptContract.Controls

    /// `formatted` is a request that `MLXOpenAIService` already passed through
    /// `OpenAIResponseFormatSupport.preparedRequest`; otherwise the instruction
    /// is inserted here exactly once.
    init(body: Data, formatted: OpenAIChatCompletionRequest? = nil) throws {
        let decoded = try formatted ?? OpenAIResponseFormatSupport.preparedRequest(
            ProviderLoop.decodeOpenAIRequest(body))
        try Self.validateWireControls(body: body, request: decoded)
        let prepared = try ToolChoicePromptPolicy.prepare(decoded,
            modelType: "nemotron_h_omni", allowInternalSchemaMetadata: false)
        var rendered = decoded
        rendered.messages = prepared.messages
        rendered.tools = prepared.tools
        request = rendered
        toolPolicy = prepared
        controls = try NemotronSuperPromptContract.controls(body: body)
    }

    var hasMedia: Bool { MediaIngest.hasMedia(request) }

    /// Reference prompt for a text request. Media requests are rendered by
    /// their admitted image owner, which also expands placeholders.
    func textPromptTokens(body: Data, templateBytes: Data, tokenizer: any MLXLMCommon.Tokenizer,
        addGenerationPrompt: Bool = true) throws -> [Int] {
        guard !hasMedia else { throw NemotronSuperPromptContract.Failure.unsupportedMedia }
        let tokens = try NemotronSuperPromptContract.render(messages: request.messages, body: body,
            declared: toolPolicy.tools, controls: controls, templateBytes: templateBytes,
            tokenizer: tokenizer, addGenerationPrompt: addGenerationPrompt)
        // Literal `<image>` text would address visual features that do not exist.
        guard !tokens.contains(NemotronSuperPromptContract.imageTokenID) else {
            throw NemotronSuperPromptContract.Failure.unsupportedMedia
        }
        return tokens
    }

    /// Output controls this owner cannot honor are refused rather than ignored:
    /// no logprob channel, prefix cache, min-p sampler or alternate parsers.
    private static func validateWireControls(body: Data, request: OpenAIChatCompletionRequest) throws {
        struct Wire: Decodable {
            let logprobs: Bool?
            let top_logprobs: Int?
            let prompt_cache_key: String?
            let n: Int?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: body)
        guard request.model == NemotronSuperLocalBinding.modelID,
            wire.logprobs != true, wire.top_logprobs == nil, wire.prompt_cache_key == nil,
            wire.n == nil || wire.n == 1,
            request.minP == nil || request.minP == 0,
            request.toolCallParser == nil, request.reasoningParser == nil,
            !(request.responseFormat?.requiresJSONOutput == true && request.tools?.isEmpty == false)
        else { throw Failure.unsupportedControl }
    }
}
