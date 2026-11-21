// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer

/// No end of turn inside a Qwen 3.5–3.8 call frame.
///
/// The model sometimes ends its turn inside a call: on long forced writes it
/// stops right after the last line of a string value, before `</parameter>`,
/// `</function>` and `</tool_call>`. The provider then refuses the call as
/// `unterminated` after its arguments already streamed. Under this guard the
/// sampler admits no end of turn (no stop token) once a frame's
/// `<function=` has been written and until its `</tool_call>`, so the model
/// writes the rest of the value and the closing framing itself. Ordinary text
/// tokens and the reasoning and call markers stay allowed in every position
/// (other special tokens are not, as under the `strict` grammar), and text,
/// reasoning and the arguments are never held to a schema. A frame the
/// parser would not read (the JSON dialect, text between the tags) is not
/// guarded, nor is a value that writes `</tool_call>` before its
/// `</parameter>`. The token limit still ends the answer as `length`.
///
/// It applies to Qwen 3.5-family builds (`qwen3_5`, `qwen3_5_moe`) on one Mac
/// that runs token constraints, to text requests whose `tool_choice` is
/// `required` or a named function, where an unfinished call fails the request.
/// A constrained row gives up MTP drafting (about 8 % of single-request decode
/// on Qwen 3.6), so `auto` requests are left as they are. A request it
/// declines is served as before.
///
/// `DARKBLOOM_QWEN_CALL_END_GUARD`: unset or any other value keeps it on; `0`,
/// `off`, `false` or `no` turns it off. Read once per process.
enum QwenCallEndGuard {
    static let environmentKey = "DARKBLOOM_QWEN_CALL_END_GUARD"
    static let enabled = !ToolOutputLeniencySwitch.isOff(ProcessInfo.processInfo.environment[environmentKey])

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "qwen-call-end-guard")

    /// Cheap pre-check before the engine is asked whether it runs constraints:
    /// a forced call on the Qwen 3.5 call parser.
    static func isCandidate(prepared: ToolChoicePromptPolicy.Prepared, parser: ToolCallFormat?, modelType: String?,
                            enabled: Bool = enabled) -> Bool {
        guard enabled, parser == .qwen35, prepared.requiresToolCall, prepared.tools?.isEmpty == false,
              let type = modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return QwenStrictToolGrammar.modelTypes.contains(type)
    }

    /// The guard for an eligible request, or nil (served as before).
    /// `runsTokenConstraints`: the slot's engine samples under one (not a
    /// cluster pair, not a native-tracked engine).
    static func constraint(
        prepared: ToolChoicePromptPolicy.Prepared,
        request: OpenAIChatCompletionRequest,
        parser: ToolCallFormat?,
        tokenizer: TokenizerHandle,
        modelType: String?,
        defaultMaxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        runsTokenConstraints: Bool,
        enabled: Bool = enabled
    ) -> QwenCallEndGuardConstraint? {
        guard isCandidate(prepared: prepared, parser: parser, modelType: modelType, enabled: enabled) else { return nil }
        guard runsTokenConstraints else { return declined("the engine does not run token constraints") }
        guard !MediaIngest.hasMedia(request) else { return declined("media request") }
        guard let promptTokens, !promptTokens.isEmpty,
              let prefix = ReasoningPromptProbe.streamingPrefix(forPromptTail: tokenizer.inner.decode(
                  tokenIds: Array(promptTokens.suffix(ReasoningPromptProbe.tailTokenCount)),
                  skipSpecialTokens: false)) else {
            return declined("unrecognized prompt boundary")
        }
        guard let vocabulary = try? JSONAnswerVocabulary.cached(for: tokenizer, profile: QwenStrictToolGrammar.profile,
                                                                 stopTokenIDs: stopTokenIDs) else {
            return declined("tokenizer does not match the pinned vocabulary")
        }
        guard let constraint = try? QwenCallEndGuardConstraint(vocabulary: vocabulary, mode: prepared.mode,
            startsInReasoning: prefix == ReasoningPromptProbe.thinkOpen,
            maxTokens: request.maxTokens ?? defaultMaxTokens) else {
            return declined("no positive output budget")
        }
        return constraint
    }

    /// Fixed reasons only: never names, schemas, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> QwenCallEndGuardConstraint? {
        logger.info("Qwen call end guard not applied: \(reason)")
        return nil
    }
}

