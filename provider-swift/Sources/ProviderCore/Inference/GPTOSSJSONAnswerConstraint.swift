// Copyright © 2026 Eigen Labs.
//
// JSON `response_format` answers on GPT-OSS (Harmony). The model reasons in its
// analysis channel as it does unconstrained. After that message the sampler
// admits only the plain answer header, then one JSON value of the request's
// format (a `JSONAnswerConstraint` in its answer phase), then `<|return|>`.

import Foundation
import MLXLMCommon

extension JSONAnswerProfile {
    /// Harmony control spellings. None may appear as text in a constrained
    /// answer: the stream's Harmony parser reads them as framing.
    static let gptOSSAnswerMarkers = [
        "<|start|>", "<|end|>", "<|message|>", "<|channel|>", "<|constrain|>", "<|return|>", "<|call|>",
        "<|endoftext|>", "<|startoftext|>", "<|endofprompt|>",
    ]

    /// GPT-OSS answers (`gpt_oss`, o200k Harmony): byte-level BPE below
    /// `<|startoftext|>`, Harmony control tokens above it and never pieces. The
    /// answer ends with `<|return|>`. The model's vocabulary pads the
    /// tokenizer's 200,019 ids to 201,088.
    static let gptOSSAnswer = JSONAnswerProfile(
        family: "GPT-OSS answer",
        thinkClose: "<|end|>",
        reasoningStops: gptOSSAnswerMarkers,
        contentMarkers: gptOSSAnswerMarkers,
        firstAddedTokenID: 199998,
        pieceTokens: [],
        answerEOS: [.init(spelling: "<|return|>", id: 200002)],
        vocabularySize: 201088)
}

/// The Harmony control token and exact header sequences of a constrained
/// answer, resolved from the loaded tokenizer and checked by round trip.
struct GPTOSSAnswerFraming: Sendable {
    /// Where the rendered prompt leaves the model: a new assistant message.
    static let promptBoundary = "<|start|>assistant"
    static let analysisHeaderText = "<|channel|>analysis<|message|>"
    static let answerHeaderText = "<|start|>assistant<|channel|>final<|message|>"

    let end: Int
    let analysisHeader: [Int]
    let answerHeader: [Int]

    init(tokenizer: any MLXLMCommon.Tokenizer, firstAddedTokenID: Int) throws {
        func control(_ spelling: String) throws -> Int {
            guard let id = tokenizer.convertTokenToId(spelling), id >= firstAddedTokenID,
                  tokenizer.convertIdToToken(id) == spelling,
                  tokenizer.encode(text: spelling, addSpecialTokens: false) == [id],
                  tokenizer.decode(tokenIds: [id], skipSpecialTokens: false) == spelling else {
                throw ToolConstraintSchemaError.invalid("GPT-OSS vocabulary does not match the Harmony control tokens")
            }
            return id
        }
        let start = try control("<|start|>"), channel = try control("<|channel|>"), message = try control("<|message|>")
        end = try control("<|end|>")
        func header(_ text: String, opener: Int, controls: Set<Int>) throws -> [Int] {
            let tokens = tokenizer.encode(text: text, addSpecialTokens: false)
            guard tokens.first == opener, tokens.last == message, tokens.filter({ $0 == message }).count == 1,
                  tokens.allSatisfy({ $0 < firstAddedTokenID || controls.contains($0) }),
                  tokenizer.decode(tokenIds: tokens, skipSpecialTokens: false) == text else {
                throw ToolConstraintSchemaError.invalid("GPT-OSS tokenizer does not encode the Harmony headers exactly")
            }
            return tokens
        }
        analysisHeader = try header(Self.analysisHeaderText, opener: channel, controls: [channel, message])
        answerHeader = try header(Self.answerHeaderText, opener: start, controls: [start, channel, message])
    }
}

/// Token automaton of one constrained GPT-OSS answer:
/// `<|channel|>analysis<|message|>` reasoning `<|end|>`, then
/// `<|start|>assistant<|channel|>final<|message|>`, one JSON value and
/// `<|return|>`. Reasoning is free text that never spells a Harmony control
/// token; within the output kept back for the answer (`analysisReserve`) the
/// analysis must end. The value is delegated to a `JSONAnswerConstraint`,
/// which admits `<|return|>` only once it is complete. An answer cut by the
/// budget is never completed or repaired.
final class GPTOSSJSONAnswerConstraint: CBv2TokenConstraint, @unchecked Sendable {
    /// Answer budget kept back while the model reasons.
    static let answerAllowance = 256
    static let maximumStates = 16_384

