// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon

/// Fixed framing of a Qwen 3.5 call, as its chat template renders one:
/// `<tool_call>\n<function=NAME>\n<parameter=KEY>\nVALUE\n</parameter>\n…`
/// `</function>\n</tool_call>`.
enum QwenStrictToolFraming: Int8, Hashable, Sendable {
    /// After the function name's `>`, and after a text value's `</parameter>`.
    case lineBreak
    /// `<parameter=`, entered after its first two bytes.
    case parameterOpen
    /// After a parameter name's `>`.
    case valueOpen
    /// After a complete choice or JSON value, entered after its line break.
    case valueClose
    /// `</function>\n</tool_call>`, entered after its first two bytes.
    case callClose

    var bytes: [UInt8] {
        switch self {
        case .lineBreak, .valueOpen: Self.lineBreakBytes
        case .parameterOpen: Self.parameterOpenBytes
        case .valueClose: QwenStrictToolSchema.valueClose
        case .callClose: Self.callCloseBytes
        }
    }

    private static let lineBreakBytes: [UInt8] = [10]
    private static let parameterOpenBytes = Array("<parameter=".utf8)
    private static let callCloseBytes = Array("</function>\n</tool_call>".utf8)
}

/// The spellings each span of a call watches, built once per constraint,
/// and whether a second call may follow the first.
struct QwenStrictToolMarkers: Sendable {
    /// A text value: its closing tag ends it; any other is refused.
    let text: [[UInt8]]
    /// A JSON value: every one is refused.
    let value: [[UInt8]]
    /// `parallel_tool_calls: false`: no call opens after one closed.
    let singleCall: Bool

    init(forbidding markers: [[UInt8]], singleCall: Bool = false) {
        text = markers + [QwenStrictToolBoundary.parameterClose]
        value = text + QwenStrictToolBoundary.surrogateEscapes
        self.singleCall = singleCall
    }
}

/// Interned parse position of a Qwen 3.5 response under the strict-tool
/// grammar. Reasoning and text outside calls are free and only watched for
/// the marker that leaves them; inside a call every byte follows the call
/// framing and the declared schemas. No reasoning, text or argument body is
/// accumulated.
struct QwenStrictToolBoundary: Hashable {
    enum Step: Hashable {
        /// Prompt-opened reasoning, free until `</think>`.
        case reasoning
        /// Free text, until `<tool_call>` opens a call.
        case content
        /// After `<tool_call>`: whitespace, then the bytes of `<function=`
        /// matched so far. Another byte is not a call the parser can read, so
        /// the answer goes on as text, as without a grammar; `{` (the JSON
        /// dialect) and a non-ASCII byte (Unicode whitespace the parser would
        /// skip) are refused.
        case opening(Int8)
        case fixed(QwenStrictToolFraming, Int16)
        /// The function name typed so far.
        case name([UInt8])
        /// Between parameters; true after a `<`.
        case between(Bool)
        /// The parameter name typed so far.
        case key([UInt8])
        /// A text value, until `</parameter>`.
        case text
        /// A choice value and its closing framing, typed so far.
        case choice([UInt8])
        case json(FlintJSONState)
    }

    static let thinkClose = Array("</think>".utf8)
    static let callOpen = Array("<tool_call>".utf8)
    static let parameterClose = Array("</parameter>".utf8)
    static let functionOpen = Array("<function=".utf8)
    /// Whitespace the parser skips between `<tool_call>` and `<function=`.
    static func isOpeningWhitespace(_ byte: UInt8) -> Bool { (9...13).contains(byte) || byte == 32 }
    /// Refused right after `<tool_call>`: the JSON dialect, and a non-ASCII
    /// byte, which could be whitespace the parser would skip.
    static func isRefusedAfterCallMarker(_ byte: UInt8) -> Bool { byte == 123 || byte >= 0x80 }
    private static let reasoningMarkers = [thinkClose]
    private static let contentMarkers = [callOpen]
    /// `\uD800`…`\uDFFF`: the parser's JSONSerialization refuses a lone
    /// surrogate escape, which would leave the whole value a string, so a JSON
    /// value never writes one (a character outside the BMP is written as is).
    static let surrogateEscapes: [[UInt8]] = "dD".utf8.flatMap { first in
        "89abcdefABCDEF".utf8.map { second in [92, 117, first, second] }
    }

