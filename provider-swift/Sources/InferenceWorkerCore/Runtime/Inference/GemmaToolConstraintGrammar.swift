// Copyright © 2026 Eigen Labs.
//
// Byte-level NFA for the exact Gemma tool-call language rendered by the
// pinned production template. Registry template bytes are never replaced.

import Foundation

struct GemmaByteNFA {
    struct Edge {
        let range: ClosedRange<UInt8>
        let destination: Int
    }
    struct Node {
        var epsilon: [Int] = []
        var edges: [Edge] = []
        var permissiveStringLoop = false
    }

    var nodes: [Node]
    let start: Int
    let accepting: Set<Int>
    let minBytesToAccept: [Int]
}

struct GemmaByteNFABuilder {
    struct Fragment {
        let start: Int
        let end: Int
    }

    var nodes: [GemmaByteNFA.Node] = []
    private struct MemberKey: Hashable {
        let scope: Int
        let index: Int
        let emitted: Bool
    }
    private var memberMemo: [MemberKey: Fragment] = [:]
    private var nextMemberScope = 0

    mutating func node() -> Int {
        nodes.append(.init())
        return nodes.count - 1
    }

    mutating func epsilon(_ from: Int, _ to: Int) {
        nodes[from].epsilon.append(to)
    }

    mutating func edge(
        _ from: Int,
        _ range: ClosedRange<UInt8>,
        _ to: Int
    ) {
        nodes[from].edges.append(.init(range: range, destination: to))
    }

    mutating func literal(_ text: String) -> Fragment {
        literal(Array(text.utf8))
    }

    mutating func literal(_ bytes: [UInt8]) -> Fragment {
        let start = node()
        var current = start
        for byte in bytes {
            let next = node()
            edge(current, byte ... byte, next)
            current = next
        }
        return .init(start: start, end: current)
    }

    mutating func sequence(_ fragments: [Fragment]) -> Fragment {
        guard let first = fragments.first else {
            let empty = node()
            return .init(start: empty, end: empty)
        }
        for pair in zip(fragments, fragments.dropFirst()) {
            epsilon(pair.0.end, pair.1.start)
        }
        return .init(start: first.start, end: fragments.last!.end)
    }

    mutating func alternate(_ fragments: [Fragment]) -> Fragment {
        let start = node()
        let end = node()
        for fragment in fragments {
            epsilon(start, fragment.start)
            epsilon(fragment.end, end)
        }
        return .init(start: start, end: end)
    }

    mutating func optional(_ fragment: Fragment) -> Fragment {
        let start = node()
        let end = node()
        epsilon(start, end)
        epsilon(start, fragment.start)
        epsilon(fragment.end, end)
        return .init(start: start, end: end)
    }

    mutating func zeroOrMore(
        ranges: [ClosedRange<UInt8>],
        permissiveStringLoop: Bool = false
    ) -> Fragment {
        let start = node()
        let end = node()
        nodes[start].permissiveStringLoop = permissiveStringLoop
        epsilon(start, end)
        for range in ranges { edge(start, range, start) }
        return .init(start: start, end: end)
    }

    mutating func oneOrMore(ranges: [ClosedRange<UInt8>]) -> Fragment {
        let start = node()
        let loop = node()
        let end = node()
        for range in ranges {
            edge(start, range, loop)
            edge(loop, range, loop)
        }
        epsilon(loop, end)
        return .init(start: start, end: end)
    }

    mutating func one(ranges: [ClosedRange<UInt8>]) -> Fragment {
        let start = node()
        let end = node()
        for range in ranges { edge(start, range, end) }
        return .init(start: start, end: end)
    }

    mutating func value(_ schema: ToolValueSchema) throws -> Fragment {
        let core: Fragment
        switch schema {
        case .object(let properties, _, _):
            core = sequence([
                literal("{"),
                try objectMembers(properties),
                literal("}"),
            ])
        case .array(let items, let minItems, let maxItems, _):
            let upper = maxItems ?? ToolConstraintSchemaCompiler.maxArrayItems
            core = try array(items: items, minItems: minItems, maxItems: upper)
        case .string(let values, _):
            if let values {
                core = alternate(try values.map { try gemmaString($0) })
            } else {
                let content = utf8StringContent()
                core = sequence([
                    literal("<|\"|>"), content, literal("<|\"|>"),
                ])
            }
        case .boolean(let values, _):
            core = alternate((values ?? [false, true]).map {
                literal($0 ? "true" : "false")
            })
        case .integer(let values, _):
            if let values {
                core = alternate(values.map { literal(String($0)) })
            } else {
                core = integer()
            }
        case .number(let values, _):
            if let values {
                core = alternate(values.map { literal(Self.numberString($0)) })
            } else {
                core = number()
            }
        case .null:
            return literal("null")
        }
        if schema.nullable {
            return alternate([core, literal("null")])
        }
        return core
    }