    private enum Phase: Hashable {
        case analysisHeader(Int)
        case analysis(window: [UInt8])
        case answerHeader(Int)
        case answer(state: Int)
    }

    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    /// Output kept back for `<|end|>`, the answer header, the answer allowance
    /// and `<|return|>`.
    let analysisReserve: Int
    let format: JSONAnswerFormat
    private let framing: GPTOSSAnswerFraming
    private let vocabulary: JSONAnswerVocabulary
    private let markers: [[UInt8]]
    private let answer: JSONAnswerConstraint
    private let lock = NSLock()
    private var phases: [Phase] = [.analysisHeader(0)]
    private var phaseIndex: [Phase: Int] = [.analysisHeader(0): 0]
    private var analysisMasks: [(rejected: Set<Int>, tokens: [Int])] = []
    private static let maximumMaskEntries = 4

    init(format: JSONAnswerFormat, tokenizer: any MLXLMCommon.Tokenizer, vocabulary: JSONAnswerVocabulary,
         profile: JSONAnswerProfile = .gptOSSAnswer, maxTokens: Int) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS JSON answers require a positive output budget")
        }
        framing = try GPTOSSAnswerFraming(tokenizer: tokenizer, firstAddedTokenID: profile.firstAddedTokenID)
        guard !vocabulary.stopTokenIDs.contains(framing.end) else {
            throw ToolConstraintSchemaError.invalid("GPT-OSS analysis must not end the request")
        }
        answer = try JSONAnswerConstraint(format: format, profile: profile, vocabulary: vocabulary,
            initialPhase: .answer, maxTokens: maxTokens)
        self.format = format
        self.vocabulary = vocabulary
        self.maxTokens = maxTokens
        markers = profile.contentMarkers
        fallbackTokenID = vocabulary.fallbackTokenID
        analysisReserve = 1 + framing.answerHeader.count + Self.answerAllowance + 1
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return [] }
        switch phases[state] {
        case .analysisHeader(let position):
            return [framing.analysisHeader[position]]
        case .analysis(let window):
            return remainingTokens <= analysisReserve ? [framing.end] : analysisTokens(window)
        case .answerHeader(let position):
            return [framing.answerHeader[position]]
        case .answer(let inner):
            return answer.allowedTokenIDs(state: inner, remainingTokens: remainingTokens)
        }
    }

    /// The allowed set depends on the budget only through `remainingTokens > 0`
    /// and, while reasoning, whether the answer's reserve has been reached.
    /// Interned state ids are never reused.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, phases.indices.contains(state) else { return nil }
        if case .analysis = phases[state], remainingTokens <= analysisReserve { return -1 }
        return state
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
            guard tokenID == framing.analysisHeader[position] else { return nil }
            next = position + 1 < framing.analysisHeader.count ? .analysisHeader(position + 1) : .analysis(window: [])
        case .analysis(let window):
            if tokenID == framing.end {
                next = .answerHeader(0)
            } else {
                guard vocabulary.pieces.indices.contains(tokenID), !vocabulary.stopTokenIDs.contains(tokenID),
                      !vocabulary.pieces[tokenID].isEmpty,
                      let advanced = advance(window, vocabulary.pieces[tokenID]) else { return nil }
                next = .analysis(window: advanced)
            }
        case .answerHeader(let position):
            guard tokenID == framing.answerHeader[position] else { return nil }
            next = position + 1 < framing.answerHeader.count
                ? .answerHeader(position + 1) : .answer(state: answer.initialState)
        case .answer(let inner):
            guard let advanced = answer.nextState(state: inner, tokenID: tokenID) else { return nil }
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
        if let index = analysisMasks.firstIndex(where: { $0.rejected == rejected }) {
            let mask = analysisMasks.remove(at: index)
            analysisMasks.append(mask)
            return mask.tokens
        }
        var tokens = rejected.isEmpty ? vocabulary.pieceTokenIDs
            : vocabulary.pieceTokenIDs.filter { !rejected.contains($0) }
        tokens.insert(framing.end, at: tokens.firstIndex { $0 > framing.end } ?? tokens.endIndex)
        if analysisMasks.count == Self.maximumMaskEntries { analysisMasks.removeFirst() }
        analysisMasks.append((rejected, tokens))
        return tokens
    }

    /// The longest suffix of `window + piece` that still starts a marker, or
    /// nil when the piece completes one.
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