    private(set) var step: Step
    private(set) var window: [UInt8] = []
    private(set) var tool: Int16 = -1
    private(set) var parameter: Int16 = -1
    private(set) var seen = FlintJSONPropertySet()
    /// A call closed earlier in this answer.
    private(set) var closedCall = false

    init(reasoning: Bool) { step = reasoning ? .reasoning : .content }

    /// Outside calls: an end of the answer may be sampled here.
    var isFree: Bool {
        switch step {
        case .reasoning, .content, .opening: true
        default: false
        }
    }

    /// Draft only ordinary text, never a partial marker or a call opening.
    var isFreeSpan: Bool {
        guard window.isEmpty else { return false }
        switch step {
        case .reasoning, .content: return true
        default: return false
        }
    }

    /// Free spans whose bytes can only be refused by completing a marker:
    /// reasoning, text, text values (every marker ends in `>`).
    var isOpaqueSpan: Bool {
        switch step {
        case .reasoning, .content, .text: true
        default: false
        }
    }

    var inJSONStringBody: Bool {
        if case .json(let state) = step { return state.inStringBody }
        return false
    }

    mutating func consume(_ byte: UInt8, schema: QwenStrictToolSchema, markers: QwenStrictToolMarkers) -> Bool {
        switch step {
        case .reasoning:
            if Self.advance(&window, with: byte, markers: Self.reasoningMarkers) != nil {
                window = []
                step = .content
            }
            return true
        case .content:
            if Self.advance(&window, with: byte, markers: Self.contentMarkers) != nil {
                guard !(markers.singleCall && closedCall) else { return false }
                window = []
                step = .opening(0)
            }
            return true
        case .opening(let matched):
            if matched == 0, Self.isOpeningWhitespace(byte) { return true }
            if byte == Self.functionOpen[Int(matched)] {
                step = Int(matched) + 1 == Self.functionOpen.count ? .name([]) : .opening(matched + 1)
                return true
            }
            if matched == 0, Self.isRefusedAfterCallMarker(byte) { return false }
            // Text again, watched from the bytes after `<tool_call>` on.
            step = .content
            for previous in Self.functionOpen.prefix(Int(matched)) {
                _ = Self.advance(&window, with: previous, markers: Self.contentMarkers)
            }
            return consume(byte, schema: schema, markers: markers)
        case .fixed(let framing, let offset):
            let bytes = framing.bytes
            guard bytes[Int(offset)] == byte else { return false }
            if Int(offset) + 1 < bytes.count {
                step = .fixed(framing, offset + 1)
            } else {
                complete(framing, schema: schema)
            }
            return true
        case .name(let prefix):
            if byte == 62 {
                guard let index = schema.tools.firstIndex(where: { $0.name == prefix }) else { return false }
                tool = Int16(index)
                seen = FlintJSONPropertySet()
                step = .fixed(.lineBreak, 0)
                return true
            }
            let extended = prefix + [byte]
            guard schema.tools.contains(where: { $0.name.starts(with: extended) }) else { return false }
            step = .name(extended)
            return true
        case .between(let afterAngle):
            let declared = schema.tools[Int(tool)]
            guard afterAngle else {
                guard byte == 60 else { return false }
                step = .between(true)
                return true
            }
            if byte == 112, declared.parameters.indices.contains(where: { !seen.contains($0) }) {
                step = .fixed(.parameterOpen, 2)
                return true
            }
            if byte == 47, seen.isSuperset(of: declared.required) {
                step = .fixed(.callClose, 2)
                return true
            }
            return false
        case .key(let prefix):
            let parameters = schema.tools[Int(tool)].parameters
            if byte == 62 {
                guard let index = parameters.indices.first(where: { !seen.contains($0) && parameters[$0].name == prefix })
                else { return false }
                seen.insert(index)
                parameter = Int16(index)
                step = .fixed(.valueOpen, 0)
                return true
            }
            let extended = prefix + [byte]
            guard parameters.indices.contains(where: { !seen.contains($0) && parameters[$0].name.starts(with: extended) })
            else { return false }
            step = .key(extended)
            return true
        case .text:
            guard let marker = Self.advance(&window, with: byte, markers: markers.text) else {
                return true
            }
            guard marker == Self.parameterClose else { return false }
            window = []
            parameter = -1
            step = .fixed(.lineBreak, 0)
            return true
        case .choice(let prefix):
            guard case .choice(let spellings) = schema.tools[Int(tool)].parameters[Int(parameter)].value else {
                return false
            }
            let extended = prefix + [byte]
            guard spellings.contains(where: { $0.starts(with: extended) }) else { return false }
            if spellings.contains(extended) {
                parameter = -1
                step = .between(false)
            } else {
                step = .choice(extended)
            }
            return true
        case .json(var state):
            guard case .json(let grammar) = schema.tools[Int(tool)].parameters[Int(parameter)].value else {
                return false
            }
            if byte == 10, state.isComplete(grammar) {
                window = []
                step = .fixed(.valueClose, 1)
                return true
            }
            // A value may never spell a marker, the tag that ends it, or a
            // surrogate escape.
            guard Self.advance(&window, with: byte, markers: markers.value) == nil,
                  state.consume(byte, grammar: grammar) else { return false }
            step = .json(state)
            return true
        }
    }

