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
    /// Inkling 2's own message protocol (`Inkling2OutputChannels`): its
    /// reasoning, answer and call frames are read here, with no SDK handler.
    private var inklingParser: Inkling2OutputChannels?
    /// Inkling 2 calls held for the end of generation (complete-call path).
    private var inklingCalls: [ToolCall] = []
    private let nativeGemmaReasoningEnabled: Bool
    private let nativeMiMoChannels: Bool
    private let nativeMiMoRequiresConstraint: Bool
    private let rejectMiMoThought: Bool
    private var rejectedNativeGemmaReasoning = false
    private let withholdReasoning: Bool
    private var withheldReasoning = ""
    private let tools: [[String: any Sendable]]?
    /// An `auto` GLM tool suffix that does not parse at EOS is text
    /// (`GLM5ToolSuffix`).
    private let glmUnparsedOutputIsText: Bool
    /// The request's tool choice is `auto`: the only mode whose residual text
    /// the caller publishes.
    private let autoToolChoice: Bool
    /// `finishCompleteCalls` has released the EOS suffix that way, which
    /// answers its parse failure.
    private var glmSuffixSplit = false
    /// Forced GPT-OSS calls: the analysis text before the call.
    private var harmonyAnalysis: HarmonyForcedCallText?
    /// GPT-OSS `auto` while its grammar is on: the choice whose calls to
    /// undeclared functions are refused (`refuseUndeclaredHarmonyCall`).
    private let harmonyAutoChoice: ToolChoicePromptPolicy.Prepared?
    /// Validation contract for calls exposed while generated; nil keeps the
    /// complete-call path (calls flushed at the engine terminal).
    private let streamedCallPolicy: ToolChoicePromptPolicy.Prepared?
    /// GLM calls exposed while generated (`ToolStreamPreparation.streamsGLMCalls`):
    /// the SDK handler keeps its whole tool suffix to EOS, so these frames are
    /// read here instead.
    private let glmCalls: GLM5ToolCallStream?
    private var exposedCallCount = 0
    private var openCallIndex: Int?
    private var openCallName: String?
    /// `parallel_tool_calls: false`: the frames of calls after the first.
    private var laterCalls = ParallelToolCallPolicy.LaterCallFilter()
    /// Every call exposed so far whose frame parsed, each already accepted by
    /// `ToolConstraintValidation` (which returns `auto` calls as generated
    /// unless the request is `strict`).
    private(set) var completedToolCalls: [ToolCall] = []
    /// Set by the owner once an event of this response has left: a `strict`
    /// call that fails its check may then leave as generated
    /// (`StrictToolCallPolicy`).
    var responseStarted = false
    /// Telemetry: at a cut, streamed calls left open and calls never exposed
    /// that were dropped, and whether an `auto` GLM suffix lost the frames
    /// that end the cut output, closed or not (`finishCompleteCalls`), or a
    /// streamed GLM frame never exposed and still open (`finishToolCalls`);
    /// `strict` calls that failed their check and left as generated because
    /// the response started.
    private(set) var callsLeftOpenAtCut = 0
    private(set) var callsDroppedAtCut = 0
    private(set) var glmFramesDroppedAtCut = false
    private(set) var strictCallsReturnedAsGenerated = 0
    /// Calls this response returned as generated that break its declaration
    /// (`ToolConstraintValidation.breaksDeclaration`).
    private(set) var callsBreakingDeclaration = 0
    /// Failed calls closed with the arguments they sent
    /// (`refusesFailedStreamedCalls` off): returned, and breaking.
    private(set) var callsClosedUnparsed = 0
    /// `FailedStreamedCallPolicy`: injectable for tests.
    var refusesFailedStreamedCalls = FailedStreamedCallPolicy.refuses

    // Pass the same prepared schemas used by the handler: Flint's raw-string
    // boundaries must agree before and after reasoning-channel separation.
    init(handler: BatchedToolStreamHandler?, requiresToolCall: Bool, nativePrefix: String?,
         tools: [[String: any Sendable]]? = nil,
         preserveInnerReasoningSpans: Bool = false, promotesTrailingReasoningCalls: Bool = false,
         nativeGemmaChannels: Bool = false,
         nativeGemmaReasoningEnabled: Bool = true, nativeMiMoChannels: Bool = false,
         nativeMiMoThinkingEnabled: Bool = true, nativeMiMoRequiresConstraint: Bool = false,
         absorbStrayThinkClose: Bool = false, withholdReasoning: Bool = false,
         streamedCalls: ToolChoicePromptPolicy.Prepared? = nil,
         streamsGLMCalls: Bool = false,
         glmUnparsedOutputIsText: Bool = GLM5ToolSuffix.returnsUnparsedOutputAsTextByDefault,
         harmonyAutoToolGrammar: Bool = GPTOSSAutoToolGrammar.enabled,
         nativeInklingChannels: Bool = false, inklingStreamsCalls: Bool = false,
         inklingUndeclaredCallsAreText: Bool = Inkling2OutputChannels.undeclaredCallsAreTextByDefault) {
        self.handler = handler
        self.withholdReasoning = withholdReasoning
        self.tools = tools
        self.glmUnparsedOutputIsText = glmUnparsedOutputIsText
        self.requiresToolCall = requiresToolCall
        self.nativeGemmaReasoningEnabled = nativeGemmaReasoningEnabled
        self.nativeMiMoChannels = nativeMiMoChannels
        self.nativeMiMoRequiresConstraint = nativeMiMoRequiresConstraint
        self.rejectMiMoThought = nativeMiMoChannels && !nativeMiMoThinkingEnabled
        if streamsGLMCalls, handler?.format == .glm5, let allowed = streamedCalls?.allowedToolNames {
            glmCalls = GLM5ToolCallStream(tools: tools, exposesName: { allowed.contains($0) })
        } else {
            glmCalls = nil
        }
        // An Inkling 2 call is exposed when its frame closes, complete and
        // validated, to a client that streams (`inklingStreamsCalls`).
        self.streamedCallPolicy = handler?.streamsCalls == true || glmCalls != nil
            || (nativeInklingChannels && inklingStreamsCalls) ? streamedCalls : nil
        // The scheduler passes the prepared choice here on every path.
        self.autoToolChoice = streamedCalls.map { $0.mode == .auto } ?? !requiresToolCall
        if requiresToolCall, handler?.format == .harmony { harmonyAnalysis = HarmonyForcedCallText() }
        harmonyAutoChoice = harmonyAutoToolGrammar && handler?.format == .harmony && streamedCalls?.mode == .auto
            ? streamedCalls : nil
        if nativeInklingChannels {
            // An `auto` request that declares no tools renders no
            // `tool_declare`, so no call can be valid: a frame is answer text,
            // never a refusal (422 `undeclared_name`, or 500 unparsed).
            // Client stops follow (`Inkling2PromptContract.stopStringScope`).
            inklingParser = Inkling2OutputChannels(
                callsAreText: inklingUndeclaredCallsAreText && autoToolChoice && tools?.isEmpty != false,
                readsCallOpeningAnswer: tools?.isEmpty == false)
        } else if nativeGemmaChannels {
            gemmaParser = DiffusionGemmaChannelSplitter()
        } else if let nativePrefix {
            self.parser = NativeChannelSplitter(prefix: nativePrefix, protectToolFrames: handler != nil,
                qwenStructuredFrames: handler?.format == .qwen35 || handler?.format == .mimoV2,
                flintFrames: handler?.format == .flint,
                glmFrames: handler?.format == .glm5,
                tools: tools,
                preserveInnerReasoningSpans: preserveInnerReasoningSpans,
                absorbStrayThinkClose: absorbStrayThinkClose,
                // Nemotron 3.5 drafts calls after an early `</think>`, then closes again.
                holdsFramesAfterThought: handler?.format == .nemotron,
                promotesTrailingCalls: promotesTrailingReasoningCalls)
        }
    }

    var usesNativeChannels: Bool { parser != nil || gemmaParser != nil || inklingParser != nil }

    /// True when calls leave as `.toolCallDelta` events while generated.
    var streamsToolCalls: Bool { streamedCallPolicy != nil }

    /// Streamed GLM frames never exposed that became text
    /// (`GLM5ToolCallStream.unparsedFrames`): the complete-call path's parse
    /// failures, for its `auto` fallback telemetry.
    var glmUnparsedFrames: Int { glmCalls?.unparsedFrames ?? 0 }

    /// The engine stopped at the token limit (`length`): a thought it cut off
    /// promotes none of its frames.
    mutating func outputReachedTokenLimit() {
        parser?.outputReachedTokenLimit()
    }

    /// Reasoning classified since the last call but withheld from the events
    /// at the caller's request. Its owner counts it as generated reasoning; it
    /// is never emitted, logged or part of the response hash.
    mutating func takeWithheldReasoning() -> String {
        defer { withheldReasoning = "" }
        return withheldReasoning
    }

    mutating func process(_ text: String) throws -> [MLXServerGenerationEvent] {
        if inklingParser != nil {
            let pieces = inklingParser!.parse(text)
            try checkNativeToolFailure()
            return try routeInkling(pieces, cutAtLimit: false)
        }
        let pieces: [ParsedReasoning]
        if gemmaParser != nil { pieces = gemmaParser!.parse(text) }
        else { pieces = parser != nil ? parser!.parse(text) : [.init(content: text, reasoningContent: nil)] }
        try checkReasoningState()
        try checkNativeToolFailure()
        return try route(pieces)
    }

    /// `cutAtLimit`: the engine cut the answer at the token limit and it ends
    /// as `length` (`TokenLimitCutPolicy`). What the flush releases is then an
    /// unfinished frame: forced-choice text is dropped and a native frame
    /// that no longer parses is not refused (the caller drops its text).
    mutating func finishText(cutAtLimit: Bool = false) throws -> [MLXServerGenerationEvent] {
        if inklingParser != nil {
            let pieces = inklingParser!.finish()
            let events = try routeInkling(pieces, cutAtLimit: cutAtLimit)
            if !cutAtLimit { try checkNativeToolFailure() }
            return events
        }
        let pieces = gemmaParser != nil ? gemmaParser!.finish() : (parser?.finish() ?? [])
        try checkReasoningState()
        try checkNativeToolFailure()
        let events = try route(pieces, cutAtLimit: cutAtLimit)
        if handler?.format == .flint {
            // EOF can expose an incomplete frame only when the handler flushes.
            // Validate it here, before the caller's generic auto-mode residual
            // fallback can publish tool syntax as ordinary content. finish() is
            // idempotent for completed frames and does not drain validated calls.
            _ = handler?.finish()
            if !cutAtLimit { try checkNativeToolFailure() }
        }
        return events
    }

    /// End of generation for streamed calls: completes a call whose end tag
    /// is a stop token and flushes unexposed buffers. A call cut off by the
    /// output-token limit stays truncated, as in OpenAI streams, even when a
    /// lenient EOS parse reads its partial arguments as a different call;
    /// any other unfinished exposed call is model noncompliance. When the cut
    /// ends as `length` (`cutAtLimit`, `TokenLimitCutPolicy`), the flush
    /// completes no call: an exposed one stays open with the fragments it sent,
    /// unclosed, so the stream finishes `length` and no client can parse it,
    /// and one never exposed is not exposed.
    mutating func finishToolCalls(truncated: Bool, cutAtLimit: Bool = false) throws
        -> [MLXServerGenerationEvent]
    {
        guard let handler, let prepared = streamedCallPolicy else { return [] }
        var events: [MLXServerGenerationEvent] = []
        let unparsed = glmUnparsedFrames
        // Whichever source is in use: GLM's own stream or the handler. GLM's
        // never counts in `handler.parseFailureCount`, so the native checks
        // below never fire for it; its unparsed frames have their own rule.
        var segments = glmCalls?.finish(cutAtLimit: cutAtLimit) ?? handler.finishSegments()
        try refuseUnparsedGLMFrames(since: unparsed, cutAtLimit: cutAtLimit)
        if glmCalls?.droppedFrameAtCut == true { glmFramesDroppedAtCut = true }
        if cutAtLimit, hasNativeToolFailure {
            // A native frame the cut left unparsed is never published as text,
            // as on the complete-call path.
            segments.removeAll { if case .text = $0 { true } else { false } }
        } else {
            try refuseUnexposedNativeFailure(segments)
        }
        for segment in segments {
            // `parallel_tool_calls: false` drops a later call at a cut as
            // anywhere (`ParallelToolCallPolicy`): not the cut's to count.
            if cutAtLimit, laterCalls.drops(segment, exposedCalls: exposedCallCount, prepared: prepared) { continue }
            switch segment {
            case .callFailed where truncated:
                if cutAtLimit { recordCut(leftOpen: openCallIndex != nil) }
                openCallIndex = nil
            case .callCompleted where cutAtLimit:
                // Its remainder is the parse's closure, not generated text.
                recordCut(leftOpen: openCallIndex != nil)
                openCallIndex = nil
            case .callStarted where cutAtLimit:
                continue
            case .call where cutAtLimit:
                recordCut(leftOpen: false)
            default:
                events += try routeToolSegment(segment, prepared: prepared, truncated: truncated,
                    cutAtLimit: cutAtLimit)
            }
        }
        return events
    }

    /// A call recovered at the end of generation (`GPTOSSToolCallRecovery`),
    /// exposed and checked as a call never streamed is.
    mutating func recovered(_ call: ToolCall) throws -> [MLXServerGenerationEvent] {
        guard let prepared = streamedCallPolicy else { return [] }
        return try routeToolSegment(.call(call), prepared: prepared)
    }

    private mutating func recordCut(leftOpen: Bool) {
        if leftOpen { callsLeftOpenAtCut += 1 } else { callsDroppedAtCut += 1 }
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

    /// A native family's (MiMo, GLM, Flint) own call frame failed to parse.
    /// An `auto` GLM suffix that `finishCompleteCalls` returned as text is not
    /// a failure; one the SDK refused while streaming still is.
    var hasNativeToolFailure: Bool {
        if let inklingParser { return !inklingParser.toolFailures.isEmpty }
        return (nativeMiMoChannels || handler?.format == .glm5 || handler?.format == .flint)
            && (handler?.parseFailureCount ?? 0) > 0 && !glmSuffixSplit
    }

    /// The first Inkling 2 call frame that did not parse, for telemetry.
    var inklingToolFailure: Inkling2ToolFrameFailure? { inklingParser?.toolFailures.first }

    /// Streamed path: a native frame that failed to parse before any of it
    /// was exposed comes back as text; refuse it before that text leaves, as
    /// the complete-call path does. An exposed call that failed is refused by
    /// its own segment, with its check (`routeToolSegment`).
    private func refuseUnexposedNativeFailure(_ segments: [ToolCallStreamSegment]) throws {
        guard hasNativeToolFailure,
            !segments.contains(where: { if case .callFailed = $0 { true } else { false } })
        else { return }
        try checkNativeToolFailure()
    }

    /// Also called after the SDK EOS flush, before residual text or any call
    /// is published. GLM validates the entire retained suffix only at EOS; on
    /// an `auto` request a suffix that does not parse there is text
    /// (`finishCompleteCalls`), not a failure. A suffix the SDK rejects as
    /// oversized while streaming still fails.
    func checkNativeToolFailure() throws {
        guard hasNativeToolFailure else { return }
        let model = inklingParser != nil ? "Inkling"
            : handler?.format == .glm5 ? "GLM" : handler?.format == .flint ? "Flint" : "MiMo"
        let message = "native \(model) tool output is invalid"
        if requiresToolCall || nativeMiMoRequiresConstraint {
            throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(message)
        }
        throw MultiModelBatchSchedulerEngineError.generationFailed(message)
    }

    /// End of generation on the complete-call path: the handler's calls and
    /// its residual text. An `auto` GLM suffix that did not parse as one batch
    /// is split into text and its final calls (`GLM5ToolSuffix`; such a suffix
    /// in an output the token limit cut off is all text, while one that parses
    /// keeps its calls). A suffix whose release would expose a think marker
    /// from inside a tool frame keeps failing, as before. When the cut ends
    /// the answer as `length` (`cutAtLimit`, `TokenLimitCutPolicy`), such a
    /// suffix is not split, the frames that end it are dropped, and one whose
    /// kept text would still expose a think marker is dropped whole
    /// (`GLM5ToolSuffix.textAtCut`), never failing.
    mutating func finishCompleteCalls(truncated: Bool, cutAtLimit: Bool = false) throws
        -> (calls: [ToolCall], residual: String?)
    {
        if inklingParser != nil {
            // Every frame closed in `finishText`; no text is held as a suffix.
            defer { inklingCalls = [] }
            return (inklingCalls, nil)
        }
        guard let handler else { return ([], nil) }
        let calls = handler.finish()
        let residual = handler.takeResidualText()
        for call in calls { try refuseUndeclaredHarmonyCall(call) }
        guard returnsUnparsedGLMOutputAsText, calls.isEmpty, let residual else { return (calls, residual) }
        if cutAtLimit {
            guard let kept = GLM5ToolSuffix.textAtCut(residual, tools: tools) else {
                glmFramesDroppedAtCut = true
                return ([], nil)
            }
            glmSuffixSplit = true
            glmFramesDroppedAtCut = kept.utf8.count < residual.utf8.count
            return ([], kept)
        }
        switch GLM5ToolSuffix.split(residual, tools: tools, truncated: truncated) {
        case .text(let text, calls: let found):
            glmSuffixSplit = true
            return (found, text)
        case .ambiguous:
            throw MultiModelBatchSchedulerEngineError.generationFailed("native GLM tool output is invalid")
        }
    }

    private var returnsUnparsedGLMOutputAsText: Bool {
        handler?.format == .glm5 && glmUnparsedOutputIsText && autoToolChoice
    }

    /// Inkling 2's pieces: reasoning as on every native channel; answer text
    /// as visible content, refused for a forced choice; each call when its
    /// frame closed, checked before it leaves (streamed) or held to the end.
    private mutating func routeInkling(_ pieces: [Inkling2OutputPiece], cutAtLimit: Bool) throws
        -> [MLXServerGenerationEvent]
    {
        var events: [MLXServerGenerationEvent] = []
        for piece in pieces {
            switch piece {
            case .reasoning(let reasoning):
                guard !reasoning.isEmpty else { continue }
                if withholdReasoning {
                    withheldReasoning += reasoning
                } else {
                    events.append(.parsed(.init(content: "", reasoningContent: reasoning)))
                }
            case .content(let text):
                guard !text.isEmpty else { continue }
                if requiresToolCall {
                    try refuseForcedText(text, cutAtLimit: cutAtLimit)
                    continue
                }
                events.append(visibleEvent(text))
            case .toolCall(let call):
                if let prepared = streamedCallPolicy {
                    events += try routeToolSegment(.call(call), prepared: prepared)
                } else {
                    inklingCalls.append(call)
                }
            }
        }
        return events
    }

    private mutating func route(_ pieces: [ParsedReasoning], cutAtLimit: Bool = false) throws
        -> [MLXServerGenerationEvent]
    {
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
                let unparsed = glmUnparsedFrames
                let segments = glmCalls?.process(piece.content) ?? handler.processChunkSegments(piece.content)
                try refuseUnparsedGLMFrames(since: unparsed, cutAtLimit: cutAtLimit)
                try refuseUnexposedNativeFailure(segments)
                for segment in segments {
                    events += try routeToolSegment(segment, prepared: prepared, cutAtLimit: cutAtLimit)
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
            if let shown = try showHarmonyAnalysis(visible) {
                if !shown.isEmpty { events.append(visibleEvent(shown)) }
                continue
            }
            if requiresToolCall {
                try refuseForcedText(visible, cutAtLimit: cutAtLimit)
                continue
            }
            events.append(visibleEvent(visible))
        }
        return events
    }

    /// A streamed GLM frame never exposed that did not parse (more than
    /// `count` now) fails as the complete-call path's parse failure does,
    /// before its text is routed: forced, with that path's
    /// `toolChoiceViolation` (`native_output`); `auto` with
    /// `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK` off, with its `generationFailed`.
    /// Otherwise an `auto` frame is text. At a cut, the cut decides.
    private func refuseUnparsedGLMFrames(since count: Int, cutAtLimit: Bool) throws {
        guard !cutAtLimit, glmUnparsedFrames > count else { return }
        let message = "native GLM tool output is invalid"
        if requiresToolCall { throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(message) }
        if !glmUnparsedOutputIsText { throw MultiModelBatchSchedulerEngineError.generationFailed(message) }
    }

    /// A forced GPT-OSS answer's text, streamed calls or complete: its
    /// analysis messages, which the stream's Harmony parser turns into
    /// reasoning, are shown; any other text is refused. Nil for every other
    /// request.
    private mutating func showHarmonyAnalysis(_ text: String) throws -> String? {
        guard var analysis = harmonyAnalysis else { return nil }
        guard let shown = analysis.filter(text) else {
            throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                "forced tool_choice produced visible text before a validated call")
        }
        harmonyAnalysis = analysis
        return shown
    }

    /// A forced answer is calls only, streamed or complete. Framing
    /// whitespace around and between call frames is not an answer on any
    /// path, including legacy Qwen text without native channels. Neither is
    /// the unfinished frame a cut flushes. Any other text is refused.
    private func refuseForcedText(_ text: String, cutAtLimit: Bool) throws {
        if cutAtLimit || ToolChoiceEnforcementPolicy.isFramingWhitespace(text) { return }
        throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
            "forced tool_choice produced visible text before a validated call")
    }

    /// Streamed calls are `auto`, the forced calls of Gemma 4, Qwen 3.5–3.8,
    /// GPT-OSS, MiMo V2.6, Nemotron 3.5 and Bonsai 2, and GLM's `auto` and
    /// forced calls, to a client that streams (`ToolStreamPreparation`).
    /// Each is validated (declared name, schema, cardinality) as soon as that
    /// is decidable: the cardinality at its first fragment, the arguments
    /// when its frame closes. For `auto` without `strict`, or once the
    /// response started (`StrictToolCallPolicy`), only the cardinality is
    /// (`returnsAutoCallsAsGenerated(afterResponseStarted:)`); a forced call
    /// is always checked in full.
    private mutating func routeToolSegment(
        _ segment: ToolCallStreamSegment, prepared: ToolChoicePromptPolicy.Prepared, truncated: Bool = false,
        cutAtLimit: Bool = false
    ) throws -> [MLXServerGenerationEvent] {
        if laterCalls.drops(segment, exposedCalls: exposedCallCount, prepared: prepared) { return [] }
        if case .call(let call) = segment { try refuseUndeclaredHarmonyCall(call) }
        switch segment {
        case .text(let text):
            // What a cut's flush releases is the unfinished frame, dropped
            // below (`refuseForcedText`), never a message to show.
            if !cutAtLimit, !text.isEmpty, let shown = try showHarmonyAnalysis(text) {
                return shown.isEmpty ? [] : [visibleEvent(shown)]
            }
            if requiresToolCall {
                try refuseForcedText(text, cutAtLimit: cutAtLimit)
                return []
            }
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
            try validate(call, prepared: prepared, truncated: truncated)
            completedToolCalls.append(call)
            return [.toolCallDelta(.init(index: index, arguments: remainder, completed: call))]
        case .callFailed(let failure):
            defer { openCallIndex = nil }
            // Only the part already sent left, so this is never a finished
            // call (`FailedStreamedCallPolicy`): refused with its check.
            guard !refusesFailedStreamedCalls,
                prepared.returnsAutoCallsAsGenerated(afterResponseStarted: responseStarted),
                let index = openCallIndex, let name = openCallName
            else {
                throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                    ToolNoncomplianceCheck.streamedCallViolation(failure))
            }
            if !prepared.returnsAutoCallsAsGenerated { strictCallsReturnedAsGenerated += 1 }
            callsClosedUnparsed += 1
            // Switched off: the arguments already left as generated (OpenAI's
            // raw `arguments` string for JSON that does not parse). Only close
            // the call, so the response finishes with `tool_calls`; the closing
            // call's empty arguments are never sent, and a call that did not
            // parse is not one of `completedToolCalls`.
            return [.toolCallDelta(.init(index: index,
                completed: ToolCall(function: .init(name: name, arguments: [String: MLXLMCommon.JSONValue]()))))]
        case .call(let call):
            // Never exposed (e.g. an undeclared name): validate before showing.
            try validate(call, prepared: prepared, truncated: truncated)
            let index = try admitCall(prepared)
            completedToolCalls.append(call)
            let arguments = String(
                decoding: try JSONEncoder.openAIServer.encode(call.function.arguments), as: UTF8.self)
            return [.toolCallDelta(.init(index: index, name: call.function.name, arguments: arguments,
                completed: call))]
        }
    }

    /// One call's check; counts a `strict` call that fails it but leaves as
    /// generated because the response started, and any call returned as
    /// generated that breaks the request's declaration.
    private mutating func validate(_ call: ToolCall, prepared: ToolChoicePromptPolicy.Prepared, truncated: Bool)
        throws
    {
        try ToolConstraintValidation.validate([call], prepared: prepared, truncated: truncated,
            responseStarted: responseStarted)
        if responseStarted, prepared.strictCallsAsGenerated, !prepared.returnsAutoCallsAsGenerated,
            (try? ToolConstraintValidation.validate([call], prepared: prepared, truncated: truncated)) == nil
        {
            strictCallsReturnedAsGenerated += 1
        }
        callsBreakingDeclaration += ToolConstraintValidation.countBreakingDeclaration([call], prepared: prepared,
            responseStarted: responseStarted)
    }

    /// A GPT-OSS `auto` call to a function the request did not declare is
    /// refused as a `strict` request refuses it (`undeclared_name`, 422 model
    /// noncompliance), with or without `strict` and before or after the
    /// response started: no declared function can stand in for it, and its
    /// frame is not an answer. Reached only where the grammar did not prevent
    /// it (a cluster pair, a native-tracked engine, a declined request). With
    /// `DARKBLOOM_HARMONY_AUTO_TOOL_GRAMMAR` off, calls leave as generated.
    private func refuseUndeclaredHarmonyCall(_ call: ToolCall) throws {
        guard let prepared = harmonyAutoChoice, !prepared.allowedToolNames.contains(call.function.name) else { return }
        throw MultiModelBatchSchedulerEngineError.toolChoiceViolation(ToolNoncomplianceCheck.undeclaredNameViolation)
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
