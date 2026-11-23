// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// No tool-call close without an open call on Gemma 4 `auto` tool rows.
///
/// Gemma 4 sometimes ends a tool-calling answer after four tokens: it opens a
/// thought (`<|channel>thought`), writes the call close `<tool_call|>` with no
/// `<|tool_call>` before it, then `<|tool_response>`, which is one of its end
/// tokens. The client gets no call and no text. Under this guard the sampler
/// never draws `<tool_call|>` while no call is open (nor a second one right
/// after a close), so the model takes its next choice instead: more thought,
/// the thought's close, or a real call. `strict` also refuses
/// `<|tool_response>` everywhere but right after a call closes, the only place
/// the template expects it. Every other token stays allowed in every position,
/// so an answer that never draws those tokens is unchanged.
///
/// It applies to Gemma 4 text rows (`gemma4`, `gemma4_text`) on one Mac that
/// runs token constraints, with declared tools and `tool_choice` `auto`, no
/// media and no presence or frequency penalty. A forced call keeps its grammar,
/// which admits a close only after a call; every other row is not touched.
///
/// `DARKBLOOM_GEMMA_ORPHAN_CALL_GUARD`: `on` refuses the orphan close, `strict`
/// also the misplaced `<|tool_response>`; unset or any other value is off.
/// Read once per process.
enum GemmaOrphanCallGuard {
    enum Mode: String, Equatable, Sendable {
        case off, on, strict
    }

    static let environmentKey = "DARKBLOOM_GEMMA_ORPHAN_CALL_GUARD"
    static let mode = mode(ProcessInfo.processInfo.environment[environmentKey])

    static func mode(_ raw: String?) -> Mode {
        switch raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "1", "true", "yes": .on
        case "strict": .strict
        default: .off
        }
    }

    static let modelTypes: Set<String> = ["gemma4", "gemma4_text"]

    /// The call frame's markers and the tool response's opener, pinned by id
    /// and checked against the tokenizer before a guard is built.
    static let callOpen = JSONAnswerProfile.PinnedToken(spelling: "<|tool_call>", id: 48)
    static let callClose = JSONAnswerProfile.PinnedToken(spelling: "<tool_call|>", id: 49)
    static let toolResponse = JSONAnswerProfile.PinnedToken(spelling: "<|tool_response>", id: 50)
    static let vocabularySize = JSONAnswerProfile.gemma4.vocabularySize

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "gemma-orphan-call-guard")

    /// Cheap pre-check: a Gemma 4 text row with declared tools and `auto`.
    static func isCandidate(prepared: ToolChoicePromptPolicy.Prepared, modelType: String?,
                            mode: Mode = mode) -> Bool {
        guard mode != .off, prepared.mode == .auto, prepared.tools?.isEmpty == false,
              let type = modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return modelTypes.contains(type)
    }

    /// The guard for an eligible request, or nil (served as before).
    /// `runsTokenConstraints`: the slot's engine samples under one (not a
    /// cluster pair, not a native-tracked engine). `maxTokens`: the engine
    /// request's budget.
    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        modelType: String?,
        maxTokens: Int,
        stopTokenIDs: Set<Int>,
        runsTokenConstraints: Bool,
        logitsWidth: Int?,
        mode: Mode = mode
    ) -> GemmaOrphanCallGuardConstraint? {
        guard isCandidate(prepared: prepared, modelType: modelType, mode: mode) else { return nil }
        guard runsTokenConstraints else { return declined("the engine does not run token constraints") }
        guard !MediaIngest.hasMedia(request) else { return declined("media request") }
        // A constrained row with a penalty does not draft; leave those rows as they are.
        guard (request.presencePenalty ?? 0) == 0, (request.frequencyPenalty ?? 0) == 0 else {
            return declined("presence or frequency penalty")
        }
        guard logitsWidth == nil || logitsWidth == vocabularySize,
              matchesPinnedVocabulary(tokenizer.inner) else {
            return declined("tokenizer does not match the pinned vocabulary")
        }
        return try? GemmaOrphanCallGuardConstraint(
            guardMode: mode, vocabularySize: vocabularySize, stopTokenIDs: stopTokenIDs, maxTokens: maxTokens)
    }

    static func matchesPinnedVocabulary(_ tokenizer: any MLXLMCommon.Tokenizer) -> Bool {
        for token in [callOpen, callClose, toolResponse] {
            guard tokenizer.convertTokenToId(token.spelling) == token.id,
                  tokenizer.convertIdToToken(token.id) == token.spelling else { return false }
        }
        return tokenizer.convertIdToToken(vocabularySize - 1) != nil
            && tokenizer.convertIdToToken(vocabularySize) == nil
    }

    private static func declined(_ reason: StaticString) -> GemmaOrphanCallGuardConstraint? {
        logger.info("Gemma orphan call guard not applied: \(reason)")
        return nil
    }
}

/// The token constraint of `GemmaOrphanCallGuard`: three states (no call open,
/// a call open, a call just closed), each the whole vocabulary less at most
/// two tokens, so at most four masks, uploaded once per process and keyed by
/// what they refuse.
final class GemmaOrphanCallGuardConstraint: CBv2FreeSpanTokenConstraint, @unchecked Sendable {
    static let idle = 0, open = 1, closed = 2