    private mutating func complete(_ framing: QwenStrictToolFraming, schema: QwenStrictToolSchema) {
        switch framing {
        case .lineBreak:
            step = .between(false)
        case .parameterOpen:
            step = .key([])
        case .valueOpen:
            switch schema.tools[Int(tool)].parameters[Int(parameter)].value {
            case .text: step = .text
            case .choice: step = .choice([])
            case .json(let grammar): step = .json(FlintJSONState(grammar: grammar))
            }
        case .valueClose:
            parameter = -1
            step = .between(false)
        case .callClose:
            tool = -1
            seen = FlintJSONPropertySet()
            closedCall = true
            step = .content
        }
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

/// Constrains the arguments of every call a Qwen 3.5 answer opens to the
/// declared schemas (`QwenStrictToolSchema`), and nothing else: reasoning and
/// text stay free, an answer may end wherever it could before, and `auto`
/// still lets the model choose whether to call. Inside a call the function
/// must be declared, each parameter is declared and at most once, required
/// ones come before `</function>`, and each value is one the parser reads as
/// a schema-valid argument. Per-request and host-only, like
/// `JSONAnswerConstraint`, whose vocabulary and interning it shares.
///
/// Should the interned states ever run out, the constraint releases the rest
/// of the answer to free sampling (as before the grammar) instead of failing
/// it.
final class QwenStrictToolConstraint: CBv2FreeSpanTokenConstraint, @unchecked Sendable {
    let mode = CBv2TokenConstraintMode.auto
    let maxTokens: Int
    let initialState = 0
    let fallbackTokenID: Int
    let schema: QwenStrictToolSchema
    let startsInReasoning: Bool
    private let vocabulary: JSONAnswerVocabulary
    private let markers: QwenStrictToolMarkers
    /// Stop tokens sampled outside calls end the answer, as without a grammar.
    private let freeStops: [Int]
    private let lock = NSLock()
    private var states: [QwenStrictToolBoundary]
    private var stateIndex: [QwenStrictToolBoundary: Int]
    private var allowedCache: [(state: Int, tokens: [Int])] = []
    /// Opaque-span masks by refused pieces and whether stops are allowed.
    private var broadMasks: [(rejected: Set<Int>, free: Bool, tokens: [Int])] = []
    /// A call's opening masks by bytes of `<function=` matched: nothing else
    /// of an opening state changes what it admits. At most ten entries.
    private var openingMasks: [Int: [Int]] = [:]
    private var releasedMask: [Int]?
    static let maximumStates = 32_768
    private static let maximumMaskEntries = 8
    /// After resource exhaustion every later token is free (`releasedState`).
    static let releasedState = Int.max

    init(schema: QwenStrictToolSchema, vocabulary: JSONAnswerVocabulary, forbidding markers: [[UInt8]],
         startsInReasoning: Bool, allowsParallelCalls: Bool = true, maxTokens: Int) throws {
        guard maxTokens > 0 else {
            throw ToolConstraintSchemaError.invalid("strict tool grammars require a positive output budget")
        }
        self.schema = schema
        self.vocabulary = vocabulary
        self.markers = QwenStrictToolMarkers(forbidding: markers, singleCall: !allowsParallelCalls)
        self.startsInReasoning = startsInReasoning
        self.maxTokens = maxTokens
        fallbackTokenID = vocabulary.fallbackTokenID
        freeStops = vocabulary.stopTokenIDs.filter { vocabulary.pieces.indices.contains($0) }.sorted()
        let initial = QwenStrictToolBoundary(reasoning: startsInReasoning)
        states = [initial]
        stateIndex = [initial: 0]
    }

    func allowedTokenIDs(state: Int, remainingTokens: Int) -> [Int] {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0 else { return [] }
        if state == Self.releasedState {
            if let releasedMask { return releasedMask }
            let mask = Self.merged(vocabulary.pieceTokenIDs, freeStops)
            releasedMask = mask
            return mask
        }
        guard states.indices.contains(state) else { return [] }
        if let index = allowedCache.firstIndex(where: { $0.state == state }) {
            let entry = allowedCache.remove(at: index)
            allowedCache.append(entry)
            return entry.tokens
        }
        let boundary = states[state]
        var allowed: [Int]
        if case .opening(let matched) = boundary.step {
            if let mask = openingMasks[Int(matched)] {
                allowed = mask
            } else {
                allowed = openingMask(boundary, matched: Int(matched))
                openingMasks[Int(matched)] = allowed
            }
        } else if let sensitive = broadCandidates(boundary) {
            // Opaque spans: only sensitive pieces can be refused, so the rest
            // of the vocabulary is admitted without simulation. Outside calls
            // an answer may also end.
            let rejected = Set(sensitive.filter { transition(boundary, token: $0) == nil })
            let free = boundary.isFree
            if let index = broadMasks.firstIndex(where: { $0.rejected == rejected && $0.free == free }) {
                let mask = broadMasks.remove(at: index)
                broadMasks.append(mask)
                allowed = mask.tokens
            } else {
                allowed = rejected.isEmpty ? vocabulary.pieceTokenIDs
                    : vocabulary.pieceTokenIDs.filter { !rejected.contains($0) }
                if free { allowed = Self.merged(allowed, freeStops) }
                if broadMasks.count == Self.maximumMaskEntries { broadMasks.removeFirst() }
                broadMasks.append((rejected, free, allowed))
            }
        } else {
            // Structural positions are inside calls, where no answer ends.
            allowed = vocabulary.acceptedTokens(from: boundary) {
                $0.consume($1, schema: schema, markers: markers)
            }
        }
        if allowedCache.count == Self.maximumMaskEntries { allowedCache.removeFirst() }
        allowedCache.append((state, allowed))
        return allowed
    }

    /// The allowed set depends on the budget only through `remainingTokens > 0`,
    /// and interned state ids are never reused, so the CBv2 sampler may keep one
    /// uploaded device mask per state.
    func maskCacheKey(state: Int, remainingTokens: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard remainingTokens > 0, state == Self.releasedState || states.indices.contains(state) else { return nil }
        return state
    }

    /// `allowedTokenIDs` has no observable effect beyond its result, and
    /// `nextState` interns only host-confirmed tokens.
    var allowsChainedDecode: Bool { true }

    func isFreeSpan(state: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return states.indices.contains(state) && states[state].isFreeSpan
    }

    /// Preview a copy: discarded proposals must not intern states or release
    /// the grammar. A token touching a marker is protected even when its final
    /// bytes return to the same free state.
    func isFreeSpanContinuation(state: Int, tokenID: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard states.indices.contains(state), states[state].isFreeSpan,
              vocabulary.pieces.indices.contains(tokenID),
              !vocabulary.stopTokenIDs.contains(tokenID) else { return false }
        let piece = vocabulary.pieces[tokenID]
        guard !piece.isEmpty else { return false }
        let boundary = states[state]
        var next = boundary
        for byte in piece {
            guard next.consume(byte, schema: schema, markers: markers), next.isFreeSpan else { return false }
        }
        return next == boundary
    }

    func nextState(state: Int, tokenID: Int) -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard vocabulary.pieces.indices.contains(tokenID) else { return nil }
        if state == Self.releasedState {
            return vocabulary.stopTokenIDs.contains(tokenID) ? -1 : Self.releasedState
        }
        guard states.indices.contains(state) else { return nil }
        let boundary = states[state]
        if vocabulary.stopTokenIDs.contains(tokenID) { return boundary.isFree ? -1 : nil }
        guard let next = transition(boundary, token: tokenID) else { return nil }
        if let known = stateIndex[next] { return known }
        guard states.count < Self.maximumStates else { return Self.releasedState }
        states.append(next)
        stateIndex[next] = states.count - 1
        return states.count - 1
    }

    var cachedStateCount: Int { lock.lock(); defer { lock.unlock() }; return states.count }

    /// After `<tool_call>` most pieces leave the opening at their first byte
    /// that is not whitespace (the answer goes on as free text), so only pieces
    /// that keep matching `<function=`, or that could complete a marker later,
    /// are simulated; the rest are decided by that byte.
    private func openingMask(_ boundary: QwenStrictToolBoundary, matched: Int) -> [Int] {
        let open = QwenStrictToolBoundary.functionOpen
        var allowed: [Int] = []
        allowed.reserveCapacity(vocabulary.pieceTokenIDs.count + freeStops.count)
        for id in vocabulary.pieceTokenIDs {
            let piece = vocabulary.pieces[id]
            var index = 0
            if matched == 0 {
                while index < piece.count, QwenStrictToolBoundary.isOpeningWhitespace(piece[index]) { index += 1 }
                if index == piece.count {
                    allowed.append(id)
                    continue
                }
            }
            let byte = piece[index]
            let keepsOpening = byte == open[matched]
            if !keepsOpening, matched == 0, QwenStrictToolBoundary.isRefusedAfterCallMarker(byte) { continue }
            if keepsOpening || piece[index...].contains(62) {
                if transition(boundary, token: id) != nil { allowed.append(id) }
            } else {
                allowed.append(id)
            }
        }
        // Ascending already: pieces are listed in id order.
        return Self.merged(allowed, freeStops)
    }

    /// Two ascending lists of distinct ids as one.
    private static func merged(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var i = 0, j = 0
        while i < lhs.count || j < rhs.count {
            if j == rhs.count || (i < lhs.count && lhs[i] < rhs[j]) {
                result.append(lhs[i]); i += 1
            } else {
                result.append(rhs[j]); j += 1
            }
        }
        return result
    }

    /// Reasoning, text and text values are opaque until a marker; JSON string
    /// bodies are opaque until a quote, escape, control byte or marker.
    private func broadCandidates(_ boundary: QwenStrictToolBoundary) -> [Int]? {
        if boundary.isOpaqueSpan { return vocabulary.reasoningSensitive }
        return boundary.inJSONStringBody ? vocabulary.stringSensitive : nil
    }

    private func transition(_ boundary: QwenStrictToolBoundary, token: Int) -> QwenStrictToolBoundary? {
        let piece = vocabulary.pieces[token]
        guard !piece.isEmpty else { return nil }
        var next = boundary
        for byte in piece {
            guard next.consume(byte, schema: schema, markers: markers) else { return nil }
        }
        return next
    }
}