/// Where the answer stands against the canonical Qwen XML call frame:
/// `<tool_call>`, whitespace, `<function=NAME>`, then
/// `<parameter=KEY>VALUE</parameter>` entries and `</function>`,
/// `</tool_call>`, separated by whitespace alone. Only the bytes of the
/// marker being matched are kept: every marker starts with `<` and holds no
/// other `<`, so a mismatch restarts at that byte.
struct QwenCallEndBoundary: Hashable {
    enum Step: Int8, Hashable {
        /// Prompt-opened reasoning, until `</think>`.
        case reasoning
        /// Free text, until `<tool_call>`.
        case content
        /// After `<tool_call>`: whitespace, then `<function=`. Another byte is
        /// not a frame the parser reads as XML: free text again.
        case opening
        /// The function name, until `>`.
        case name
        /// Between parameters: whitespace, then `<parameter=` or `</function>`.
        case between
        /// The parameter name, until `>`.
        case key
        /// A value, until `</parameter>`.
        case value
        /// After `</function>`: whitespace, then `</tool_call>`.
        case closing
        /// Free for the rest of the answer: a frame the parser does not read,
        /// or one whose value wrote `</tool_call>` (see `.value`). A later call
        /// in the same answer is not held.
        case released
    }

    static let thinkClose = Array("</think>".utf8)
    static let callOpen = Array("<tool_call>".utf8)
    static let callClose = Array("</tool_call>".utf8)
    static let functionOpen = Array("<function=".utf8)
    static let functionClose = Array("</function>".utf8)
    static let parameterOpen = Array("<parameter=".utf8)
    static let parameterClose = Array("</parameter>".utf8)
    /// The argument streamer's tag limit: a longer name is not a frame it reads.
    static let nameLimit: Int16 = 256

    private(set) var step: Step
    /// Bytes of the marker being matched (`between`: of both, which share `<`).
    private(set) var matched: Int8 = 0
    /// `between` after `<`: 1 for `<parameter=`, 2 for `</function>`, 0
    /// undecided. In a value: bytes of `</tool_call>` matched.
    private(set) var tag: Int8 = 0
    private(set) var nameLength: Int16 = 0

    init(reasoning: Bool) { step = reasoning ? .reasoning : .content }

    /// Inside a frame whose function is named: no end of turn here.
    var holdsTurn: Bool {
        switch step {
        case .name, .between, .key, .value, .closing: true
        case .reasoning, .content, .opening, .released: false
        }
    }

    /// Ordinary text with no marker in progress: a token that keeps this
    /// state is drafted freely.
    var isFreeSpan: Bool {
        switch step {
        case .reasoning, .content: matched == 0
        case .value: matched == 0 && tag == 0
        case .released: true
        case .opening, .name, .between, .key, .closing: false
        }
    }

    mutating func consume(_ byte: UInt8) {
        switch step {
        case .reasoning:
            if watch(byte, Self.thinkClose) { step = .content }
        case .content:
            if watch(byte, Self.callOpen) { step = .opening }
        case .opening:
            if matched == 0, Self.isWhitespace(byte) { return }
            if Self.functionOpen[Int(matched)] == byte {
                matched += 1
                if Int(matched) == Self.functionOpen.count { matched = 0; nameLength = 0; step = .name }
            } else {
                // Not a frame the parser reads as XML: free text again.
                matched = 0
                step = .content
                if watch(byte, Self.callOpen) { step = .opening }
            }
        case .name, .key:
            if byte == UInt8(ascii: ">") {
                guard nameLength > 0 else { return release() }
                nameLength = 0
                step = step == .name ? .between : .value
            } else if Self.isWhitespace(byte) || byte == UInt8(ascii: "<") || nameLength >= Self.nameLimit {
                release()
            } else {
                nameLength += 1
            }
        case .between:
            if matched == 0, Self.isWhitespace(byte) { return }
            if matched == 0 {
                guard byte == UInt8(ascii: "<") else { return release() }
                matched = 1
                return
            }
            if tag == 0 { tag = byte == UInt8(ascii: "p") ? 1 : byte == UInt8(ascii: "/") ? 2 : -1 }
            let marker = tag == 1 ? Self.parameterOpen : Self.functionClose
            guard tag > 0, marker[Int(matched)] == byte else { return release() }
            matched += 1
            if Int(matched) == marker.count {
                matched = 0
                nameLength = 0
                step = tag == 1 ? .key : .closing
                tag = 0
            }
        case .value:
            // `</tool_call>` before `</parameter>` is read as the model closing
            // the call with the parameter left open, and releases the guard: a
            // deliberate trade-off. Holding the turn there would most likely run
            // the row to the token limit. The parser reads that text as part of the
            // value, so a value that legitimately contains it (a document about
            // tool calls) is served as without the guard.
            if watchCallClose(byte) { return release() }
            if watch(byte, Self.parameterClose) { tag = 0; step = .between }
        case .closing:
            if matched == 0, Self.isWhitespace(byte) { return }
            guard Self.callClose[Int(matched)] == byte else { return release() }
            matched += 1
            if Int(matched) == Self.callClose.count { matched = 0; step = .content }
        case .released:
            return
        }
    }

