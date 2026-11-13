// Copyright © 2026 Eigen Labs.
//
// JSON `response_format` answers on Gemma 4. Its tokenizer is SentencePiece
// BPE, not byte-level: pieces spell a space as U+2581 and reach other bytes
// through 256 byte-fallback tokens. `GemmaAnswerPieces` gives each id the bytes
// the stream decodes it to, so the shared byte-level JSON lexer
// (`FlintJSONState`) drives the mask as it does for Qwen. The thought
// (`<|channel>` ... `<channel|>`) stays free; the answer is one JSON value of
// the request's format, then `<turn|>` or `<eos>`.

import Foundation
import MLXLMCommon

extension JSONAnswerProfile {
    /// Gemma 4 (`gemma4`, `gemma4_text`): 262,144 SentencePiece ids. No id is
    /// byte-level BPE (`firstAddedTokenID` 0): `GemmaAnswerPieces` spells them.
    /// The thought markers are pieces so the thought can open and close; every
    /// control spelling stays impossible in the answer. Answers end with
    /// `<turn|>` or `<eos>`.
    static let gemma4 = JSONAnswerProfile(
        family: "Gemma",
        thinkClose: GemmaAnswerPieces.thoughtClose,
        reasoningStops: [],
        contentMarkers: GemmaAnswerPieces.controlSpellings,
        firstAddedTokenID: 0,
        pieceTokens: [.init(spelling: GemmaAnswerPieces.thoughtOpen, id: 100),
                      .init(spelling: GemmaAnswerPieces.thoughtClose, id: 101)],
        answerEOS: [.init(spelling: "<turn|>", id: 106), .init(spelling: "<eos>", id: 1)],
        vocabularySize: 262_144)
}

/// A Gemma 4 JSON-answer vocabulary and the longest run of JSON whitespace any
/// of its pieces starts with (31 bytes for Gemma 4: thirty-one newlines).
struct GemmaAnswerVocabulary: Sendable {
    let json: JSONAnswerVocabulary
    let leadingWhitespace: Int

    init(_ json: JSONAnswerVocabulary) {
        self.json = json
        leadingWhitespace = json.pieceTokenIDs.reduce(0) { longest, id in
            max(longest, json.pieces[id].prefix(while: FlintJSONState.whitespace).count)
        }
    }
}

/// Gemma 4's vocabulary as the bytes its decoder produces (U+2581 to a space,
/// byte fallback, fuse; no strip). The provider's tokenizer runs no
/// clean-up for Gemma (`LocalTokenizerLoader`).
enum GemmaAnswerPieces {
    static let thoughtOpen = "<|channel>"
    static let thoughtClose = "<channel|>"
    /// Gemma 4's added tokens. None is text, and no answer may spell one:
    /// the stream's parsers read them as framing.
    static let controlSpellings = [
        "<pad>", "<eos>", "<bos>", "<unk>", "<mask>", "<|tool>", "<tool|>", "<|tool_call>", "<tool_call|>",
        "<|tool_response>", "<tool_response|>", "<|\"|>", "<|think|>", "<|channel>", "<channel|>", "<|turn>",
        "<turn|>", "<|image>", "<|audio>", "<|image|>", "<|audio|>", "<image|>", "<audio|>", "<|video|>",
    ]
    private static let controls = Set(controlSpellings)
    private static let cache = TokenizerVocabularyCache<Set<Int>, GemmaAnswerVocabulary>(capacity: 2)

    /// The bytes one vocabulary entry decodes to, or nil for an entry that is
    /// never answer text: a control token, an `<unusedN>` slot, or an ASCII
    /// byte-fallback token. A byte-fallback run is decoded as a whole, so what
    /// one byte becomes depends on its neighbours (a run that is not UTF-8 reads
    /// as U+FFFD); every ASCII character JSON needs has its own piece, and
    /// non-ASCII bytes occur only inside strings, where U+FFFD is a character.
    static func bytes(_ raw: String) -> [UInt8]? {
        if raw.utf8.count == 6, raw.hasPrefix("<0x"), raw.hasSuffix(">"),
           let byte = UInt8(raw.dropFirst(3).dropLast(), radix: 16) {
            return byte >= 0x80 ? [byte] : nil
        }
        if controls.contains(raw) { return nil }
        if raw.hasPrefix("<unused"), raw.hasSuffix(">"), raw.count > 8,
           raw.dropFirst(7).dropLast().allSatisfy({ $0.isASCII && $0.isNumber }) {
            return nil
        }
        let bytes = Array(raw.replacingOccurrences(of: "\u{2581}", with: " ").utf8)
        return bytes.isEmpty ? nil : bytes
    }

