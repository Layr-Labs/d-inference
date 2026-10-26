// Copyright © 2026 Eigen Labs.

import Foundation

/// Framing state only. No argument value or reasoning text is accumulated.
/// Argument JSON boundary rules deliberately match MLXLMCommon's
/// FlintArgumentValueScanner; semantic JSON/schema validation stays downstream.
/// A response format instead constrains content with FlintJSONState.
struct FlintNativeProtocolBoundary: Hashable {
    enum Phase: Hashable {
        case initial, content, reasoning, name, nameSpace, arguments, key, keyEnd, valueStart, value, afterCall
    }
    enum Value: Hashable { case undecided, raw, scalar, structured }
    var phase = Phase.initial
    var marker: [UInt8] = []
    var name = ""
    var key: [UInt8] = []
    var rawValue = false
    var value = Value.undecided
    var depth = 0
    var quoted = false
    var escaped = false
    var leadingUTF8: [UInt8] = []
    var json: FlintJSONState?

    static let maxKeyBytes = 1024
    static let maxJSONDepth = 128
    static let think = Array("<think>".utf8)
    static let thinkEnd = Array("</think>".utf8)
    static let call = Array("<tool_call>".utf8)
    static let callEnd = Array("</tool_call>".utf8)
    static let keyStart = Array("<arg_key>".utf8)
    static let keyEnd = Array("</arg_key>".utf8)
    static let valueStart = Array("<arg_value>".utf8)
    static let valueEnd = Array("</arg_value>".utf8)
    static let protocolMarkers = FlintNativeVocabulary.markers.map { Array($0.0.utf8) }
    // rec excludes three stop spellings inside reasoning. The loaded provider
    // artifact also stops on developer, so the native machine excludes four.
    static let reasoningMarkers = [thinkEnd] +
        ["<|end_of_text|>", "<|user|>", "<|observation|>", "<|developer|>"].map { Array($0.utf8) }

    struct Rules {
        let requiresCall: Bool
        let allowsParallel: Bool
        let names: Set<String>
        let rawKeys: [String: Set<String>]
        /// Response-format content grammar; no call frame is then allowed.
        let json: FlintJSONGrammar?
    }

    func canStop(_ id: Int, vocabulary: FlintNativeVocabulary, rules: Rules) -> Bool {
        // In ordinary text, an unfinished marker prefix is literal content.
        // Only a complete opening moves us into a frame that must close.
        if phase == .initial || phase == .content {
            if let grammar = rules.json {
                return jsonContentComplete(grammar) && vocabulary.answerStops.contains(id)
            }
            return !rules.requiresCall && vocabulary.answerStops.contains(id)
        }
        guard marker.isEmpty else { return false }
        if phase == .afterCall { return id == vocabulary.observationStop }
        return false
    }

    /// In these states only a marker completion can reject a token. Structured
    /// JSON additionally needs quote/escape/depth checks, including whole-piece
    /// text following a close. Other boundaries use first-byte buckets.
    func broadCandidates(_ vocabulary: FlintNativeVocabulary, rules: Rules) -> [Int]? {
        switch phase {
        case .reasoning: return vocabulary.markerCompleters
        case .initial, .content:
            if rules.json != nil { return json?.inStringBody == true ? vocabulary.jsonStringSensitive : nil }
            return rules.requiresCall ? nil : vocabulary.markerCompleters
        case .value:
            return value == .raw || value == .scalar ? vocabulary.markerCompleters : vocabulary.jsonSensitive
        case .key: return vocabulary.keySensitive(remainingBytes: Self.maxKeyBytes - key.count)
        default: return nil
        }
    }

    func firstBytes(rules: Rules) -> Set<UInt8>? {
        switch phase {
        case .initial, .content, .afterCall, .arguments, .nameSpace:
            // Framing whitespace is ASCII, as in the complete-frame parser.
            return marker.isEmpty ? [9, 10, 13, 32, 60] : nextMarkerBytes(rules: rules)
        case .name:
            var bytes: Set<UInt8> = name.isEmpty ? [9, 10, 13, 32] : []
            for candidate in rules.names where candidate.hasPrefix(name) {
                let suffix = candidate.utf8.dropFirst(name.utf8.count)
                if let first = suffix.first { bytes.insert(first) }
                else { bytes.formUnion([9, 10, 13, 32, 60]) }
            }
            return bytes
        case .keyEnd: return [Self.keyEnd[marker.count]]
        case .valueStart: return [Self.valueStart[marker.count]]
        case .key: return nil
        case .reasoning, .value: return nil
        }
    }

    private func nextMarkerBytes(rules: Rules) -> Set<UInt8> {
        Set(openings(rules: rules).compactMap { candidate in
            candidate.starts(with: marker) && candidate.count > marker.count ? candidate[marker.count] : nil
        })
    }

    private func openings(rules: Rules) -> [[UInt8]] {
        switch phase {
        case .arguments, .nameSpace: return [Self.keyStart, Self.callEnd]
        case .afterCall: return rules.allowsParallel && !rules.names.isEmpty ? [Self.call] : []
        case .initial: return [Self.think] + (rules.names.isEmpty ? [] : [Self.call])
        default: return rules.names.isEmpty ? [] : [Self.call]
        }
    }

    mutating func consume(_ bytes: [UInt8], rules: Rules) -> Bool {
        for byte in bytes {
            guard consume(byte, rules: rules) else { return false }
        }
        return true
    }