    mutating func topLevelArguments(_ schema: ToolValueSchema) throws -> Fragment {
        guard case .object(let properties, _, let nullable) = schema, !nullable else {
            throw ToolConstraintSchemaError.unsupported(
                "function parameters must be a non-null object")
        }
        return try objectMembers(properties)
    }

    private mutating func objectMembers(
        _ properties: [ToolValueSchema.Property]
    ) throws -> Fragment {
        let scope = nextMemberScope
        nextMemberScope += 1
        return try members(
            properties, scope: scope, index: 0, emitted: false)
    }

    private mutating func members(
        _ properties: [ToolValueSchema.Property],
        scope: Int,
        index: Int,
        emitted: Bool
    ) throws -> Fragment {
        let key = MemberKey(scope: scope, index: index, emitted: emitted)
        if let cached = memberMemo[key] { return cached }
        let result = Fragment(start: node(), end: node())
        memberMemo[key] = result
        guard index < properties.count else {
            epsilon(result.start, result.end)
            return result
        }
        let property = properties[index]
        var emittedParts: [Fragment] = []
        if emitted { emittedParts.append(literal(",")) }
        emittedParts.append(literal(property.name))
        emittedParts.append(literal(":"))
        emittedParts.append(try value(property.schema))
        emittedParts.append(
            try members(
                properties, scope: scope, index: index + 1, emitted: true))
        let include = sequence(emittedParts)
        epsilon(result.start, include.start)
        epsilon(include.end, result.end)
        if property.required {
            return result
        }
        let skip = try members(
            properties, scope: scope, index: index + 1, emitted: emitted)
        epsilon(result.start, skip.start)
        epsilon(skip.end, result.end)
        return result
    }

    private mutating func gemmaString(_ value: String) throws -> Fragment {
        let structuralMarkers = [
            "<|\"|>", "<escape>", "<|tool_call>", "<tool_call|>",
            "<start_function_call>", "<end_function_call>",
        ]
        guard !structuralMarkers.contains(where: value.contains) else {
            throw ToolConstraintSchemaError.unsupported(
                "string enum/const contains a Gemma parser delimiter")
        }
        return sequence([
            literal("<|\"|>"), literal(value), literal("<|\"|>"),
        ])
    }

    private mutating func integer() -> Fragment {
        let sign = optional(literal("-"))
        let zero = literal("0")
        let nonzero = sequence([
            one(ranges: [0x31 ... 0x39]),
            boundedRepetition(
                ranges: [0x30 ... 0x39], minimum: 0, maximum: 17),
        ])
        return sequence([sign, alternate([zero, nonzero])])
    }

    private mutating func number() -> Fragment {
        let sign = optional(literal("-"))
        let integral = alternate([
            literal("0"),
            sequence([
                one(ranges: [0x31 ... 0x39]),
                boundedRepetition(
                    ranges: [0x30 ... 0x39], minimum: 0, maximum: 17),
            ]),
        ])
        let fraction = optional(sequence([
            literal("."),
            boundedRepetition(
                ranges: [0x30 ... 0x39], minimum: 1, maximum: 18),
        ]))
        return sequence([sign, integral, fraction])
    }

    private mutating func array(
        items: ToolValueSchema,
        minItems: Int,
        maxItems: Int
    ) throws -> Fragment {
        let start = literal("[")
        let close = literal("]")
        let end = node()
        var current = start.end
        if minItems == 0 { epsilon(current, close.start) }
        for index in 0 ..< maxItems {
            if index > 0 {
                let comma = literal(",")
                epsilon(current, comma.start)
                current = comma.end
            }
            let item = try value(items)
            epsilon(current, item.start)
            current = item.end
            if index + 1 >= minItems { epsilon(current, close.start) }
        }
        epsilon(close.end, end)
        return .init(start: start.start, end: end)
    }

