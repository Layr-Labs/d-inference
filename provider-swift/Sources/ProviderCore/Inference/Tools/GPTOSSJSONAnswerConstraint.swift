// Copyright © 2026 Eigen Labs.
//
// GPT-OSS (Harmony) answers to a JSON `response_format`: the model reasons in
// its analysis channel as without the grammar; after that message the sampler
// admits only the final message's header, then one JSON value of the request's
// format (`JSONAnswerFormat`, widened as Qwen's answers are) and `<|return|>`.

import Foundation
import MLXLMCommon
import MLXLMServer

/// The process switch and the admission of GPT-OSS JSON answers to
/// `GPTOSSJSONAnswerConstraint`.
enum GPTOSSJSONAnswers {
    /// An off word (`off`, `false`, `0`, `none`, `no` or `disabled`, any case,
    /// surrounding space ignored) restores prompt-only JSON answers. Read once
    /// at launch. Not `DARKBLOOM_GPTOSS_`: that prefix is part of the SSD
    /// prefix cache's checkpoint identity.
    static let environmentKey = "DARKBLOOM_HARMONY_JSON_ANSWERS"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    private static let logger = ProviderLogger(
        subsystem: BuildEnvironment.current.serviceLogSubsystem, category: "harmony-json-answer")

    static func isEnabled(_ value: String?) -> Bool {
        GPTOSSForcedToolCalls.isEnabled(value)
    }

    /// Cheap pre-check: a tool-free GPT-OSS request whose `response_format`
    /// asks for JSON, split by the Harmony reasoning parser (which, with
    /// `HarmonyFinalHeaderFilter`, reads both final headers as the answer).
    static func isCandidate(request: OpenAIChatCompletionRequest, modelType: String?,
                            enabled: Bool = enabled) -> Bool {
        enabled && modelType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == GPTOSSForcedToolCalls.modelType
            && request.reasoningParser == .harmony
            && request.responseFormat?.requiresJSONOutput == true
            && (request.tools?.isEmpty ?? true) && request.toolChoice == nil && !MediaIngest.hasMedia(request)
    }

    /// The constraint for an eligible request, or nil: the answer keeps
    /// prompt-only steering, as before. `runsTokenConstraints`: the slot's
    /// engine samples under one (not a cluster pair, not a native-tracked
    /// engine).
    static func constraint(
        request: OpenAIChatCompletionRequest,
        modelType: String?,
        tokenizer: TokenizerHandle,
        maxTokens: Int,
        stopTokenIDs: Set<Int>,
        promptTokens: [Int]?,
        runsTokenConstraints: Bool,
        enabled: Bool = enabled
    ) -> GPTOSSJSONAnswerConstraint? {
        guard isCandidate(request: request, modelType: modelType, enabled: enabled),
              let format = request.responseFormat else { return nil }
        guard runsTokenConstraints else { return declined("the engine does not run token constraints") }
        guard let promptTokens, !promptTokens.isEmpty,
              tokenizer.inner.decode(tokenIds: Array(promptTokens.suffix(32)), skipSpecialTokens: false)
                  .hasSuffix(GPTOSSHarmonyFraming.promptBoundary) else {
            return declined("unrecognized prompt boundary")
        }
        let profile = JSONAnswerProfile.gptOSSFinal
        guard case let (answer, widening)? = QwenJSONSchemaRewrite.answerFormat(format, profile: profile,
                  widens: true) else {
            return declined("schema outside the constrained subset")
        }
        let vocabulary: JSONAnswerVocabulary
        do {
            vocabulary = try JSONAnswerVocabulary.cached(for: tokenizer, profile: profile, stopTokenIDs: stopTokenIDs)
        } catch {
            return declined("tokenizer does not match the Harmony contract")
        }
        guard let constraint = try? GPTOSSJSONAnswerConstraint(format: answer, tokenizer: tokenizer.inner,
                  vocabulary: vocabulary, maxTokens: maxTokens) else {
            return declined("tokenizer or budget does not fit the Harmony answer framing")
        }
        if let widening { logger.info("GPT-OSS json_schema outside the constrained subset: \(widening.note)") }
        return constraint
    }

    /// Fixed reasons only: never schemas, prompt content or token IDs.
    private static func declined(_ reason: StaticString) -> GPTOSSJSONAnswerConstraint? {
        logger.info("GPT-OSS JSON response_format served prompt-only: \(reason)")
        return nil
    }
}