    static func cachedVocabulary(for handle: TokenizerHandle, stopTokenIDs: Set<Int>) throws -> GemmaAnswerVocabulary {
        try cache.value(for: handle, key: stopTokenIDs) {
            GemmaAnswerVocabulary(try vocabulary(tokenizer: handle.inner, stopTokenIDs: stopTokenIDs))
        }
    }

    /// Verifies the thought markers and terminators by id, spelling, encoding
    /// and decoding, and that the tokenizer has exactly the model's ids.
    static func vocabulary(tokenizer: any MLXLMCommon.Tokenizer, profile: JSONAnswerProfile = .gemma4,
                           stopTokenIDs: Set<Int>) throws -> JSONAnswerVocabulary {
        for token in profile.pieceTokens + profile.answerEOS {
            guard tokenizer.convertTokenToId(token.spelling) == token.id,
                  tokenizer.convertIdToToken(token.id) == token.spelling,
                  tokenizer.encode(text: token.spelling, addSpecialTokens: false) == [token.id],
                  tokenizer.decode(tokenIds: [token.id], skipSpecialTokens: false) == token.spelling else {
                throw ToolConstraintSchemaError.invalid("Gemma vocabulary does not match the pinned marker contract")
            }
        }
        guard tokenizer.convertIdToToken(profile.vocabularySize) == nil else {
            throw ToolConstraintSchemaError.invalid("Gemma tokenizer is larger than the pinned vocabulary")
        }
        var pieces = [[UInt8]](repeating: [], count: profile.vocabularySize)
        for id in 0..<profile.vocabularySize {
            guard let raw = tokenizer.convertIdToToken(id) else {
                throw ToolConstraintSchemaError.invalid("Incomplete Gemma vocabulary")
            }
            pieces[id] = bytes(raw) ?? []
        }
        for token in profile.pieceTokens { pieces[token.id] = Array(token.spelling.utf8) }
        return try JSONAnswerVocabulary(pieces: pieces, profile: profile, stopTokenIDs: stopTokenIDs)
    }
}

/// Interned parse position of a constrained Gemma answer: the phase, the
/// rolling marker window, the JSON lexer once answering, and the current run
/// of whitespace outside strings. No thought text or string body is kept.
struct GemmaJSONAnswerBoundary: Hashable {
    enum Phase: Hashable {
        /// The prompt ends at the model's turn: a thought may open, or the
        /// answer starts (leading whitespace stays content).
        case opening
        /// Free text until `<channel|>`.
        case thought
        /// One JSON value of the grammar.
        case answer
    }

    /// Consecutive JSON whitespace bytes allowed outside strings: room for any
    /// indentation, while a model that keeps reaching for a refused spelling
    /// (a code fence) cannot fill its budget with blank lines.
    static let maximumWhitespaceRun = 64
    private static let thoughtOpen = Array(GemmaAnswerPieces.thoughtOpen.utf8)
    private static let thoughtCloseMarkers = [Array(GemmaAnswerPieces.thoughtClose.utf8)]

    private(set) var phase: Phase
    private(set) var window: [UInt8] = []
    private(set) var json: FlintJSONState?
    private(set) var whitespace = 0

    init(phase: Phase, grammar: FlintJSONGrammar) {
        self.phase = phase
        if phase == .answer { json = FlintJSONState(grammar: grammar) }
    }

    /// Free string bodies admit every piece without a sensitive byte.
    var inStringBody: Bool { json?.inStringBody == true }

    /// The value is complete; `isClosed` when it also delimits itself (a
    /// number or an integer literal could still grow).
    func isComplete(_ grammar: FlintJSONGrammar) -> Bool { json?.isComplete(grammar) == true }
    var isClosed: Bool { json.map { $0.stack.isEmpty && $0.lexer == .afterValue } == true }

    /// The same position with a whitespace run no piece can push past the
    /// cap (`leadingWhitespace` is the longest run a piece starts with), so it
    /// admits exactly the same pieces as one with no run.
    func maskEquivalent(leadingWhitespace: Int) -> GemmaJSONAnswerBoundary {
        guard whitespace > 0, whitespace + leadingWhitespace <= Self.maximumWhitespaceRun else { return self }
        var canonical = self
        canonical.whitespace = 0
        return canonical
    }

