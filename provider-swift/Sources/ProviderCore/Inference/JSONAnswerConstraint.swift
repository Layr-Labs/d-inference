// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Interned parse position of a constrained JSON answer: the phase, the
/// rolling marker window of that phase, and the JSON lexer once answering.
/// No reasoning text or string body is accumulated.
struct JSONAnswerBoundary: Hashable {
    private(set) var phase: JSONAnswerPhase
    private(set) var window: [UInt8] = []
    private(set) var json: FlintJSONState?

    init(phase: JSONAnswerPhase, grammar: FlintJSONGrammar) {
        self.phase = phase
        if phase == .answer { json = FlintJSONState(grammar: grammar) }
    }

    /// Free string bodies admit every piece without a sensitive byte.
    var inStringBody: Bool { json?.inStringBody == true }

    func isComplete(_ grammar: FlintJSONGrammar) -> Bool { json?.isComplete(grammar) == true }

    mutating func consume(_ byte: UInt8, profile: JSONAnswerProfile, grammar: FlintJSONGrammar) -> Bool {
        switch phase {
        case .reasoning:
            guard let marker = Self.advance(&window, with: byte, markers: profile.reasoningMarkers) else {
                return true
            }
            guard marker == profile.thinkClose else { return false }
            phase = .answer
            window = []
            json = FlintJSONState(grammar: grammar)
            return true
        case .answer:
            guard Self.advance(&window, with: byte, markers: profile.contentMarkers) == nil else { return false }
            return json?.consume(byte, grammar: grammar) == true
        }
    }

    /// Keeps the longest window suffix that still starts a marker and returns
    /// a marker this byte completed. Every completed marker is a suffix of
    /// that window, however the output was split into tokens.
    private static func advance(_ window: inout [UInt8], with byte: UInt8, markers: [[UInt8]]) -> [UInt8]? {
        window.append(byte)
        while !window.isEmpty && !markers.contains(where: { $0.starts(with: window) }) {
            window.removeFirst()
        }
        return markers.first { window.count >= $0.count && window.suffix($0.count).elementsEqual($0) }
    }
}

/// Constrains one answer to a single JSON value of a compiled grammar, after
/// reasoning when the prompt opened it (`JSONAnswerProfile`). Reasoning stays
/// free apart from its markers and masked EOS; an answer EOS is allowed only
/// once the value is complete. Per-request and host-only: as in
/// `FlintNativeProtocolConstraint`, interning collapses free text to bounded
/// framing states, and it never forces a value or repairs a truncated one.
final class JSONAnswerConstraint: CBv2TokenConstraint, @unchecked Sendable {
    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let format: JSONAnswerFormat
    let initialPhase: JSONAnswerPhase
    private let profile: JSONAnswerProfile
    private let vocabulary: JSONAnswerVocabulary
    private let lock = NSLock()
    private var states: [JSONAnswerBoundary]
    private var stateIndex: [JSONAnswerBoundary: Int]
    private var allowedCache: [(state: Int, tokens: [Int])] = []
    private var broadMasks: [(rejected: Set<Int>, tokens: [Int])] = []
    private var resourceExhausted = false
    static let maximumStates = 8192
    private static let maximumMaskEntries = 4

    init(format: JSONAnswerFormat, profile: JSONAnswerProfile, vocabulary: JSONAnswerVocabulary,
         initialPhase: JSONAnswerPhase, maxTokens: Int) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("\(profile.family) JSON answers require a positive output budget")
        }
        self.format = format
        self.profile = profile
        self.vocabulary = vocabulary
        self.initialPhase = initialPhase
        self.maxTokens = maxTokens
        fallbackTokenID = vocabulary.fallbackTokenID
        let initial = JSONAnswerBoundary(phase: initialPhase, grammar: format.grammar)
        states = [initial]
        stateIndex = [initial: 0]
    }

    /// The prompt-side channel state for the stream's native reasoning split.
    var channelPrefix: String {
        initialPhase == .reasoning
            ? ReasoningPromptProbe.thinkOpen : ReasoningPromptProbe.thinkOpen + ReasoningPromptProbe.thinkClose
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard !resourceExhausted, remainingTokens > 0, states.indices.contains(state) else { return [] }
        if let index = allowedCache.firstIndex(where: { $0.state == state }) {
            let entry = allowedCache.remove(at: index)
            allowedCache.append(entry)
            return entry.tokens
        }
        let boundary = states[state]
        var allowed: [Int]
        if let sensitive = broadCandidates(boundary) {
            // Opaque spans: only sensitive pieces can be refused, so the rest
            // of the vocabulary is admitted without simulation.
            let rejected = Set(sensitive.filter { transition(boundary, token: $0) == nil })
            if let index = broadMasks.firstIndex(where: { $0.rejected == rejected }) {
                let mask = broadMasks.remove(at: index)
                broadMasks.append(mask)
                allowed = mask.tokens
            } else {
                allowed = rejected.isEmpty ? vocabulary.pieceTokenIDs
                    : vocabulary.pieceTokenIDs.filter { !rejected.contains($0) }
                if broadMasks.count == Self.maximumMaskEntries { broadMasks.removeFirst() }
                broadMasks.append((rejected, allowed))
            }
        } else {
            allowed = vocabulary.acceptedTokens(from: boundary) {
                $0.consume($1, profile: profile, grammar: format.grammar)
            }
        }
        if boundary.isComplete(format.grammar) { allowed = (allowed + vocabulary.answerEOS).sorted() }
        if allowedCache.count == Self.maximumMaskEntries { allowedCache.removeFirst() }
        allowedCache.append((state, allowed))
        return allowed
    }

    /// The allowed set depends on the budget only through `remainingTokens > 0`,
    /// and interned state ids are never reused, so the CBv2 sampler may keep one
    /// uploaded device mask per state.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !resourceExhausted, remainingTokens > 0, states.indices.contains(state) else { return nil }
        return state
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens, so CBv2 may sample one
    /// step ahead and redraw it when the confirmed token changes the state.
    var allowsChainedDecode: Bool { true }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !resourceExhausted, states.indices.contains(state), vocabulary.pieces.indices.contains(tokenID) else {
            return nil
        }
        let boundary = states[state]
        if vocabulary.stopTokenIDs.contains(tokenID) {
            return vocabulary.answerEOS.contains(tokenID) && boundary.isComplete(format.grammar) ? -1 : nil
        }
        guard let next = transition(boundary, token: tokenID) else { return nil }
        if let known = stateIndex[next] { return known }
        guard states.count < Self.maximumStates else {
            // Resource exhaustion is a typed impossible-state failure, never an
            // unconstrained continuation or a fabricated successful stop.
            resourceExhausted = true
            allowedCache = []
            broadMasks = []
            return nil
        }
        states.append(next)
        stateIndex[next] = states.count - 1
        return states.count - 1
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return states.count }

    /// Reasoning and free string bodies are opaque spans; structural JSON
    /// positions search the byte-ordered vocabulary instead.
    private func broadCandidates(_ boundary: JSONAnswerBoundary) -> [Int]? {
        if boundary.phase == .reasoning { return vocabulary.reasoningSensitive }
        return boundary.inStringBody ? vocabulary.stringSensitive : nil
    }

    private func transition(_ boundary: JSONAnswerBoundary, token: Int) -> JSONAnswerBoundary? {
        let piece = vocabulary.pieces[token]
        guard !piece.isEmpty else { return nil }
        var next = boundary
        for byte in piece {
            guard next.consume(byte, profile: profile, grammar: format.grammar) else { return nil }
        }
        return next
    }
}