/// Token automaton of one GPT-OSS JSON answer:
/// `<|channel|>analysis<|message|>` reasoning `<|end|>`, then a final header
/// (`<|start|>assistant<|channel|>final<|message|>`, or the
/// `final <|constrain|>json<|message|>` GPT-OSS writes for JSON answers, which
/// the stream's `HarmonyFinalHeaderFilter` reads as `final`), one JSON value of
/// the request's format and `<|return|>`. Reasoning is free text that never
/// spells a Harmony control token; it must end within the output kept back for
/// the answer (`analysisReserve`) and once `analysisCap` tokens are out, as a
/// forced call's does (`GPTOSSForcedToolConstraint`). The answer is delegated
/// to a `JSONAnswerConstraint`, which admits `<|return|>` only once the value
/// is complete. An answer cut by the budget is never completed or repaired.
/// Nothing is checked after generation: the stream's Harmony parser splits the
/// answer from the reasoning downstream, and the grammar already holds it.
final class GPTOSSJSONAnswerConstraint: CBv2TokenConstraint, @unchecked Sendable {
    /// Answer budget kept back while the model reasons: half the output,
    /// between `minimumAnswerAllowance` and `maximumAnswerAllowance` tokens. An
    /// extraction or classification answer takes 50–250 tokens, so a smaller
    /// share cuts many of them at a small `max_tokens`; the reasoning ends
    /// earlier in exchange.
    static let minimumAnswerAllowance = 64
    static let maximumAnswerAllowance = 256
    static let analysisCap = GPTOSSForcedToolConstraint.analysisCap
    static let finalHeaderTexts = [
        "<|start|>assistant<|channel|>final<|message|>",
        "<|start|>assistant<|channel|>final <|constrain|>json<|message|>",
    ]

    static func answerAllowance(maxTokens: Int) -> Int {
        min(maximumAnswerAllowance, max(minimumAnswerAllowance, maxTokens / 2))
    }
    /// The answer's delegate interns at most its own maximum; the analysis
    /// windows and header positions add a few hundred more.
    static let maximumStates = 2 * JSONAnswerConstraint.maximumStates
    private static let maximumTokenSets = 4

    private enum Phase: Hashable {
        case analysisHeader(Int)
        /// The suffix of the reasoning that still starts a Harmony spelling.
        case analysis(window: [UInt8])
        case finalHeader(node: Int)
        case answer(state: Int)
    }

    private struct HeaderNode {
        var next: [Int: Int] = [:]
        var complete = false
    }

    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    /// Output kept back for `<|end|>`, the longest final header, the answer
    /// allowance and `<|return|>`.
    let analysisReserve: Int
    let format: JSONAnswerFormat
    private let analysisHeader: [Int]
    private let finalHeaderTrie: [HeaderNode]
    private let end: Int
    private let vocabulary: JSONAnswerVocabulary
    private let markers = JSONAnswerProfile.gptOSSFinal.contentMarkers
    private let answerConstraint: JSONAnswerConstraint
    private let lock = NSLock()
    private var phases: [Phase] = [.analysisHeader(0)]
    private var phaseIndex: [Phase: Int] = [.analysisHeader(0): 0]
    private var analysisTokenSets: [(rejected: Set<Int>, tokens: [Int])] = []

