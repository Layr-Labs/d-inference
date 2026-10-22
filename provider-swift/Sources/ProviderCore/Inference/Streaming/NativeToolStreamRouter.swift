import MLXLMCommon
import MLXLMServer

/// Classify native reasoning BEFORE tool parsing. Tool-like text inside a
/// reasoning block is never an invocation. Original token accounting is owned
/// by the engine; this layer only routes already generated text.
struct NativeToolStreamRouter {
    private let handler: BatchedToolStreamHandler?
    private let requiresToolCall: Bool
    private var parser: NativeChannelSplitter?
    private var gemmaParser: DiffusionGemmaChannelSplitter?
    private let nativeGemmaReasoningEnabled: Bool
    private let nativeMiMoChannels: Bool
    private let nativeMiMoRequiresConstraint: Bool
    private let rejectMiMoThought: Bool
    /// Reasoning is split and withheld: the request asked not to see it.
    private let withholdsReasoning: Bool
    private var rejectedNativeGemmaReasoning = false

    // Pass the same prepared schemas used by the handler: Flint's raw-string
    // boundaries must agree before and after reasoning-channel separation.
    init(handler: BatchedToolStreamHandler?, requiresToolCall: Bool, nativePrefix: String?,
         tools: [[String: any Sendable]]? = nil,
         preserveInnerReasoningSpans: Bool = false, nativeGemmaChannels: Bool = false,
         nativeGemmaReasoningEnabled: Bool = true, nativeMiMoChannels: Bool = false,
         nativeMiMoThinkingEnabled: Bool = true, nativeMiMoRequiresConstraint: Bool = false,
         absorbStrayThinkClose: Bool = false, withholdsReasoning: Bool = false) {
        self.handler = handler
        self.withholdsReasoning = withholdsReasoning
        self.requiresToolCall = requiresToolCall
        self.nativeGemmaReasoningEnabled = nativeGemmaReasoningEnabled
        self.nativeMiMoChannels = nativeMiMoChannels
        self.nativeMiMoRequiresConstraint = nativeMiMoRequiresConstraint
        self.rejectMiMoThought = nativeMiMoChannels && !nativeMiMoThinkingEnabled
        if nativeGemmaChannels {
            gemmaParser = DiffusionGemmaChannelSplitter()
        } else if let nativePrefix {
            self.parser = NativeChannelSplitter(prefix: nativePrefix, protectToolFrames: handler != nil,
                qwenStructuredFrames: handler?.format == .qwen35 || handler?.format == .mimoV2,
                flintFrames: handler?.format == .flint,
                tools: tools,
                preserveInnerReasoningSpans: preserveInnerReasoningSpans,
                absorbStrayThinkClose: absorbStrayThinkClose)
        }
    }

    var usesNativeChannels: Bool { parser != nil || gemmaParser != nil }

    mutating func process(_ text: String) throws -> [MLXServerGenerationEvent] {
        let pieces: [ParsedReasoning]
        if gemmaParser != nil { pieces = gemmaParser!.parse(text) }
        else { pieces = parser != nil ? parser!.parse(text) : [.init(content: text, reasoningContent: nil)] }
        try checkReasoningState()
        try checkNativeToolFailure()
        return try route(pieces)
    }

    mutating func finishText() throws -> [MLXServerGenerationEvent] {
        let pieces = gemmaParser != nil ? gemmaParser!.finish() : (parser?.finish() ?? [])
        try checkReasoningState()
        try checkNativeToolFailure()
        let events = try route(pieces)
        if handler?.format == .flint {
            // EOF can expose an incomplete frame only when the handler flushes.
            // Validate it here, before the caller's generic auto-mode residual
            // fallback can publish tool syntax as ordinary content. finish() is
            // idempotent for completed frames and does not drain validated calls.
            _ = handler?.finish()
            try checkNativeToolFailure()
        }
        return events
    }

    private func checkReasoningState() throws {
        if rejectedNativeGemmaReasoning {
            throw disabledNativeReasoningFailure
        }
        if parser?.reasoningNestingLimitExceeded == true {
            throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                "native reasoning span nesting exceeded the safety limit")
        }
    }

    func visibleEvent(_ text: String) -> MLXServerGenerationEvent {
        usesNativeChannels ? .parsed(.init(content: text, reasoningContent: nil)) : .content(text)
    }

    private var disabledNativeReasoningFailure: MultiModelBatchSchedulerEngineError {
        let message = "native reasoning output is disabled for this request"
        // A forced-tool failure stays model noncompliance (422), preserving
        // bounded failover and the existing provider-reputation exemption.
        return requiresToolCall || nativeMiMoRequiresConstraint
            ? .toolChoiceViolation(message) : .generationFailed(message)
    }

    /// Also called after the SDK EOS flush, before residual text or any call
    /// is published. GLM validates the entire retained suffix only at EOS.
    func checkNativeToolFailure() throws {
        guard nativeMiMoChannels || handler?.format == .glm5 || handler?.format == .flint,
            (handler?.parseFailureCount ?? 0) > 0 else { return }
        let model = handler?.format == .glm5 ? "GLM" : handler?.format == .flint ? "Flint" : "MiMo"
        let message = "native \(model) tool output is invalid"
        if requiresToolCall || nativeMiMoRequiresConstraint {
            throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(message)
        }
        throw MultiModelBatchSchedulerEngineError.generationFailed(message)
    }

    private mutating func route(_ pieces: [ParsedReasoning]) throws -> [MLXServerGenerationEvent] {
        var events: [MLXServerGenerationEvent] = []
        for piece in pieces {
            if let reasoning = piece.reasoningContent, !reasoning.isEmpty {
                if (gemmaParser != nil && !nativeGemmaReasoningEnabled) || rejectMiMoThought {
                    // Empty native envelopes may contain framing whitespace.
                    // Never promote a call/example from an unclosed thought,
                    // or expose disabled thought before a later error frame.
                    if !ToolChoiceEnforcementPolicy.isFramingWhitespace(reasoning) {
                        rejectedNativeGemmaReasoning = true
                        throw disabledNativeReasoningFailure
                    }
                } else if !withholdsReasoning {
                    events.append(.parsed(.init(content: "", reasoningContent: reasoning)))
                }
            }
            guard !piece.content.isEmpty else { continue }
            let visible: String?
            if let handler { visible = handler.processChunk(piece.content) }
            else { visible = piece.content }
            // Complete malformed frames may be returned as visible fallback
            // by the shared parser. Refuse BEFORE exposing that return value,
            // including pieces produced by finishText. Other families retain
            // their existing fallback contract.
            try checkNativeToolFailure()
            guard let visible, !visible.isEmpty else { continue }
            if requiresToolCall {
                if usesNativeChannels && ToolChoiceEnforcementPolicy.isFramingWhitespace(visible) { continue }
                throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                    "forced tool_choice produced visible text before a validated call")
            }
            events.append(visibleEvent(visible))
        }
        return events
    }
}