    mutating func consume(_ byte: UInt8, rules: Rules) -> Bool {
        switch phase {
        case .reasoning:
            if let match = scan(byte, candidates: Self.reasoningMarkers) {
                guard match == Self.thinkEnd else { return false }
                phase = .content
                if let grammar = rules.json { json = FlintJSONState(grammar: grammar) }
            }
            return true
        case .initial, .content:
            if let grammar = rules.json { return consumeJSONContent(byte, grammar: grammar) }
            if rules.requiresCall { return consumeOpening(byte, rules: rules) }
            // Displaced marker-prefix bytes are ordinary content. Whitespace
            // before an optional opening thought does not disable that channel.
            marker.append(byte)
            while !marker.isEmpty && !Self.protocolMarkers.contains(where: { $0.starts(with: marker) }) {
                let released = marker.removeFirst()
                if !Self.whitespace(released) { phase = .content }
            }
            guard let match = Self.protocolMarkers.first(where: { $0 == marker }) else { return true }
            marker = []
            if match == Self.think && phase == .initial { phase = .reasoning; return true }
            if match == Self.call && !rules.names.isEmpty { phase = .name; return true }
            return false
        case .afterCall, .arguments, .nameSpace:
            return consumeOpening(byte, rules: rules)
        case .name:
            if Self.whitespace(byte) {
                if name.isEmpty { return true }
                guard rules.names.contains(name) else { return false }
                phase = .nameSpace
                return true
            }
            if byte == 60 {
                guard rules.names.contains(name) else { return false }
                phase = .arguments
                return consumeOpening(byte, rules: rules)
            }
            guard byte < 128, name.utf8.count < 64 else { return false }
            name.append(Character(Unicode.Scalar(byte)))
            return rules.names.contains { $0.hasPrefix(name) }
        case .key:
            if byte == 60 {
                guard !key.isEmpty else { return false }
                // String equality retains the parser's Unicode-equivalent key
                // lookup; a lossy ASCII projection must not select raw mode.
                rawValue = rules.rawKeys[name]?.contains(String(decoding: key, as: UTF8.self)) == true
                key = []
                phase = .keyEnd
                marker = [byte]
                return true
            }
            guard key.count < Self.maxKeyBytes else { return false }
            key.append(byte)
            return true
        case .keyEnd:
            guard appendLiteral(byte, literal: Self.keyEnd) else { return false }
            if marker.isEmpty { phase = .valueStart }
            return true
        case .valueStart:
            guard appendLiteral(byte, literal: Self.valueStart) else { return false }
            if marker.isEmpty {
                phase = .value
                value = rawValue ? .raw : .undecided
                rawValue = false
            }
            return true
        case .value:
            return consumeValue(byte)
        }
    }

    private mutating func consumeOpening(_ byte: UInt8, rules: Rules) -> Bool {
        if marker.isEmpty && Self.whitespace(byte) { return true }
        marker.append(byte)
        let candidates = openings(rules: rules)
        guard candidates.contains(where: { $0.starts(with: marker) }) else { return false }
        guard let match = candidates.first(where: { $0 == marker }) else { return true }
        marker = []
        if match == Self.think { phase = .reasoning }
        else if match == Self.call { phase = .name }
        else if match == Self.keyStart { phase = .key }
        else {
            phase = .afterCall
            name = ""
        }
        return true
    }

    private mutating func consumeValue(_ byte: UInt8) -> Bool {
        if value == .undecided {
            if !leadingUTF8.isEmpty || byte >= 128 {
                if !leadingUTF8.isEmpty && !(0x80...0xBF).contains(byte) {
                    leadingUTF8 = []
                    value = .scalar
                    return consumeValue(byte)
                }
                if leadingUTF8.isEmpty && !(0xC2...0xF4).contains(byte) {
                    value = .scalar
                    return true
                }
                leadingUTF8.append(byte)
                let first = leadingUTF8[0]
                let count = first < 0xE0 ? 2 : (first < 0xF0 ? 3 : 4)
                if leadingUTF8.count < count { return true }
                let text = String(decoding: leadingUTF8, as: UTF8.self)
                leadingUTF8 = []
                if text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) { return true }
                value = .scalar
                return true
            }
            if Unicode.Scalar(byte).properties.isWhitespace { return true }
            value = byte == 123 || byte == 91 ? .structured : .scalar
        }
        if value == .structured {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
                return true
            }
            if byte == 34 { quoted = true; return true }
            if byte == 123 || byte == 91 {
                guard depth < Self.maxJSONDepth else { return false }
                depth += 1
            }
            if byte == 125 || byte == 93 {
                guard depth > 0 else { return false }
                depth -= 1
            }
            if depth != 0 { return true }
        }
        if scan(byte, candidates: [Self.valueEnd]) != nil {
            phase = .arguments
            value = .undecided
            depth = 0
            quoted = false
            escaped = false
            leadingUTF8 = []
        }
        return true
    }

    private mutating func appendLiteral(_ byte: UInt8, literal: [UInt8]) -> Bool {
        guard marker.count < literal.count, byte == literal[marker.count] else { return false }
        marker.append(byte)
        if marker.count == literal.count { marker = [] }
        return true
    }

    private mutating func scan(_ byte: UInt8, candidates: [[UInt8]]) -> [UInt8]? {
        marker.append(byte)
        while !marker.isEmpty && !candidates.contains(where: { $0.starts(with: marker) }) {
            marker.removeFirst()
        }
        if let match = candidates.first(where: { $0 == marker }) { marker = []; return match }
        return nil
    }

    private static func whitespace(_ byte: UInt8) -> Bool { [9, 10, 13, 32].contains(byte) }
}