    init(format: JSONAnswerFormat, tokenizer: any MLXLMCommon.Tokenizer, vocabulary: JSONAnswerVocabulary,
         maxTokens: Int) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS JSON answers require a positive output budget")
        }
        let profile = JSONAnswerProfile.gptOSSFinal
        let framing = try GPTOSSHarmonyFraming(tokenizer: tokenizer, names: [],
            firstAddedTokenID: profile.bpeIDs.upperBound)
        guard !vocabulary.stopTokenIDs.contains(framing.end) else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS analysis must not end the request")
        }
        let headers = try Self.finalHeaderTexts.map {
            try GPTOSSHarmonyFraming.header($0, tokenizer: tokenizer, opener: framing.start, message: framing.message,
                controls: [framing.start, framing.channel, framing.constrain, framing.message],
                firstAddedTokenID: profile.bpeIDs.upperBound)
        }
        var trie = [HeaderNode()]
        for header in headers {
            var node = 0
            for token in header {
                if let child = trie[node].next[token] {
                    node = child
                } else {
                    trie.append(HeaderNode())
                    trie[node].next[token] = trie.count - 1
                    node = trie.count - 1
                }
            }
            trie[node].complete = true
        }
        answerConstraint = try JSONAnswerConstraint(format: format, profile: profile, vocabulary: vocabulary,
            initialPhase: .answer, maxTokens: maxTokens)
        self.format = format
        analysisHeader = framing.analysisHeader
        finalHeaderTrie = trie
        end = framing.end
        self.vocabulary = vocabulary
        self.maxTokens = maxTokens
        fallbackTokenID = vocabulary.fallbackTokenID
        analysisReserve = 1 + (headers.map(\.count).max() ?? 0) + Self.answerAllowance(maxTokens: maxTokens) + 1
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return [] }
        switch phases[state] {
        case .analysisHeader(let position):
            return [analysisHeader[position]]
        case .analysis(let window):
            return analysisMustEnd(remainingTokens: remainingTokens) ? [end] : analysisTokens(window)
        case .finalHeader(let node):
            return finalHeaderTrie[node].next.keys.sorted()
        case .answer(let inner):
            return answerConstraint.allowedTokenIDs(state: inner, remainingTokens: remainingTokens)
        }
    }

    /// The allowed set depends on the budget only through `remainingTokens > 0`
    /// and, while reasoning, whether the analysis must end. Interned state ids
    /// are never reused.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return nil }
        if case .analysis = phases[state], analysisMustEnd(remainingTokens: remainingTokens) { return -1 }
        return state
    }

    /// Within the answer's reserve, or once `analysisCap` tokens are out.
    private func analysisMustEnd(remainingTokens: Int) -> Bool {
        remainingTokens <= analysisReserve || maxTokens - remainingTokens >= Self.analysisCap
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens.
    var allowsChainedDecode: Bool { true }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard phases.indices.contains(state) else { return nil }
        let next: Phase
        switch phases[state] {
        case .analysisHeader(let position):
            guard tokenID == analysisHeader[position] else { return nil }
            next = position + 1 < analysisHeader.count ? .analysisHeader(position + 1) : .analysis(window: [])
        case .analysis(let window):
            if tokenID == end {
                next = .finalHeader(node: 0)
            } else {
                guard vocabulary.pieces.indices.contains(tokenID), !vocabulary.stopTokenIDs.contains(tokenID),
                      !vocabulary.pieces[tokenID].isEmpty,
                      let advanced = advance(window, vocabulary.pieces[tokenID]) else { return nil }
                next = .analysis(window: advanced)
            }
        case .finalHeader(let node):
            guard let child = finalHeaderTrie[node].next[tokenID] else { return nil }
            next = finalHeaderTrie[child].complete
                ? .answer(state: answerConstraint.initialState) : .finalHeader(node: child)
        case .answer(let inner):
            guard let advanced = answerConstraint.nextState(state: inner, tokenID: tokenID) else { return nil }
            if advanced == -1 { return -1 }
            next = .answer(state: advanced)
        }
        if let known = phaseIndex[next] { return known }
        guard phases.count < Self.maximumStates else { return nil }
        phases.append(next)
        phaseIndex[next] = phases.count - 1
        return phases.count - 1
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return phases.count }

    /// Reasoning pieces: every piece except one that would complete a Harmony
    /// spelling (only pieces holding a marker's final byte can), and `<|end|>`.
    private func analysisTokens(_ window: [UInt8]) -> [Int] {
        let rejected = Set(vocabulary.reasoningSensitive.filter { advance(window, vocabulary.pieces[$0]) == nil })
        if let index = analysisTokenSets.firstIndex(where: { $0.rejected == rejected }) {
            let entry = analysisTokenSets.remove(at: index)
            analysisTokenSets.append(entry)
            return entry.tokens
        }
        var tokens = rejected.isEmpty ? vocabulary.pieceTokenIDs
            : vocabulary.pieceTokenIDs.filter { !rejected.contains($0) }
        tokens.insert(end, at: tokens.firstIndex { $0 > end } ?? tokens.endIndex)
        if analysisTokenSets.count == Self.maximumTokenSets { analysisTokenSets.removeFirst() }
        analysisTokenSets.append((rejected, tokens))
        return tokens
    }

    /// The longest suffix of `window + piece` that still starts a Harmony
    /// spelling, or nil when the piece completes one.
    private func advance(_ window: [UInt8], _ piece: [UInt8]) -> [UInt8]? {
        var window = window
        for byte in piece {
            window.append(byte)
            while !window.isEmpty && !markers.contains(where: { $0.starts(with: window) }) {
                window.removeFirst()
            }
            if markers.contains(where: { $0.count <= window.count && window.suffix($0.count).elementsEqual($0) }) {
                return nil
            }
        }
        return window
    }
}