    mutating func consume(_ byte: UInt8, grammar: FlintJSONGrammar, markers: [[UInt8]]) -> Bool {
        switch phase {
        case .opening:
            if !window.isEmpty || byte == 0x3C {
                window.append(byte)
                guard Self.thoughtOpen.starts(with: window) else { return false }
                if window.count == Self.thoughtOpen.count {
                    phase = .thought
                    window = []
                    whitespace = 0
                }
                return true
            }
            if FlintJSONState.whitespace(byte) { return extendWhitespaceRun() }
            phase = .answer
            json = FlintJSONState(grammar: grammar)
            return consumeAnswer(byte, grammar: grammar, markers: markers)
        case .thought:
            if Self.advance(&window, with: byte, markers: Self.thoughtCloseMarkers) != nil {
                phase = .answer
                window = []
                json = FlintJSONState(grammar: grammar)
            }
            return true
        case .answer:
            return consumeAnswer(byte, grammar: grammar, markers: markers)
        }
    }

    private mutating func consumeAnswer(_ byte: UInt8, grammar: FlintJSONGrammar, markers: [[UInt8]]) -> Bool {
        // A closed value is followed by its terminator only, never by text
        // the client would have to strip (a fence, blank lines).
        guard var json, !isClosed, Self.advance(&window, with: byte, markers: markers) == nil else { return false }
        if FlintJSONState.whitespace(byte), !json.inString {
            guard extendWhitespaceRun() else { return false }
        } else {
            whitespace = 0
        }
        guard json.consume(byte, grammar: grammar) else { return false }
        self.json = json
        return true
    }

    private mutating func extendWhitespaceRun() -> Bool {
        whitespace += 1
        return whitespace <= Self.maximumWhitespaceRun
    }

    /// Keeps the longest window suffix that still starts a marker and returns
    /// a marker this byte completed, however the output was split into tokens.
    private static func advance(_ window: inout [UInt8], with byte: UInt8, markers: [[UInt8]]) -> [UInt8]? {
        window.append(byte)
        while !window.isEmpty && !markers.contains(where: { $0.starts(with: window) }) {
            window.removeFirst()
        }
        return markers.first { window.count >= $0.count && window.suffix($0.count).elementsEqual($0) }
    }
}

private extension FlintJSONState {
    /// Inside a string or a declared key, where whitespace is content.
    var inString: Bool {
        switch lexer {
        case .string, .key: return true
        default: return false
        }
    }
}

/// Constrains one Gemma 4 answer to a single JSON value of a compiled grammar,
/// after an optional free thought. The answer may end only once the value is
/// complete, and a self-delimited value only with its terminator. Best effort
/// by design, unlike `JSONAnswerConstraint`: the stream is not validated
/// afterwards, a budget cut stays `length`, and a request whose states outgrow
/// the cap continues unconstrained rather than failing. Per-request and
/// host-only; interning collapses free text to bounded framing states.
final class GemmaJSONAnswerConstraint: CBv2TokenConstraint, @unchecked Sendable {
    static let defaultMaximumStates = 16_384
    /// Broad allowed sets (thought, string bodies) are most of the vocabulary;
    /// two per request cover a key and a value string. The sampler keeps the
    /// uploaded masks per key itself.
    private static let maximumBroadMasks = 2

    /// An interned state: a parse position, or unconstrained output after the
    /// state cap.
    private enum Node: Hashable {
        case bounded(GemmaJSONAnswerBoundary)
        case free

        func maskEquivalent(leadingWhitespace: Int) -> Node {
            guard case .bounded(let boundary) = self else { return self }
            return .bounded(boundary.maskEquivalent(leadingWhitespace: leadingWhitespace))
        }
    }

    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let format: JSONAnswerFormat
    let initialPhase: GemmaJSONAnswerBoundary.Phase
    let maximumStates: Int
    private let vocabulary: JSONAnswerVocabulary
    private let leadingWhitespace: Int
    private let markers: [[UInt8]]
    private let vocabularySize: Int
    private let lock = NSLock()
    private var nodes: [Node]
    private var nodeIndex: [Node: Int]
    /// Per state, its mask key: states with the same `maskEquivalent` share
    /// one, so the sampler builds and uploads that mask once.
    private var maskKeys: [Int]
    private var maskKeyIndex: [Node: Int]
    private var broadMasks: [(rejected: Set<Int>, tokens: [Int])] = []

