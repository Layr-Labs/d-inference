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

    static func makeHandler(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        modelType: String?,
        streamToolCalls: Bool = streamsToolCallsByDefault
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
                context: context) ? streamingOptions(prepared) : nil)
    }

    /// Only `auto` calls are exposed before they close: required/named calls
    /// keep validate-then-expose, and native channel families keep their own
    /// withheld framing. The request must come from a surface that renders
    /// fragments (chat streaming).
    private static func exposesCallsWhileGenerated(
        request: OpenAIChatCompletionRequest,
        prepared: ToolChoicePromptPolicy.Prepared,
        context: ChatTemplateFixContext
    ) -> Bool {
        request.streamToolCallDeltas && prepared.mode == .auto
            && !ToolChoiceEnforcementPolicy.usesNativeTextChannels(context)
    }

    /// A call is exposed only once its resolved name is declared. Any other
    /// call completes in one piece and is validated before it is shown,
    /// unless the parser rejects the frame and returns it as text.
    private static func streamingOptions(_ prepared: ToolChoicePromptPolicy.Prepared) -> ToolCallStreamingOptions {
        let allowed = prepared.allowedToolNames
        return ToolCallStreamingOptions(exposesName: { allowed.contains($0) })
    }
}