    private mutating func boundedRepetition(
        ranges: [ClosedRange<UInt8>],
        minimum: Int,
        maximum: Int
    ) -> Fragment {
        let start = node()
        let end = node()
        var current = start
        if minimum == 0 { epsilon(current, end) }
        guard maximum > 0 else { return .init(start: start, end: end) }
        for count in 1 ... maximum {
            let next = node()
            for range in ranges { edge(current, range, next) }
            current = next
            if count >= minimum { epsilon(current, end) }
        }
        return .init(start: start, end: end)
    }

    /// Repeating valid UTF-8 scalar bytes, excluding ASCII controls and `<`
    /// (reserved as the Gemma quote-marker opener).
    private mutating func utf8StringContent() -> Fragment {
        let start = node()
        let end = node()
        nodes[start].permissiveStringLoop = true
        epsilon(start, end)
        edge(start, 0x20 ... 0x3B, start)
        edge(start, 0x3D ... 0x7E, start)

        func path(
            _ builder: inout GemmaByteNFABuilder,
            _ ranges: [ClosedRange<UInt8>]
        ) {
            var current = start
            for (index, range) in ranges.enumerated() {
                let next = index == ranges.count - 1 ? start : builder.node()
                builder.edge(current, range, next)
                current = next
            }
        }
        path(&self, [0xC2 ... 0xDF, 0x80 ... 0xBF])
        path(&self, [0xE0 ... 0xE0, 0xA0 ... 0xBF, 0x80 ... 0xBF])
        path(&self, [0xE1 ... 0xEC, 0x80 ... 0xBF, 0x80 ... 0xBF])
        path(&self, [0xED ... 0xED, 0x80 ... 0x9F, 0x80 ... 0xBF])
        path(&self, [0xEE ... 0xEF, 0x80 ... 0xBF, 0x80 ... 0xBF])
        path(&self, [
            0xF0 ... 0xF0, 0x90 ... 0xBF, 0x80 ... 0xBF, 0x80 ... 0xBF,
        ])
        path(&self, [
            0xF1 ... 0xF3, 0x80 ... 0xBF, 0x80 ... 0xBF, 0x80 ... 0xBF,
        ])
        path(&self, [
            0xF4 ... 0xF4, 0x80 ... 0x8F, 0x80 ... 0xBF, 0x80 ... 0xBF,
        ])
        return .init(start: start, end: end)
    }

    private static func numberString(_ value: Double) -> String {
        if let integer = Int(exactly: value) {
            return String(integer)
        }
        return String(value)
    }

    mutating func build(
        tools: [CompiledToolSchema],
        allowsParallel: Bool
    ) throws -> GemmaByteNFA {
        let calls = try tools.map { tool -> Fragment in
            sequence([
                literal("<|tool_call>call:"),
                literal(tool.name),
                literal("{"),
                try topLevelArguments(tool.parameters),
                literal("}<tool_call|>"),
            ])
        }
        guard !calls.isEmpty else {
            throw ToolConstraintSchemaError.invalid(
                "tool grammar has no declared functions")
        }
        let call = alternate(calls)
        let start = node()
        let accept = node()
        epsilon(start, call.start)
        epsilon(call.end, accept)
        if allowsParallel {
            epsilon(accept, call.start)
        }
        return GemmaByteNFA(
            nodes: nodes,
            start: start,
            accepting: [accept],
            minBytesToAccept: Self.minimumByteDistances(nodes: nodes, accepting: [accept]))
    }

    private static func minimumByteDistances(
        nodes: [GemmaByteNFA.Node],
        accepting: Set<Int>
    ) -> [Int] {
        let infinity = Int.max / 4
        var distances = [Int](repeating: infinity, count: nodes.count)
        for state in accepting { distances[state] = 0 }
        var changed = true
        while changed {
            changed = false
            for state in nodes.indices.reversed() {
                var best = distances[state]
                for destination in nodes[state].epsilon {
                    best = min(best, distances[destination])
                }
                for edge in nodes[state].edges where distances[edge.destination] < infinity {
                    best = min(best, distances[edge.destination] + 1)
                }
                if best < distances[state] {
                    distances[state] = best
                    changed = true
                }
            }
        }
        return distances
    }
}
