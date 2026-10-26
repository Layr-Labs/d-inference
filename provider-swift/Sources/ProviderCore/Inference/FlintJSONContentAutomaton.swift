// Copyright © 2026 Eigen Labs.
//
// Byte-level JSON automaton for Flint `response_format` content. It plugs into
// FlintNativeProtocolBoundary's content phase: reasoning stays unconstrained,
// and once `</think>` closes (or the model answers directly) the visible
// content must be one JSON value of the compiled grammar.

import Foundation

/// Up to `ToolConstraintSchemaCompiler.maxProperties` declared properties.
struct FlintJSONPropertySet: Hashable, Sendable {
    static let capacity = 128
    private var low: UInt64 = 0
    private var high: UInt64 = 0

    func contains(_ index: Int) -> Bool {
        index < 64 ? low & (1 << UInt64(index)) != 0 : high & (1 << UInt64(index - 64)) != 0
    }

    mutating func insert(_ index: Int) {
        if index < 64 { low |= 1 << UInt64(index) } else { high |= 1 << UInt64(index - 64) }
    }

    func isSuperset(of other: Self) -> Bool { low & other.low == other.low && high & other.high == other.high }
}

/// Immutable per-request grammar compiled from the shared fail-closed schema
/// subset. Objects with declared properties admit exactly those keys, each at
/// most once and in any order (additional keys are never generated, as in
/// strict structured-output engines); objects without declared properties and
/// `json_object` admit arbitrary JSON members.
struct FlintJSONGrammar: Sendable {
    enum Kind: Sendable { case any, object, array, string, integer, number, literal }

    struct Property: Sendable {
        let name: [UInt8]
        let node: Int32
    }

    struct Node: Sendable {
        var kind: Kind
        /// `.literal`: every finite spelling. Otherwise the nullable `null`.
        var literals: Int32?
        var properties: [Property] = []
        var required = FlintJSONPropertySet()
        var openMembers = false
        var items: Int32 = 0
        var minItems = 0
        var maxItems: Int?
    }

    static let anyValue: Int32 = 0
    static let anyObject: Int32 = 1
    static let anyArray: Int32 = 2
    static let anyLiterals: Int32 = 0
    static let nullLiteral: Int32 = 1

    private(set) var nodes: [Node] = [
        Node(kind: .any), Node(kind: .object, openMembers: true), Node(kind: .array, items: FlintJSONGrammar.anyValue),
    ]
    /// Each set is sorted bytewise, so the spellings sharing a prefix form one
    /// contiguous range and a state needs only that range and the depth.
    private(set) var literalSets: [[[UInt8]]] = [
        ["false", "null", "true"].map { Array($0.utf8) }, [Array("null".utf8)],
    ]
    private(set) var root = FlintJSONGrammar.anyObject

    /// `nil` is `json_object`: any JSON object.
    init(schema: ToolValueSchema?) throws {
        if let schema { root = try add(schema) }
    }

    private mutating func add(_ schema: ToolValueSchema) throws -> Int32 {
        let nullable: Int32? = schema.nullable ? Self.nullLiteral : nil
        let node: Node
        switch schema {
        case .object(let properties, let allowsAdditional, _):
            guard properties.count <= FlintJSONPropertySet.capacity else {
                throw ToolConstraintSchemaError.unsupported(
                    "response_format objects allow at most \(FlintJSONPropertySet.capacity) properties")
            }
            var object = Node(kind: .object, literals: nullable, openMembers: properties.isEmpty && allowsAdditional)
            for (index, property) in properties.enumerated() {
                object.properties.append(.init(name: Array(property.name.utf8), node: try add(property.schema)))
                if property.required { object.required.insert(index) }
            }
            node = object
        case .array(let items, let minItems, let maxItems, _):
            node = Node(kind: .array, literals: nullable, items: try add(items), minItems: minItems, maxItems: maxItems)
        case .string(let values, let isNullable):
            if let values {
                node = try literal(values.map(Self.spelling), nullable: isNullable)
            } else {
                node = Node(kind: .string, literals: nullable)
            }
        case .boolean(let values, let isNullable):
            node = try literal((values ?? [false, true]).map { Array(String($0).utf8) }, nullable: isNullable)
        case .integer(let values, let isNullable):
            if let values {
                node = try literal(values.map { Array(String($0).utf8) }, nullable: isNullable)
            } else {
                node = Node(kind: .integer, literals: nullable)
            }
        case .number(let values, _):
            guard values == nil else {
                throw ToolConstraintSchemaError.unsupported("response_format number enums are unsupported")
            }
            node = Node(kind: .number, literals: nullable)
        case .null:
            node = Node(kind: .literal, literals: Self.nullLiteral)
        }
        nodes.append(node)
        return Int32(nodes.count - 1)
    }