    let mode: CBv2TokenConstraintMode = .auto
    let maxTokens: Int
    let initialState: Int
    let fallbackTokenID: Int
    let guardMode: GemmaOrphanCallGuard.Mode
    let vocabularySize: Int
    let stopTokenIDs: Set<Int>
    private let callOpen = GemmaOrphanCallGuard.callOpen.id
    private let callClose = GemmaOrphanCallGuard.callClose.id
    private let toolResponse = GemmaOrphanCallGuard.toolResponse.id

    init(guardMode: GemmaOrphanCallGuard.Mode, vocabularySize: Int, stopTokenIDs: Set<Int>, maxTokens: Int,
         initialState: Int = GemmaOrphanCallGuardConstraint.idle) throws {
        guard guardMode != .off else {
            throw ToolConstraintSchemaError.invalid("the Gemma orphan call guard is off")
        }
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("the Gemma orphan call guard requires a positive output budget")
        }
        guard let fallback = stopTokenIDs.filter({ (0..<vocabularySize).contains($0) }).min() else {
            throw ToolConstraintSchemaError.invalid("constrained decoding requires at least one stop token")
        }
        guard (Self.idle...Self.closed).contains(initialState) else {
            throw ToolConstraintSchemaError.invalid("unknown Gemma orphan call guard state")
        }
        self.guardMode = guardMode
        self.vocabularySize = vocabularySize
        self.stopTokenIDs = stopTokenIDs
        self.maxTokens = maxTokens
        self.initialState = initialState
        fallbackTokenID = fallback
    }

    /// The tokens a state refuses, sorted.
    func refused(state: Int) -> [Int] {
        switch (state, guardMode) {
        case (Self.idle, .strict): [callClose, toolResponse]
        case (Self.open, .strict): [toolResponse]
        case (Self.idle, _), (Self.closed, _): [callClose]
        default: []
        }
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        guard remainingTokens > 0, (Self.idle...Self.closed).contains(state) else { return [] }
        return Self.mask(vocabularySize: vocabularySize, refusing: refused(state: state))
    }

    /// One key per refused set, independent of the positive budget.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        guard remainingTokens > 0, (Self.idle...Self.closed).contains(state) else { return nil }
        let tokens = refused(state: state)
        if tokens.isEmpty { return 0 }
        if tokens == [callClose] { return 1 }
        if tokens == [toolResponse] { return 2 }
        return 3
    }

    /// `allowedTokenIDs` has no effect beyond its result, and the state is
    /// derived from confirmed tokens alone.
    var allowsChainedDecode: Bool { true }

    func nextState(state: Int, tokenID: Int) -> Int? {
        guard (Self.idle...Self.closed).contains(state), (0..<vocabularySize).contains(tokenID),
              !refused(state: state).contains(tokenID) else { return nil }
        if stopTokenIDs.contains(tokenID) { return -1 }
        switch tokenID {
        case callOpen: return Self.open
        case callClose: return Self.closed
        default: return state == Self.open ? Self.open : Self.idle
        }
    }

    /// Text inside or outside a call: every token but the markers and the
    /// stops keeps the state. Right after a close every token moves it.
    func isFreeSpan(state: Int) -> Bool { state == Self.idle || state == Self.open }

    func isFreeSpanContinuation(state: Int, tokenID: Int) -> Bool {
        isFreeSpan(state: state) && (0..<vocabularySize).contains(tokenID) && !stopTokenIDs.contains(tokenID)
            && tokenID != callOpen && tokenID != callClose && tokenID != toolResponse
    }

    /// The same guard for a continuation of this row (the loop guard's
    /// exit-thinking continuation): its state after `output`, the row's
    /// generated tokens and the exit, with the continuation's budget. Nil when
    /// `output` is not a sequence this guard admits.
    func continuing(after output: [Int], maxTokens: Int) -> GemmaOrphanCallGuardConstraint? {
        var state = initialState
        for token in output {
            guard let next = nextState(state: state, tokenID: token), next >= 0 else { return nil }
            state = next
        }
        return try? GemmaOrphanCallGuardConstraint(guardMode: guardMode, vocabularySize: vocabularySize,
                                                   stopTokenIDs: stopTokenIDs, maxTokens: maxTokens,
                                                   initialState: state)
    }

    private struct MaskKey: Hashable {
        let vocabularySize: Int
        let refused: [Int]
    }

    private static let maskLock = NSLock()
    nonisolated(unsafe) private static var masks: [MaskKey: [Int]] = [:]

    /// The vocabulary less `refused`, built once per process per set.
    static func mask(vocabularySize: Int, refusing refused: [Int]) -> [Int] {
        let key = MaskKey(vocabularySize: vocabularySize, refused: refused)
        maskLock.lock(); defer { maskLock.unlock() }
        if let mask = masks[key] { return mask }
        let excluded = Set(refused)
        let mask = (0..<vocabularySize).filter { !excluded.contains($0) }
        masks[key] = mask
        return mask
    }
}