    init(format: JSONAnswerFormat, vocabulary: GemmaAnswerVocabulary, profile: JSONAnswerProfile = .gemma4,
         initialPhase: GemmaJSONAnswerBoundary.Phase, maxTokens: Int,
         maximumStates: Int = GemmaJSONAnswerConstraint.defaultMaximumStates) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("Gemma JSON answers require a positive output budget")
        }
        self.format = format
        self.vocabulary = vocabulary.json
        leadingWhitespace = vocabulary.leadingWhitespace
        self.initialPhase = initialPhase
        self.maxTokens = maxTokens
        self.maximumStates = max(2, maximumStates)
        markers = profile.contentMarkers
        vocabularySize = vocabulary.json.pieces.count
        fallbackTokenID = vocabulary.json.fallbackTokenID
        let initial = Node.bounded(GemmaJSONAnswerBoundary(phase: initialPhase, grammar: format.grammar))
        nodes = [initial]
        nodeIndex = [initial: 0]
        maskKeys = [0]
        maskKeyIndex = [initial: 0]
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, nodes.indices.contains(state) else { return [] }
        switch nodes[state] {
        case .free:
            return Array(0..<vocabularySize)
        case .bounded(let boundary):
            return allowedTokens(boundary.maskEquivalent(leadingWhitespace: leadingWhitespace))
        }
    }

    /// The allowed set depends on the budget only through `remainingTokens > 0`,
    /// and mask keys are never reused for another set, so the CBv2 sampler may
    /// keep one uploaded device mask per key.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, maskKeys.indices.contains(state) else { return nil }
        return maskKeys[state]
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens, so CBv2 may sample one
    /// step ahead and redraw it when the confirmed token changes the state.
    var allowsChainedDecode: Bool { true }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard nodes.indices.contains(state), (0..<vocabularySize).contains(tokenID) else { return nil }
        guard case .bounded(let boundary) = nodes[state] else {
            return vocabulary.stopTokenIDs.contains(tokenID) ? -1 : state
        }
        if vocabulary.stopTokenIDs.contains(tokenID) {
            return vocabulary.answerEOS.contains(tokenID) && boundary.phase == .answer
                && boundary.isComplete(format.grammar) ? -1 : nil
        }
        guard let next = transition(boundary, token: tokenID) else { return nil }
        let node = Node.bounded(next)
        if let known = nodeIndex[node] { return known }
        // Past the cap the answer continues as today's unconstrained output,
        // never as an impossible state or a fabricated stop.
        let interned = nodes.count < maximumStates - 1 ? node : .free
        if let known = nodeIndex[interned] { return known }
        let index = nodes.count
        nodes.append(interned)
        nodeIndex[interned] = index
        let equivalent = interned.maskEquivalent(leadingWhitespace: leadingWhitespace)
        let maskKey = maskKeyIndex[equivalent] ?? index
        maskKeyIndex[equivalent] = maskKey
        maskKeys.append(maskKey)
        return index
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return nodes.count }

    private func allowedTokens(_ boundary: GemmaJSONAnswerBoundary) -> [Int] {
        let grammar = format.grammar
        if boundary.phase == .answer, boundary.isClosed { return vocabulary.answerEOS }
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
                if broadMasks.count == Self.maximumBroadMasks { broadMasks.removeFirst() }
                broadMasks.append((rejected, allowed))
            }
        } else {
            let markers = markers
            allowed = vocabulary.acceptedTokens(from: boundary) { $0.consume($1, grammar: grammar, markers: markers) }
        }
        if boundary.phase == .answer, boundary.isComplete(grammar) {
            allowed = (allowed + vocabulary.answerEOS).sorted()
        }
        return allowed
    }

    /// The thought and free string bodies are opaque spans; structural
    /// positions search the byte-ordered vocabulary instead.
    private func broadCandidates(_ boundary: GemmaJSONAnswerBoundary) -> [Int]? {
        if boundary.phase == .thought { return vocabulary.reasoningSensitive }
        return boundary.inStringBody ? vocabulary.stringSensitive : nil
    }

    private func transition(_ boundary: GemmaJSONAnswerBoundary, token: Int) -> GemmaJSONAnswerBoundary? {
        let piece = vocabulary.pieces[token]
        guard !piece.isEmpty else { return nil }
        var next = boundary
        for byte in piece {
            guard next.consume(byte, grammar: format.grammar, markers: markers) else { return nil }
        }
        return next
    }
}