    private mutating func literal(_ spellings: [[UInt8]], nullable: Bool) throws -> Node {
        let set = Array(Set(spellings + (nullable ? [Array("null".utf8)] : []))).sorted {
            $0.lexicographicallyPrecedes($1)
        }
        guard !set.isEmpty else { throw ToolConstraintSchemaError.invalid("response_format enum admits no value") }
        // Protocol markup stays impossible in content, so such a value could
        // never be generated. Refuse it instead of dead-ending the sampler.
        for spelling in set where FlintNativeProtocolBoundary.protocolMarkers.contains(where: {
            Self.contains(spelling, $0)
        }) {
            throw ToolConstraintSchemaError.unsupported("response_format enum values cannot contain Flint protocol markup")
        }
        literalSets.append(set)
        return Node(kind: .literal, literals: Int32(literalSets.count - 1))
    }

    /// Minimal JSON escaping; the decoded string is exactly `value`.
    static func spelling(_ value: String) -> [UInt8] {
        var bytes: [UInt8] = [34]
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: bytes += [92, 34]
            case 0x5C: bytes += [92, 92]
            case 0x0A: bytes += [92, 110]
            case 0x0D: bytes += [92, 114]
            case 0x09: bytes += [92, 116]
            case 0x08: bytes += [92, 98]
            case 0x0C: bytes += [92, 102]
            case 0..<0x20: bytes += Array(String(format: "\\u%04x", scalar.value).utf8)
            default: bytes += Array(String(scalar).utf8)
            }
        }
        bytes.append(34)
        return bytes
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }
}

/// Canonical, hashable JSON parse position. Free string bodies collapse to one
/// state per container path; numbers, nesting and declared keys are bounded.
struct FlintJSONState: Hashable {
    struct Frame: Hashable {
        let node: Int32
        /// Arrays: items started, saturated where bounds no longer distinguish.
        var count: Int32 = 0
        /// Objects: declared properties already present.
        var seen = FlintJSONPropertySet()
    }

    enum StringEscape: Hashable { case none, backslash, hex(Int8) }
    enum NumberPart: Hashable { case sign, zero, integer, dot, fraction, exponentMark, exponentSign, exponent }

    enum Lexer: Hashable {
        case value(Int32)
        case literal(set: Int32, lower: Int32, upper: Int32, depth: Int32)
        case string(key: Bool, escape: StringEscape)
        case key([UInt8])
        case number(integer: Bool, part: NumberPart, digits: Int8)
        case objectOpen, objectNext, arrayOpen, afterValue
        case colon(Int32)
    }

    static let maximumDepth = 64
    /// Every accepted integer stays exact in JSON decoders' Double fallback.
    static let maximumIntegerDigits = 15
    /// With these bounds every accepted number is finite.
    static let maximumNumberDigits = 32
    static let maximumExponentDigits = 2

    private(set) var stack: [Frame] = []
    private(set) var lexer: Lexer

    init(grammar: FlintJSONGrammar) { lexer = .value(grammar.root) }

    /// Free string bodies accept every byte except quote, backslash and C0
    /// controls; the boundary additionally rejects protocol marker spellings.
    var inStringBody: Bool {
        if case .string(_, .none) = lexer { return true }
        return false
    }

    /// One complete root value, optionally followed by JSON whitespace.
    func isComplete(_ grammar: FlintJSONGrammar) -> Bool {
        guard stack.isEmpty else { return false }
        switch lexer {
        case .afterValue: return true
        case .literal(let set, let lower, _, let depth):
            return grammar.literalSets[Int(set)][Int(lower)].count == Int(depth)
        case .number(_, let part, _): return [.zero, .integer, .fraction, .exponent].contains(part)
        default: return false
        }
    }

