import Foundation
import MLXLMCommon
import MLXLMServer

/// Resolve one request-owned parser before text or qualified native media
/// submission. Existing forced-tool validation remains fail-closed.
enum ToolStreamPreparation {
    /// `DARKBLOOM_TTFT_STREAM_TOOL_CALLS=0` restores complete-call exposure
    /// at the engine terminal for every request.
    static let streamToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_TOOL_CALLS"
    static let streamsToolCallsByDefault =
        ProcessInfo.processInfo.environment[streamToolCallsEnvironmentKey] != "0"
    /// `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS`: `0`, `off`, `false` or `no`
    /// keeps forced (`required`/named) Gemma calls on the complete-call path,
    /// released at the engine terminal (0.10.15). Read once per process.
    static let streamForcedToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS"
    static let streamsForcedToolCallsByDefault = streamsForcedToolCalls(
        environment: ProcessInfo.processInfo.environment)

    static func streamsForcedToolCalls(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[streamForcedToolCallsEnvironmentKey])
    }

    /// `DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS`: `0`, `off`, `false` or `no`
    /// keeps GLM-5.3-Flash calls (`auto` and forced) withheld until the end
    /// of generation (0.10.15). Read once per process.
    static let streamGLMToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS"
    static let streamsGLMToolCallsByDefault = streamsGLMToolCalls(
        environment: ProcessInfo.processInfo.environment)

    static func streamsGLMToolCalls(environment: [String: String]) -> Bool {
        guard let raw = environment[streamGLMToolCallsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return true }
        return !["0", "off", "false", "no"].contains(raw)
    }

    /// GLM-5.3-Flash calls, `auto` and forced, are exposed while generated
    /// (`GLM5ToolCallStream`) to a client that itself streams, on a surface
    /// that renders fragments, when neither switch is off. Its reasoning is
    /// then split before tool parsing (the scheduler's native channel), so a
    /// frame drafted in a thought is never a call. A JSON `response_format`
    /// (withheld until it validates) and a client that does not stream keep
    /// the complete-call path: the whole suffix, parsed at EOS.
    static func streamsGLMCalls(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamGLMToolCalls: Bool = streamsGLMToolCallsByDefault
    ) -> Bool {
        guard streamToolCalls, streamGLMToolCalls, GLM5NextPromptPolicy.applies(modelType: modelType),
            request.streamToolCallDeltas, prepared.clientStreams, prepared.glmResponseFormat == nil,
            prepared.tools?.isEmpty == false
        else { return false }
        return prepared.mode != .none
    }

    static func makeHandler(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamForcedToolCalls: Bool = streamsForcedToolCallsByDefault
    ) throws -> BatchedToolStreamHandler? {
        let isMiMo = modelType == "mimo_v2"
        // Even absent/none tools need native detection: an undeclared generated
        // call must fail validation, not become raw visible XML. This does not
        // restore declarations to the rendered prompt.
        guard prepared.tools?.isEmpty == false || isMiMo else { return nil }
        let format = try ServerToolParser.resolve(
            requested: request.toolCallParser, modelType: modelType)
        if isMiMo, format != .mimoV2 {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload(
                "native MiMo requires the native MiMo tool parser")
        }
        let context = ChatTemplateFixContext(modelId: request.model, modelType: modelType)
        let strategy = try ToolChoiceEnforcementPolicy.forcedStrategy(
            mode: prepared.mode, modelContext: context)
        try ToolChoiceEnforcementPolicy.validateParser(
            format, strategy: strategy, modelContext: context)
        return BatchedToolStreamHandler(format: format,
            tools: (isMiMo && prepared.mode == .none ? request.tools : prepared.tools)?.map { $0.toolSpec() },
            strictGemma: modelType == "diffusion_gemma",
            streaming: streamToolCalls && exposesCallsWhileGenerated(request: request, prepared: prepared,
                context: context, strategy: strategy, forced: streamForcedToolCalls)
                ? streamingOptions(prepared) : nil)
    }

    /// `auto` calls are exposed before they close, and so are Gemma's forced
    /// (`required`/named) calls when the client itself streams: the sampler's
    /// grammar holds them to a declared function and its schema
    /// (`.gemmaGrammar`), each is still validated when its frame closes, and
    /// one that fails after it started is refused (`FailedStreamedCallPolicy`
    /// does not apply to forced calls), never finished. Without it a long
    /// forced answer had no first content before generation ended and missed
    /// the coordinator's first-content deadline. Other families'
    /// forced calls keep validate-then-expose, as does a client that does not
    /// stream, and native channel families keep their own withheld framing.
    /// The request must come from a surface that renders fragments (chat
    /// streaming).
    private static func exposesCallsWhileGenerated(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        context: ChatTemplateFixContext,
        strategy: ToolChoiceEnforcementPolicy.Strategy,
        forced: Bool
    ) -> Bool {
        guard request.streamToolCallDeltas, !ToolChoiceEnforcementPolicy.usesNativeTextChannels(context)
        else { return false }
        switch prepared.mode {
        case .auto: return true
        case .required, .named: return forced && prepared.clientStreams && strategy == .gemmaGrammar
        case .none: return false
        }
    }

    /// A call is exposed only once its resolved name is declared. Any other
    /// call completes in one piece and is validated before it is shown,
    /// unless the parser rejects the frame and returns it as text.
    private static func streamingOptions(_ prepared: ToolChoicePromptPolicy.Prepared) -> ToolCallStreamingOptions {
        let allowed = prepared.allowedToolNames
        return ToolCallStreamingOptions(exposesName: { allowed.contains($0) })
    }
}