    /// In a value, `tag` follows `</tool_call>` beside `matched`'s `</parameter>`.
    private mutating func watchCallClose(_ byte: UInt8) -> Bool {
        if Self.callClose[Int(tag)] == byte {
            tag += 1
            if Int(tag) == Self.callClose.count { tag = 0; return true }
        } else {
            tag = byte == Self.callClose[0] ? 1 : 0
        }
        return false
    }

    /// Free text watched for `marker`; true (and reset) once it completes.
    private mutating func watch(_ byte: UInt8, _ marker: [UInt8]) -> Bool {
        if marker[Int(matched)] == byte {
            matched += 1
            if Int(matched) == marker.count { matched = 0; return true }
        } else {
            matched = byte == marker[0] ? 1 : 0
        }
        return false
    }

    private mutating func release() {
        step = .released
        matched = 0
        tag = 0
        nameLength = 0
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool { (9...13).contains(byte) || byte == 32 }
}

/// The token constraint of `QwenCallEndGuard`: two masks only, the whole
/// vocabulary with the stop tokens (outside a frame) and without them
/// (inside one). Per-request and host-only; states are interned like
/// `QwenStrictToolConstraint`'s, and should they ever run out the rest of the
/// answer is free, as without the guard.
final class QwenCallEndGuardConstraint: CBv2FreeSpanTokenConstraint, @unchecked Sendable {
    let mode: CBv2TokenConstraintMode
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let startsInReasoning: Bool
    private let vocabulary: JSONAnswerVocabulary
    /// Every piece and every stop: outside a frame.
    private let freeMask: [Int]
    private let lock = NSLock()
    private var states: [QwenCallEndBoundary]
    private var stateIndex: [QwenCallEndBoundary: Int]
    static let maximumStates = 4_096
    /// After resource exhaustion every later token is free.
    static let releasedState = Int.max
    private static let freeMaskKey = 0
    private static let heldMaskKey = 1

    init(vocabulary: JSONAnswerVocabulary, mode: ToolConstraintMode, startsInReasoning: Bool, maxTokens: Int) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("the Qwen call end guard requires a positive output budget")
        }
        self.vocabulary = vocabulary
        self.mode = switch mode {
        case .none: .none
        case .auto: .auto
        case .required: .required
        case .named: .named
        }
        self.startsInReasoning = startsInReasoning
        self.maxTokens = maxTokens
        fallbackTokenID = vocabulary.fallbackTokenID
        let stops = vocabulary.stopTokenIDs.filter { vocabulary.pieces.indices.contains($0) }
        freeMask = (vocabulary.pieceTokenIDs + stops).sorted()
        let initial = QwenCallEndBoundary(reasoning: startsInReasoning)
        states = [initial]
        stateIndex = [initial: 0]
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0 else { return [] }
        if state == Self.releasedState { return freeMask }
        guard states.indices.contains(state) else { return [] }
        return states[state].holdsTurn ? vocabulary.pieceTokenIDs : freeMask
    }

    /// Two masks, independent of the positive budget.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0 else { return nil }
        if state == Self.releasedState { return Self.freeMaskKey }
        guard states.indices.contains(state) else { return nil }
        return states[state].holdsTurn ? Self.heldMaskKey : Self.freeMaskKey
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens.
    var allowsChainedDecode: Bool { true }

    func isFreeSpan(state: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if state == Self.releasedState { return true }
        return states.indices.contains(state) && states[state].isFreeSpan
    }

    /// Preview a copy: discarded proposals must not intern states.
    func isFreeSpanContinuation(state: Int, tokenID: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard vocabulary.pieces.indices.contains(tokenID), !vocabulary.stopTokenIDs.contains(tokenID),
              !vocabulary.pieces[tokenID].isEmpty else { return false }
        if state == Self.releasedState { return true }
        guard states.indices.contains(state), states[state].isFreeSpan else { return false }
        let boundary = states[state]
        return transition(boundary, token: tokenID) == boundary
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard vocabulary.pieces.indices.contains(tokenID) else { return nil }
        if vocabulary.stopTokenIDs.contains(tokenID) {
            if state == Self.releasedState { return -1 }
            guard states.indices.contains(state) else { return nil }
            return states[state].holdsTurn ? nil : -1
        }
        guard !vocabulary.pieces[tokenID].isEmpty else { return nil }
        if state == Self.releasedState { return Self.releasedState }
        guard states.indices.contains(state) else { return nil }
        let next = transition(states[state], token: tokenID)
        if let known = stateIndex[next] { return known }
        guard states.count < Self.maximumStates else { return Self.releasedState }
        states.append(next)
        stateIndex[next] = states.count - 1
        return states.count - 1
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return states.count }

    private func transition(_ boundary: QwenCallEndBoundary, token: Int) -> QwenCallEndBoundary {
        var next = boundary
        for byte in vocabulary.pieces[token] { next.consume(byte) }
        return next
    }
}
