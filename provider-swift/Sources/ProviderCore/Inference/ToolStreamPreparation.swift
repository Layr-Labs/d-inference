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
    /// keeps every family's forced (`required`/named) calls on the
    /// complete-call path, released at the engine terminal (0.10.15).
    /// `DARKBLOOM_TTFT_STREAM_FORCED_QWEN_TOOL_CALLS` and
    /// `DARKBLOOM_TTFT_STREAM_FORCED_GPTOSS_TOOL_CALLS` do so for one family.
    /// Read once per process.
    static let streamForcedToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS"
    static let streamForcedQwenToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_FORCED_QWEN_TOOL_CALLS"
    static let streamForcedGPTOSSToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_FORCED_GPTOSS_TOOL_CALLS"
    static let streamsForcedToolCallsByDefault = ForcedCalls(environment: ProcessInfo.processInfo.environment)

    static func streamsForcedToolCalls(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[streamForcedToolCallsEnvironmentKey])
    }

    /// The families whose forced calls stream to a client that streams.
    struct ForcedCalls: Equatable, Sendable {
        /// Gemma 4: the sampler's grammar holds a call to a declared function
        /// and its schema (`.gemmaGrammar`).
        var gemma = true
        /// Qwen 3.5–3.8: prompt-forced, with no sampler grammar; the name,
        /// schema and cardinality are checked when each frame closes
        /// (`.structuredPostValidation`).
        var qwen = true
        /// GPT-OSS: the sampler admits only a declared function's Harmony
        /// header, then one JSON object of its schema (`.harmonyFraming`).
        var gptOSS = true

        static let all = ForcedCalls()
        static let none = ForcedCalls(gemma: false, qwen: false, gptOSS: false)

        init(gemma: Bool = true, qwen: Bool = true, gptOSS: Bool = true) {
            (self.gemma, self.qwen, self.gptOSS) = (gemma, qwen, gptOSS)
        }

        init(environment: [String: String]) {
            func isOn(_ key: String) -> Bool { !ToolOutputLeniencySwitch.isOff(environment[key]) }
            let every = isOn(streamForcedToolCallsEnvironmentKey)
            self.init(gemma: every,
                qwen: every && isOn(streamForcedQwenToolCallsEnvironmentKey),
                gptOSS: every && isOn(streamForcedGPTOSSToolCallsEnvironmentKey))
        }
    }

    static func makeHandler(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamForcedToolCalls: ForcedCalls = streamsForcedToolCallsByDefault
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

    /// `auto` calls are exposed before they close, and so are forced
    /// (`required`/named) calls when the client itself streams, on Gemma 4
    /// (`.gemmaGrammar`), Qwen 3.5–3.8 (`.structuredPostValidation`, the
    /// `qwen3_5` and `qwen3_5_moe` types) and GPT-OSS (`.harmonyFraming`).
    /// Each forced call is still checked in full when its frame closes, and
    /// one that fails after it started is refused (`FailedStreamedCallPolicy`
    /// does not apply to forced calls), never finished. Without it a long
    /// forced answer had no first content before generation ended and missed
    /// the coordinator's first-content deadline. Other families' forced calls
    /// keep validate-then-expose, as does a client that does not stream, and
    /// native channel families keep their own withheld framing. The request
    /// must come from a surface that renders fragments (chat streaming).
    private static func exposesCallsWhileGenerated(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        context: ChatTemplateFixContext,
        strategy: ToolChoiceEnforcementPolicy.Strategy,
        forced: ForcedCalls
    ) -> Bool {
        guard request.streamToolCallDeltas, !ToolChoiceEnforcementPolicy.usesNativeTextChannels(context)
        else { return false }
        switch prepared.mode {
        case .auto: return true
        case .required, .named:
            guard prepared.clientStreams else { return false }
            switch strategy {
            case .gemmaGrammar: return forced.gemma
            case .structuredPostValidation:
                return forced.qwen && ToolChoiceEnforcementPolicy.splitsQwenReasoningBeforeTools(context)
            case .harmonyFraming: return forced.gptOSS
            case .none: return false
            }
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
