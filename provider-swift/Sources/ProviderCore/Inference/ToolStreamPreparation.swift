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

    /// `DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS`: `0`, `off`, `false` or `no`
    /// keeps GLM-5.3-Flash calls (`auto` and forced) withheld until the end
    /// of generation (0.10.15). Read once per process.
    static let streamGLMToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS"
    static let streamsGLMToolCallsByDefault = streamsGLMToolCalls(
        environment: ProcessInfo.processInfo.environment)

    static func streamsGLMToolCalls(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[streamGLMToolCallsEnvironmentKey])
    }

    /// GLM-5.3-Flash calls, `auto` and forced, are exposed while generated
    /// (`GLM5ToolCallStream`) to a client that itself streams, on a surface
    /// that renders fragments, when neither switch is off, nor, for a forced
    /// call, `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS`. Its reasoning is
    /// then split before tool parsing (the scheduler's native channel), so a
    /// frame drafted in a thought is never a call. A JSON `response_format`
    /// (withheld until it validates) and a client that does not stream keep
    /// the complete-call path: the whole suffix, parsed at EOS.
    static func streamsGLMCalls(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamGLMToolCalls: Bool = streamsGLMToolCallsByDefault,
        streamForcedToolCalls: ForcedCalls = streamsForcedToolCallsByDefault
    ) -> Bool {
        guard streamToolCalls, streamGLMToolCalls, !prepared.requiresToolCall || streamForcedToolCalls.glm,
            GLM5NextPromptPolicy.applies(modelType: modelType),
            request.streamToolCallDeltas, prepared.clientStreams, prepared.glmResponseFormat == nil,
            prepared.tools?.isEmpty == false
        else { return false }
        return prepared.mode != .none
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
        /// MiMo V2.6, Nemotron 3.5 and Bonsai 2: prompt-forced, checked as
        /// Qwen's are. Only the master switch governs them here;
        /// `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS` governs `auto` and forced.
        var native = true
        /// GLM-5.3-Flash: prompt-forced, with no sampler grammar
        /// (`GLM5ToolCallStream`). Its own switch,
        /// `DARKBLOOM_TTFT_STREAM_GLM_TOOL_CALLS`, governs `auto` and forced
        /// alike, so only the master sets this.
        var glm = true

        static let all = ForcedCalls()
        static let none = ForcedCalls(gemma: false, qwen: false, gptOSS: false, native: false, glm: false)

        init(gemma: Bool = true, qwen: Bool = true, gptOSS: Bool = true, native: Bool = true, glm: Bool = true) {
            (self.gemma, self.qwen, self.gptOSS, self.native, self.glm) = (gemma, qwen, gptOSS, native, glm)
        }

        init(environment: [String: String]) {
            func isOn(_ key: String) -> Bool { !ToolOutputLeniencySwitch.isOff(environment[key]) }
            let every = isOn(streamForcedToolCallsEnvironmentKey)
            self.init(gemma: every,
                qwen: every && isOn(streamForcedQwenToolCallsEnvironmentKey),
                gptOSS: every && isOn(streamForcedGPTOSSToolCallsEnvironmentKey),
                native: every, glm: every)
        }
    }

    /// `DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS`: `0`, `off`, `false` or `no`
    /// keeps MiMo V2.6, Nemotron 3.5 and Bonsai calls (`auto` and forced) on the
    /// complete-call path, released at the engine terminal (0.10.15).
    /// `DARKBLOOM_TTFT_STREAM_FORCED_TOOL_CALLS` off does so for their forced
    /// calls. Read once per process.
    static let streamNativeToolCallsEnvironmentKey = "DARKBLOOM_TTFT_STREAM_NATIVE_TOOL_CALLS"
    static let streamsNativeToolCallsByDefault = streamsNativeToolCalls(
        environment: ProcessInfo.processInfo.environment)

    static func streamsNativeToolCalls(environment: [String: String]) -> Bool {
        !ToolOutputLeniencySwitch.isOff(environment[streamNativeToolCallsEnvironmentKey])
    }

    /// Inkling 2: each call leaves when its frame closes, complete and checked,
    /// to a client that streams on a surface that renders fragments, for every
    /// mode that calls, under the switches native families stream under. Any
    /// other request gets its calls at the end of generation.
    static func streamsInklingCalls(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamNativeToolCalls: Bool = streamsNativeToolCallsByDefault,
        streamForcedToolCalls: ForcedCalls = streamsForcedToolCallsByDefault
    ) -> Bool {
        guard streamToolCalls, streamNativeToolCalls, request.streamToolCallDeltas, prepared.clientStreams,
            prepared.tools?.isEmpty == false
        else { return false }
        switch prepared.mode {
        case .auto: return true
        case .required, .named: return streamForcedToolCalls.native
        case .none: return false
        }
    }

    /// The served native-channel families whose calls stream, each with the
    /// only parser its frames stream through: MiMo V2.6 (`.mimoV2`), the
    /// Nemotron 3.5 builds the scheduler serves (Lightning, `.nemotron`) and
    /// the admitted Bonsai builds (`.qwen35`). Nemotron 3.5 Super streams
    /// through its own owner (`NemotronSuperLocalOutput`). Qwen 4 and
    /// diffusion Gemma, not served, keep their withheld framing.
    static func streamsNativeFamilyCalls(_ context: ChatTemplateFixContext, format: ToolCallFormat) -> Bool {
        switch format {
        case .mimoV2: context.modelType == "mimo_v2"
        case .nemotron:
            context.modelType == "nemotron_h" && EngineV2SupportedModels.isNemotron35ListingModelID(context.modelId)
        case .qwen35:
            context.modelType == "prism_hadamard_qwen35" && ToolChoiceEnforcementPolicy.nativeStructuredTarget(context)
        default: false
        }
    }

    static func makeHandler(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamForcedToolCalls: ForcedCalls = streamsForcedToolCallsByDefault,
        streamNativeToolCalls: Bool = streamsNativeToolCallsByDefault
    ) throws -> BatchedToolStreamHandler? {
        let isMiMo = modelType == "mimo_v2"
        if Inkling2PromptContract.applies(modelType: modelType) {
            // Inkling 2's calls are framed by its own message tokens and read
            // by its channel lexer (`NativeToolStreamRouter`), never by a text
            // tool parser; a forced choice still needs its prompt strategy.
            _ = try ToolChoiceEnforcementPolicy.forcedStrategy(mode: prepared.mode,
                modelContext: ChatTemplateFixContext(modelId: request.model, modelType: modelType))
            return nil
        }
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
            tools: (isMiMo && prepared.mode == .none ? request.tools : prepared.argumentTools ?? prepared.tools)?
                .map { $0.toolSpec() },
            strictGemma: modelType == "diffusion_gemma",
            streaming: streamToolCalls && exposesCallsWhileGenerated(request: request, prepared: prepared,
                context: context, strategy: strategy, format: format, forced: streamForcedToolCalls,
                native: streamNativeToolCalls)
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
    /// keep validate-then-expose, as does a client that does not stream. The
    /// request must come from a surface that renders fragments (chat
    /// streaming).
    ///
    /// Native channel families keep their withheld framing, except MiMo V2.6,
    /// Nemotron 3.5 and Bonsai 2 (`streamsNativeFamilyCalls`, checked before
    /// the strategies above, so Bonsai's `.structuredPostValidation` stays
    /// here): their `auto` and forced calls stream to a client that streams,
    /// under the same rules (each checked when its frame closes, forced
    /// answers calls only, a call that fails after it started refused). Their
    /// forced calls also need the forced master switch (`ForcedCalls.native`).
    /// A client that does not stream keeps the complete-call output for every
    /// mode, and so does any other build whose parser now streams (`.mimoV2`,
    /// `.nemotron`).
    private static func exposesCallsWhileGenerated(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        context: ChatTemplateFixContext,
        strategy: ToolChoiceEnforcementPolicy.Strategy,
        format: ToolCallFormat,
        forced: ForcedCalls,
        native: Bool
    ) -> Bool {
        guard request.streamToolCallDeltas else { return false }
        if ToolChoiceEnforcementPolicy.usesNativeTextChannels(context) || format == .mimoV2 || format == .nemotron {
            guard native, prepared.clientStreams, streamsNativeFamilyCalls(context, format: format)
            else { return false }
            switch prepared.mode {
            case .auto: return true
            case .required, .named: return forced.native
            case .none: return false
            }
        }
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