    mutating func consume(_ byte: UInt8, grammar: FlintJSONGrammar) -> Bool {
        switch lexer {
        case .value(let node):
            return Self.whitespace(byte) || startValue(byte, node: node, grammar: grammar)
        case .literal(let set, let lower, let upper, let depth):
            let spellings = grammar.literalSets[Int(set)]
            // Sorted: the one spelling ending here, if any, precedes the rest.
            let complete = spellings[Int(lower)].count == Int(depth)
            let continuing = (Int(lower) + (complete ? 1 : 0))..<Int(upper)
            if let first = continuing.first(where: { spellings[$0][Int(depth)] == byte }) {
                let end = continuing[first...].firstIndex { spellings[$0][Int(depth)] != byte } ?? continuing.upperBound
                setLiteral(set, first, end, Int(depth) + 1, grammar: grammar)
                return true
            }
            // Integer literals are not self-delimiting; the next byte ends them.
            guard complete else { return false }
            lexer = .afterValue
            return consume(byte, grammar: grammar)
        case .string(let key, let escape):
            return consumeString(byte, key: key, escape: escape)
        case .key(let prefix):
            return consumeKey(byte, prefix: prefix, grammar: grammar)
        case .number(let integer, let part, let digits):
            return consumeNumber(byte, integer: integer, part: part, digits: digits, grammar: grammar)
        case .objectOpen, .objectNext:
            if Self.whitespace(byte) { return true }
            guard let frame = stack.last else { return false }
            let node = grammar.nodes[Int(frame.node)]
            if byte == 34 {
                if node.openMembers {
                    lexer = .string(key: true, escape: .none)
                    return true
                }
                guard Self.hasUnseenProperty(frame, node) else { return false }
                lexer = .key([])
                return true
            }
            guard byte == 125, lexer == .objectOpen else { return false }
            return closeObject(grammar)
        case .colon(let node):
            if Self.whitespace(byte) { return true }
            guard byte == 58 else { return false }
            lexer = .value(node)
            return true
        case .arrayOpen:
            if Self.whitespace(byte) { return true }
            guard let frame = stack.last else { return false }
            let node = grammar.nodes[Int(frame.node)]
            if byte == 93 { return closeArray(grammar) }
            guard node.maxItems != 0 else { return false }
            startItem(node)
            return startValue(byte, node: node.items, grammar: grammar)
        case .afterValue:
            if Self.whitespace(byte) { return true }
            guard let frame = stack.last else { return false }
            let node = grammar.nodes[Int(frame.node)]
            if node.kind == .object {
                if byte == 125 { return closeObject(grammar) }
                guard byte == 44, node.openMembers || Self.hasUnseenProperty(frame, node) else { return false }
                lexer = .objectNext
                return true
            }
            if byte == 93 { return closeArray(grammar) }
            guard byte == 44, node.maxItems.map({ Int(frame.count) < $0 }) ?? true else { return false }
            startItem(node)
            lexer = .value(node.items)
            return true
        }
    }

    private mutating func startValue(_ byte: UInt8, node index: Int32, grammar: FlintJSONGrammar) -> Bool {
        let node = grammar.nodes[Int(index)]
        if node.kind == .any {
            switch byte {
            case 123: return push(FlintJSONGrammar.anyObject, lexer: .objectOpen)
            case 91: return push(FlintJSONGrammar.anyArray, lexer: .arrayOpen)
            case 34: lexer = .string(key: false, escape: .none); return true
            case 45, 48...57: return startNumber(byte, integer: false)
            default: return startLiteral(FlintJSONGrammar.anyLiterals, byte, grammar: grammar)
            }
        }
        if let literals = node.literals, node.kind == .literal || byte == 110 {
            return startLiteral(literals, byte, grammar: grammar)
        }
        switch (node.kind, byte) {
        case (.object, 123): return push(index, lexer: .objectOpen)
        case (.array, 91): return push(index, lexer: .arrayOpen)
        case (.string, 34): lexer = .string(key: false, escape: .none); return true
        case (.integer, _): return startNumber(byte, integer: true)
        case (.number, _): return startNumber(byte, integer: false)
        default: return false
        }
    }

    private mutating func push(_ node: Int32, lexer next: Lexer) -> Bool {
        guard stack.count < Self.maximumDepth else { return false }
        stack.append(Frame(node: node))
        lexer = next
        return true
    }

