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
    /// the complete-call path: the whole suffix, parsed at EOS. The caller
    /// checks that the request's handler parses GLM's own format.
    static func streamsGLMCalls(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamGLMToolCalls: Bool = streamsGLMToolCallsByDefault,
        streamForcedToolCalls: ForcedCalls = streamsForcedToolCallsByDefault
    ) -> Bool {
        exposure(request: request, prepared: prepared, modelType: modelType, parser: .glm5,
            switches: .init(toolCalls: streamToolCalls, forced: streamForcedToolCalls, glm: streamGLMToolCalls))
            == .streamed(.glmFrames)
    }

    /// How one request's calls leave on the scheduler's path
    /// (`ToolCallExposure.resolve`): its model's family, the parser its
    /// handler resolved and its prepared choice.
    static func exposure(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        parser: ToolCallFormat,
        switches: ToolCallExposure.Switches = .current
    ) -> ToolCallExposure {
        ToolCallExposure.resolve(
            family: .of(ChatTemplateFixContext(modelId: request.model, modelType: modelType)),
            parser: parser,
            request: .init(
                mode: prepared.mode, clientStreams: prepared.clientStreams,
                rendersFragments: request.streamToolCallDeltas,
                offersTools: prepared.tools?.isEmpty == false,
                withholdsJSONAnswer: prepared.glmResponseFormat != nil),
            switches: switches)
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

        /// The families, one per switch above.
        enum Family: Equatable, Sendable, CaseIterable { case gemma, qwen, gptOSS, native, glm }

        subscript(family: Family) -> Bool {
            switch family {
            case .gemma: gemma
            case .qwen: qwen
            case .gptOSS: gptOSS
            case .native: native
            case .glm: glm
            }
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

    static func makeHandler(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault,
        streamForcedToolCalls: ForcedCalls = streamsForcedToolCallsByDefault,
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
        let resolved = exposure(request: request, prepared: prepared, modelType: modelType, parser: format,
            switches: .init(toolCalls: streamToolCalls, forced: streamForcedToolCalls,
                native: streamNativeToolCalls))
        return BatchedToolStreamHandler(format: format,
            tools: (isMiMo && prepared.mode == .none ? request.tools : prepared.tools)?.map { $0.toolSpec() },
            strictGemma: modelType == "diffusion_gemma",
            streaming: resolved == .streamed(.parserFrames) ? streamingOptions(prepared) : nil)
    }

    /// A call is exposed only once its resolved name is declared. Any other
    /// call completes in one piece and is validated before it is shown,
    /// unless the parser rejects the frame and returns it as text.
    private static func streamingOptions(_ prepared: ToolChoicePromptPolicy.Prepared) -> ToolCallStreamingOptions {
        let allowed = prepared.allowedToolNames
        return ToolCallStreamingOptions(exposesName: { allowed.contains($0) })
    }
}
