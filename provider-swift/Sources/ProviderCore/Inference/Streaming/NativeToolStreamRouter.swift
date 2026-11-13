import Foundation
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
    private var rejectedNativeGemmaReasoning = false
    private let withholdReasoning: Bool
    private var withheldReasoning = ""
    private let tools: [[String: any Sendable]]?
    /// An `auto` GLM tool suffix that does not parse is text (`GLM5ToolSuffix`).
    private let glmUnparsedOutputIsText: Bool
    /// Validation contract for calls exposed while generated; nil keeps the
    /// complete-call path (calls flushed at the engine terminal).
    private let streamedCallPolicy: ToolChoicePromptPolicy.Prepared?
    private var exposedCallCount = 0
    private var openCallIndex: Int?
    private var openCallName: String?
    /// Every call exposed so far whose frame parsed, each already accepted by
    /// `ToolConstraintValidation` (which returns `auto` calls as generated
    /// unless the request is `strict`).
    private(set) var completedToolCalls: [ToolCall] = []

    // Pass the same prepared schemas used by the handler: Flint's raw-string
    // boundaries must agree before and after reasoning-channel separation.
    init(handler: BatchedToolStreamHandler?, requiresToolCall: Bool, nativePrefix: String?,
         tools: [[String: any Sendable]]? = nil,
         preserveInnerReasoningSpans: Bool = false, nativeGemmaChannels: Bool = false,
         nativeGemmaReasoningEnabled: Bool = true, nativeMiMoChannels: Bool = false,
         nativeMiMoThinkingEnabled: Bool = true, nativeMiMoRequiresConstraint: Bool = false,
         absorbStrayThinkClose: Bool = false, withholdReasoning: Bool = false,
         streamedCalls: ToolChoicePromptPolicy.Prepared? = nil,
         glmUnparsedOutputIsText: Bool = GLM5ToolSuffix.returnsUnparsedOutputAsTextByDefault) {
        self.handler = handler
        self.withholdReasoning = withholdReasoning
        self.tools = tools
        self.glmUnparsedOutputIsText = glmUnparsedOutputIsText
        self.requiresToolCall = requiresToolCall
        self.nativeGemmaReasoningEnabled = nativeGemmaReasoningEnabled
        self.nativeMiMoChannels = nativeMiMoChannels
        self.nativeMiMoRequiresConstraint = nativeMiMoRequiresConstraint
        self.rejectMiMoThought = nativeMiMoChannels && !nativeMiMoThinkingEnabled
        self.streamedCallPolicy = handler?.streamsCalls == true ? streamedCalls : nil
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

    /// True when calls leave as `.toolCallDelta` events while generated.
    var streamsToolCalls: Bool { streamedCallPolicy != nil }

    /// Reasoning classified since the last call but withheld from the events
    /// at the caller's request. Its owner counts it as generated reasoning; it
    /// is never emitted, logged or part of the response hash.
    mutating func takeWithheldReasoning() -> String {
        defer { withheldReasoning = "" }
        return withheldReasoning
    }

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

    /// End of generation for streamed calls: completes a call whose end tag
    /// is a stop token and flushes unexposed buffers. A call cut off by the
    /// output-token limit stays truncated, as in OpenAI streams, even when a
    /// lenient EOS parse reads its partial arguments as a different call;
    /// any other unfinished exposed call is model noncompliance.
    mutating func finishToolCalls(truncated: Bool) throws -> [MLXServerGenerationEvent] {
        guard let handler, let prepared = streamedCallPolicy else { return [] }
        var events: [MLXServerGenerationEvent] = []
        for segment in handler.finishSegments() {
            if truncated, case .callFailed = segment {
                openCallIndex = nil
                continue
            }
            events += try routeToolSegment(segment, prepared: prepared, truncated: truncated)
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
    /// is published. GLM validates the entire retained suffix only at EOS; on
    /// an `auto` request a suffix that does not parse is text
    /// (`finishCompleteCalls`), not a failure.
    func checkNativeToolFailure() throws {
        guard nativeMiMoChannels || handler?.format == .glm5 || handler?.format == .flint,
            (handler?.parseFailureCount ?? 0) > 0 else { return }
        if returnsUnparsedGLMOutputAsText { return }
        let model = handler?.format == .glm5 ? "GLM" : handler?.format == .flint ? "Flint" : "MiMo"
        let message = "native \(model) tool output is invalid"
        if requiresToolCall || nativeMiMoRequiresConstraint {
            throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(message)
        }
        throw MultiModelBatchSchedulerEngineError.generationFailed(message)
    }

    /// End of generation on the complete-call path: the handler's calls and
    /// its residual text. An `auto` GLM suffix that did not parse as one batch
    /// is split into text and its final calls (`GLM5ToolSuffix`), except in an
    /// output the token limit cut off, where it stays text. A suffix whose
    /// release would expose a think marker from inside a tool frame keeps
    /// failing, as before.
    func finishCompleteCalls(truncated: Bool) throws -> (calls: [ToolCall], residual: String?) {
        guard let handler else { return ([], nil) }
        let calls = handler.finish()
        let residual = handler.takeResidualText()
        guard returnsUnparsedGLMOutputAsText, calls.isEmpty, let residual else { return (calls, residual) }
        switch GLM5ToolSuffix.split(residual, tools: tools) {
        case .text(let text, calls: let found): return truncated ? ([], residual) : (found, text)
        case .ambiguous: throw MultiModelBatchSchedulerEngineError.generationFailed("native GLM tool output is invalid")
        }
    }

    private var returnsUnparsedGLMOutputAsText: Bool {
        handler?.format == .glm5 && glmUnparsedOutputIsText && !requiresToolCall
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
                } else if withholdReasoning {
                    // Classified exactly like visible reasoning, so its
                    // tool-like text stays inert; only emission differs.
                    withheldReasoning += reasoning
                } else {
                    events.append(.parsed(.init(content: "", reasoningContent: reasoning)))
                }
            }
            guard !piece.content.isEmpty else { continue }
            if let handler, let prepared = streamedCallPolicy {
                for segment in handler.processChunkSegments(piece.content) {
                    events += try routeToolSegment(segment, prepared: prepared)
                }
                continue
            }
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
                // Framing whitespace around and between call frames is not an
                // answer on any path, including legacy Qwen text without
                // native channels.
                if ToolChoiceEnforcementPolicy.isFramingWhitespace(visible) { continue }
                throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                    "forced tool_choice produced visible text before a validated call")
            }
            events.append(visibleEvent(visible))
        }
        return events
    }

    /// Streamed calls are `auto` only. Each is validated (declared name,
    /// schema, cardinality) as soon as that is decidable: the cardinality at
    /// its first fragment, the arguments when its frame closes. Without
    /// `strict` only the cardinality is (`returnsAutoCallsAsGenerated`).
    private mutating func routeToolSegment(
        _ segment: ToolCallStreamSegment, prepared: ToolChoicePromptPolicy.Prepared, truncated: Bool = false
    ) throws -> [MLXServerGenerationEvent] {
        switch segment {
        case .text(let text):
            return text.isEmpty ? [] : [visibleEvent(text)]
        case .callStarted(let name):
            let index = try admitCall(prepared)
            openCallIndex = index
            openCallName = name
            return [.toolCallDelta(.init(index: index, name: name))]
        case .callArguments(let fragment):
            guard let index = openCallIndex, !fragment.isEmpty else { return [] }
            return [.toolCallDelta(.init(index: index, arguments: fragment))]
        case .callCompleted(let call, let remainder):
            guard let index = openCallIndex else { return [] }
            openCallIndex = nil
            try ToolConstraintValidation.validate([call], prepared: prepared, truncated: truncated)
            completedToolCalls.append(call)
            return [.toolCallDelta(.init(index: index, arguments: remainder, completed: call))]
        case .callFailed(let failure):
            defer { openCallIndex = nil }
            guard prepared.returnsAutoCallsAsGenerated, let index = openCallIndex, let name = openCallName
            else {
                throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                    ToolNoncomplianceCheck.streamedCallViolation(failure))
            }
            // Its arguments already left exactly as generated: OpenAI's raw
            // `arguments` string for JSON that does not parse. Only close the
            // call, so the response finishes with `tool_calls`; the closing
            // call's empty arguments are never sent, and a call that did not
            // parse is not one of `completedToolCalls`.
            return [.toolCallDelta(.init(index: index,
                completed: ToolCall(function: .init(name: name, arguments: [String: MLXLMCommon.JSONValue]()))))]
        case .call(let call):
            // Never exposed (e.g. an undeclared name): validate before showing.
            try ToolConstraintValidation.validate([call], prepared: prepared, truncated: truncated)
            let index = try admitCall(prepared)
            completedToolCalls.append(call)
            let arguments = String(
                decoding: try JSONEncoder.openAIServer.encode(call.function.arguments), as: UTF8.self)
            return [.toolCallDelta(.init(index: index, name: call.function.name, arguments: arguments,
                completed: call))]
        }
    }

    private mutating func admitCall(_ prepared: ToolChoicePromptPolicy.Prepared) throws -> Int {
        if !prepared.allowsParallelCalls, exposedCallCount > 0 {
            throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                ToolNoncomplianceCheck.parallelViolation)
        }
        defer { exposedCallCount += 1 }
        return exposedCallCount
    }
}
