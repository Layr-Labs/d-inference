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
        guard let raw = environment[streamForcedToolCallsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return true }
        return !["0", "off", "false", "no"].contains(raw)
    }

    /// `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS`: `0`, `off`, `false` or `no`
    /// keeps MiMo V2.6 and Nemotron 3.5 calls (`auto` and forced) on the
    /// complete-call path, released at the engine terminal (0.10.15). Read
    /// once per process.
    static let streamNativeToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS"
    static let streamsNativeToolCallsByDefault = streamsNativeToolCalls(
        environment: ProcessInfo.processInfo.environment)

    static func streamsNativeToolCalls(environment: [String: String]) -> Bool {
        guard let raw = environment[streamNativeToolCallsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        else { return true }
        return !["0", "off", "false", "no"].contains(raw)
    }

    /// The native-channel families whose calls stream, each with the only
    /// parser its frames stream through: MiMo V2.6 (`.mimoV2`) and the
    /// Nemotron 3.5 builds the scheduler serves (Lightning, `.nemotron`).
    /// Nemotron 3.5 Super streams through its own owner
    /// (`NemotronSuperLocalOutput`).
    static func streamsNativeFamilyCalls(_ context: ChatTemplateFixContext, format: ToolCallFormat) -> Bool {
        switch format {
        case .mimoV2: context.modelType == "mimo_v2"
        case .nemotron:
            context.modelType == "nemotron_h" && EngineV2SupportedModels.isNemotron35ListingModelID(context.modelId)
        default: false
        }
    }

    static func makeHandler(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamForcedToolCalls: Bool = streamsForcedToolCallsByDefault,
        streamNativeToolCalls: Bool = streamsNativeToolCallsByDefault
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
                context: context, strategy: strategy, format: format, forced: streamForcedToolCalls,
                native: streamNativeToolCalls)
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
    /// stream. The request must come from a surface that renders fragments
    /// (chat streaming).
    ///
    /// Native channel families keep their withheld framing, except MiMo V2.6
    /// and Nemotron 3.5 (`streamsNativeFamilyCalls`): their `auto` and forced
    /// calls stream to a client that streams, under the same rules (each
    /// checked when its frame closes, forced answers calls only, a call that
    /// fails after it started refused). A client that does not stream keeps
    /// the complete-call output for every mode, and so does any other build
    /// whose parser now streams (`.mimoV2`, `.nemotron`).
    private static func exposesCallsWhileGenerated(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        context: ChatTemplateFixContext,
        strategy: ToolChoiceEnforcementPolicy.Strategy,
        format: ToolCallFormat,
        forced: Bool,
        native: Bool
    ) -> Bool {
        guard request.streamToolCallDeltas else { return false }
        if ToolChoiceEnforcementPolicy.usesNativeTextChannels(context) || format == .mimoV2 || format == .nemotron {
            guard native, prepared.clientStreams, streamsNativeFamilyCalls(context, format: format)
            else { return false }
            return prepared.mode != .none
        }
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
