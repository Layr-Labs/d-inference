import Foundation
import MLXLMCommon
import MLXLMServer

/// One Super chat request resolved once: reference reasoning controls, the
/// shared tool-choice policy and the response-format instruction. Prompt
/// rendering and output parsing both consume this plan, so they cannot
/// disagree about thinking, tools or structured output.
struct NemotronSuperRequestPlan: Sendable {
    enum Failure: Error, Equatable { case unsupportedControl, tooManyContentParts }

    /// Content parts one request may carry across all its messages, counted
    /// after the response-format instruction is inserted and refused before
    /// any render. The pinned template's cost grows with parts × prompt
    /// length; rendering merges adjacent text parts
    /// (`NemotronSuperPromptContract`), and this bounds what remains.
    static let maximumContentParts = 4096

    /// Messages carry the provider's tool-choice and response-format text.
    let request: OpenAIChatCompletionRequest
    let toolPolicy: ToolChoicePromptPolicy.Prepared
    let controls: NemotronSuperPromptContract.Controls
    /// CBv2 `topLogprobs`: 0 unless the body sets `logprobs: true`
    /// (`EngineV2Translation.topLogprobs`). The upstream request type omits
    /// both fields, so they are read from the raw body.
    let topLogprobs: Int

    /// `formatted` is a request that `MLXOpenAIService` already passed through
    /// `OpenAIResponseFormatSupport.preparedRequest`; otherwise the instruction
    /// is inserted here exactly once. The request must name `modelID`.
    /// `trustsSchemaMetadata` admits the reserved tool-schema marker, as the
    /// generic engine does for coordinator requests: there the coordinator's
    /// authenticated normalizer or this provider's decode inserted it. Local
    /// requests leave it false, so a client-sent marker is refused.
    init(body: Data, formatted: OpenAIChatCompletionRequest? = nil,
         modelID: String = NemotronSuperLocalBinding.modelID, trustsSchemaMetadata: Bool = false) throws {
        let decoded = try formatted ?? OpenAIResponseFormatSupport.preparedRequest(
            ProviderLoop.decodeOpenAIRequest(body))
        let contentParts = decoded.messages.reduce(0) { count, message in
            guard case .parts(let parts) = message.content else { return count }
            return count + parts.count
        }
        guard contentParts <= Self.maximumContentParts else { throw Failure.tooManyContentParts }
        topLogprobs = try Self.validateWireControls(body: body, request: decoded, modelID: modelID)
        let prepared = try ToolChoicePromptPolicy.prepare(decoded,
            modelType: "nemotron_h_omni", allowInternalSchemaMetadata: trustsSchemaMetadata)
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
    /// prefix cache, logit bias, min-p sampler, alternate parsers, and
    /// `top_logprobs` outside OpenAI's 0...20. A JSON response format with
    /// tools is served: the response is then tool calls or a validated JSON
    /// answer. Returns the request's CBv2 `topLogprobs`.
    private static func validateWireControls(body: Data, request: OpenAIChatCompletionRequest,
                                             modelID: String) throws -> Int {
        struct Wire: Decodable {
            let logprobs: Bool?
            let top_logprobs: Int?
            let prompt_cache_key: String?
            let n: Int?
            let logit_bias: [String: Double]?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: body)
        guard request.model == modelID,
            (0 ... 20).contains(wire.top_logprobs ?? 0), wire.prompt_cache_key == nil,
            wire.logit_bias?.isEmpty != false,
            wire.n == nil || wire.n == 1,
            request.minP == nil || request.minP == 0,
            request.toolCallParser == nil, request.reasoningParser == nil
        else { throw Failure.unsupportedControl }
        return EngineV2Translation.topLogprobs(logprobs: wire.logprobs, topLogprobs: wire.top_logprobs)
    }
}