    private mutating func startItem(_ node: FlintJSONGrammar.Node) {
        // Only the larger bound distinguishes counts; saturating there keeps
        // unbounded arrays at one state per container path.
        let saturation = Int32(node.maxItems ?? node.minItems)
        if stack[stack.count - 1].count < saturation { stack[stack.count - 1].count += 1 }
    }

    private mutating func closeObject(_ grammar: FlintJSONGrammar) -> Bool {
        guard let frame = stack.last,
              frame.seen.isSuperset(of: grammar.nodes[Int(frame.node)].required) else { return false }
        stack.removeLast()
        lexer = .afterValue
        return true
    }

    private mutating func closeArray(_ grammar: FlintJSONGrammar) -> Bool {
        guard let frame = stack.last, Int(frame.count) >= grammar.nodes[Int(frame.node)].minItems else { return false }
        stack.removeLast()
        lexer = .afterValue
        return true
    }

    private mutating func startLiteral(_ set: Int32, _ byte: UInt8, grammar: FlintJSONGrammar) -> Bool {
        let spellings = grammar.literalSets[Int(set)]
        guard let first = spellings.firstIndex(where: { $0[0] == byte }) else { return false }
        let end = spellings[first...].firstIndex { $0[0] != byte } ?? spellings.count
        setLiteral(set, first, end, 1, grammar: grammar)
        return true
    }

    private mutating func setLiteral(_ set: Int32, _ lower: Int, _ upper: Int, _ depth: Int,
                                     grammar: FlintJSONGrammar) {
        let unique = upper - lower == 1 && grammar.literalSets[Int(set)][lower].count == depth
        lexer = unique ? .afterValue
            : .literal(set: set, lower: Int32(lower), upper: Int32(upper), depth: Int32(depth))
    }

    private mutating func startNumber(_ byte: UInt8, integer: Bool) -> Bool {
        switch byte {
        case 45: lexer = .number(integer: integer, part: .sign, digits: 0)
        case 48: lexer = .number(integer: integer, part: .zero, digits: 1)
        case 49...57: lexer = .number(integer: integer, part: .integer, digits: 1)
        default: return false
        }
        return true
    }

    private mutating func consumeNumber(_ byte: UInt8, integer: Bool, part: NumberPart, digits: Int8,
                                        grammar: FlintJSONGrammar) -> Bool {
        let digit = (48...57).contains(byte)
        let integerLimit = integer ? Self.maximumIntegerDigits : Self.maximumNumberDigits
        func next(_ part: NumberPart, _ digits: Int8) -> Bool {
            lexer = .number(integer: integer, part: part, digits: digits)
            return true
        }
        switch part {
        case .sign:
            if byte == 48 { return next(.zero, 1) }
            return digit && next(.integer, 1)
        case .dot:
            return digit && next(.fraction, 1)
        case .exponentMark:
            if byte == 43 || byte == 45 { return next(.exponentSign, 0) }
            return digit && next(.exponent, 1)
        case .exponentSign:
            return digit && next(.exponent, 1)
        case .zero, .integer, .fraction, .exponent:
            let limit = part == .exponent ? Self.maximumExponentDigits
                : part == .fraction ? Self.maximumNumberDigits : integerLimit
            if digit {
                guard part != .zero, Int(digits) < limit else { return false }
                return next(part, digits + 1)
            }
            if !integer, byte == 46, part == .zero || part == .integer { return next(.dot, 0) }
            if !integer, byte == 69 || byte == 101, part != .exponent { return next(.exponentMark, 0) }
            lexer = .afterValue
            return consume(byte, grammar: grammar)
        }
    }

    private mutating func consumeString(_ byte: UInt8, key: Bool, escape: StringEscape) -> Bool {
        switch escape {
        case .none:
            if byte == 34 {
                // Free keys occur only in objects without declared properties,
                // whose members are arbitrary JSON values.
                lexer = key ? .colon(FlintJSONGrammar.anyValue) : .afterValue
                return true
            }
            if byte == 92 { lexer = .string(key: key, escape: .backslash) }
            return byte >= 0x20
        case .backslash:
            if byte == 117 { lexer = .string(key: key, escape: .hex(4)); return true }
            guard [34, 92, 47, 98, 102, 110, 114, 116].contains(byte) else { return false }
            lexer = .string(key: key, escape: .none)
            return true
        case .hex(let remaining):
            guard (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) else { return false }
            lexer = .string(key: key, escape: remaining == 1 ? .none : .hex(remaining - 1))
            return true
        }
    }

    /// Declared names match `^[a-zA-Z0-9_-]{1,64}$`, so a key never needs an
    /// escape that could alias a declared name or hide a duplicate.
    private mutating func consumeKey(_ byte: UInt8, prefix: [UInt8], grammar: FlintJSONGrammar) -> Bool {
        guard let frame = stack.last else { return false }
        let properties = grammar.nodes[Int(frame.node)].properties
        if byte == 34 {
            guard let index = properties.indices.first(where: {
                !frame.seen.contains($0) && properties[$0].name == prefix
            }) else { return false }
            stack[stack.count - 1].seen.insert(index)
            lexer = .colon(properties[index].node)
            return true
        }
        let extended = prefix + [byte]
        guard properties.indices.contains(where: {
            !frame.seen.contains($0) && properties[$0].name.starts(with: extended)
        }) else { return false }
        lexer = .key(extended)
        return true
    }

    private static func hasUnseenProperty(_ frame: Frame, _ node: FlintJSONGrammar.Node) -> Bool {
        node.properties.indices.contains { !frame.seen.contains($0) }
    }

    static func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 10 || byte == 13 || byte == 9 }
}

extension FlintNativeProtocolBoundary {
    /// Content phases of a response-format request use the JSON automaton.
    /// The opening thought stays optional; protocol marker spellings stay
    /// impossible inside JSON strings, so no call frame or channel switch can
    /// appear in the answer.
    mutating func consumeJSONContent(_ byte: UInt8, grammar: FlintJSONGrammar) -> Bool {
        if phase == .initial {
            if !marker.isEmpty || byte == 60 {
                marker.append(byte)
                guard Self.think.starts(with: marker) else { return false }
                if marker == Self.think {
                    marker = []
                    phase = .reasoning
                }
                return true
            }
            if FlintJSONState.whitespace(byte) { return true }
            phase = .content
            json = FlintJSONState(grammar: grammar)
        }
        marker.append(byte)
        while !marker.isEmpty && !Self.protocolMarkers.contains(where: { $0.starts(with: marker) }) {
            marker.removeFirst()
        }
        guard !Self.protocolMarkers.contains(marker) else { return false }
        return json?.consume(byte, grammar: grammar) == true
    }

    func jsonContentComplete(_ grammar: FlintJSONGrammar) -> Bool {
        phase == .content && json?.isComplete(grammar) == true
    }

    /// Structural JSON positions admit few bytes; searching the byte-ordered
    /// vocabulary prunes whole token ranges at their first rejected byte.
    func searchesByteOrderedVocabulary(_ rules: Rules) -> Bool {
        rules.json != nil && (phase == .initial || phase == .content)
    }
}

extension FlintNativeVocabulary {
    /// Every non-stop token whose complete piece `consume` accepts from
    /// `state`, in ascending token order.
    func acceptedTokens<State>(from state: State, consume: (inout State, UInt8) -> Bool) -> [Int] {
        var accepted: [Int] = []
        collect(0, byteOrderedTokenIDs.count, depth: 0, state: state, consume: consume, into: &accepted)
        return accepted.sorted()
    }

    /// Pieces in `lower..<upper` share their first `depth` bytes and are all
    /// longer than `depth`, so their next bytes are sorted.
    private func collect<State>(_ lower: Int, _ upper: Int, depth: Int, state: State,
                                consume: (inout State, UInt8) -> Bool, into accepted: inout [Int]) {
        var index = lower
        while index < upper {
            let byte = pieces[Int(byteOrderedTokenIDs[index])][depth]
            var low = index + 1, high = upper
            while low < high {
                let middle = (low + high) / 2
                if pieces[Int(byteOrderedTokenIDs[middle])][depth] == byte { low = middle + 1 } else { high = middle }
            }
            let end = low
            var next = state
            if consume(&next, byte) {
                var rest = index
                while rest < end, pieces[Int(byteOrderedTokenIDs[rest])].count == depth + 1 {
                    accepted.append(Int(byteOrderedTokenIDs[rest]))
                    rest += 1
                }
                if rest < end { collect(rest, end, depth: depth + 1, state: next, consume: consume, into: &accepted) }
            }
            index = end
        }
    }
}
