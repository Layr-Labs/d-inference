import Foundation
import MLXLMCommon

/// The calls in a GLM tool suffix that does not parse as one batch.
///
/// The SDK's `GLM5ToolStream` withholds a response from its first
/// `<tool_call>` to EOS and parses that suffix as one call batch. On the legacy
/// text path the suffix also holds reasoning, so a `<tool_call>` the model only
/// mentioned or drafted in its thought, or one its answer mentions, fails the
/// batch. Reference GLM parsers (vLLM, SGLang) never fail a response on tool
/// syntax; here such a suffix is text too, under a stricter, provider-specific
/// rule for what is still a call: the trailing run of top-level frames,
/// separated only by whitespace and ending the response, from just after the
/// run's last frame that does not parse. Everything before them is text.
///
/// Only text the lexer can place outside every frame's arguments starts a
/// frame. A frame that has started its arguments must follow the SDK's grammar
/// to its own `</tool_call>`; one that does not, or is still open at the end,
/// owns the rest of the response, so a `<tool_call>` inside or after an
/// argument is never a call. A frame is never completed or salvaged.
enum GLM5ToolSuffix {
    /// `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the whole-suffix failure:
    /// an `auto` response whose suffix does not parse fails with a 500.
    static let environmentKey = "DARKBLOOM_GLM_TOOL_TEXT_FALLBACK"
    static let returnsUnparsedOutputAsTextByDefault =
        ProcessInfo.processInfo.environment[environmentKey] != "0"

    enum Split: Equatable {
        /// `text` precedes `calls`, which may be empty.
        case text(String, calls: [ToolCall])
        /// The text to release holds a think marker inside a tool frame, which
        /// the service's reasoning parser would read as a channel boundary.
        /// Such a suffix keeps failing, as before.
        case ambiguous
    }

    /// `truncated`: the token limit cut the output off; its suffix is text.
    static func split(_ suffix: String, tools: [[String: any Sendable]]?, truncated: Bool = false) -> Split {
        let bytes = Array(suffix.utf8)
        var lexer = Lexer(bytes: bytes, tools: tools)
        lexer.run()
        var start = bytes.count
        var calls: [ToolCall] = []
        if !truncated, lexer.unclosed == nil {
            // The run of whitespace-separated frames that ends the response.
            var run: [Range<Int>] = []
            var end = bytes.count
            for frame in lexer.frames.reversed() {
                guard Lexer.isWhitespace(bytes[frame.upperBound ..< end]) else { break }
                run.append(frame)
                end = frame.lowerBound
            }
            run.reverse()
            // Each frame parses on its own, so the starts that parse to the
            // end are exactly those after the run's last frame that does not.
            let parser = GLM5ToolCallParser()
            let first = run.lastIndex {
                parser.parse(content: String(decoding: bytes[$0], as: UTF8.self), tools: tools) == nil
            }.map { $0 + 1 } ?? 0
            if first < run.count {
                let parsed = parser.parseEOS(
                    String(decoding: bytes[run[first].lowerBound...], as: UTF8.self), tools: tools)
                // The SDK reads the same frames; anything else stays text.
                if parsed.count == run.count - first {
                    start = run[first].lowerBound
                    calls = parsed
                }
            }
        }
        // Decided on exactly the text that will be released.
        if lexer.holdsThinkMarker(before: start) { return .ambiguous }
        return calls.isEmpty
            ? .text(suffix, calls: []) : .text(String(decoding: bytes[..<start], as: UTF8.self), calls: calls)
    }

    /// Top-level GLM frames, read by the SDK parser's grammar: a name up to `<`,
    /// then `</tool_call>`, or `<arg_key>` pairs. A `<tool_call>` followed by
    /// anything but those or another frame tag is a mention and stays text. A
    /// string-typed value runs raw to `</arg_value>` (the template writes
    /// strings raw); any other value is JSON, structurally checked as the SDK
    /// reads it, so quoted delimiters are data. An argument whose declared type
    /// is unknown is JSON if it opens like JSON, raw otherwise.
    struct Lexer {
        let bytes: [UInt8]
        private let parameters: [String: [String: any Sendable]]
        /// Closed top-level frames, in order.
        private(set) var frames: [Range<Int>] = []
        /// Start of a frame whose arguments break the grammar or are still open
        /// at the end; it owns the rest of the response.
        private(set) var unclosed: Int?
        private var index = 0

        init(bytes: [UInt8], tools: [[String: any Sendable]]?) {
            self.bytes = bytes
            var parameters: [String: [String: any Sendable]] = [:]
            var duplicates: Set<String> = []
            for tool in tools ?? [] {
                let function = (tool["function"] as? [String: any Sendable]) ?? tool
                guard let name = function["name"] as? String else { continue }
                if parameters[name] != nil { duplicates.insert(name) }
                parameters[name] = (function["parameters"] as? [String: any Sendable]) ?? [:]
            }
            for name in duplicates { parameters[name] = nil }
            self.parameters = parameters
        }

        mutating func run() {
            while let start = find("<tool_call>", from: index) {
                guard let tag = find("<", from: start + 11) else { return }
                if starts("</tool_call>", at: tag) {
                    index = tag + 12
                    frames.append(start ..< index)
                } else if starts("<arg_key>", at: tag) {
                    let name = String(decoding: bytes[start + 11 ..< tag], as: UTF8.self)
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
                    guard let end = arguments(from: tag, name: name) else {
                        unclosed = start
                        return
                    }
                    index = end
                    frames.append(start ..< end)
                } else if ["</arg_key>", "<arg_value>", "</arg_value>"].contains(where: { starts($0, at: tag) }) {
                    // A frame's own tags out of order: a malformed frame, not a mention.
                    unclosed = start
                    return
                } else {
                    index = tag
                }
            }
        }

        /// Whether text released before `end` holds a think marker inside a frame.
        func holdsThinkMarker(before end: Int) -> Bool {
            frames.contains { $0.lowerBound < end && containsThinkMarker($0) }
                || unclosed.map { $0 < end && containsThinkMarker($0 ..< bytes.count) } == true
        }

        /// The end of the frame whose first `<arg_key>` is at `start`, read as
        /// the SDK reads it; nil when it breaks that grammar or is open at the end.
        private func arguments(from start: Int, name: String) -> Int? {
            var index = start
            while true {
                index = skipWhitespace(from: index)
                if starts("</tool_call>", at: index) { return index + 12 }
                guard starts("<arg_key>", at: index), let close = find("</arg_key>", from: index + 9),
                    close > index + 9, !bytes[index + 9 ..< close].contains(60)
                else { return nil }
                let key = String(decoding: bytes[index + 9 ..< close], as: UTF8.self)
                index = close + 10
                guard starts("<arg_value>", at: index) else { return nil }
                index += 11
                guard let raw = readsRaw(name: name, key: key, value: index) else { return nil }
                if raw {
                    guard let end = find("</arg_value>", from: index) else { return nil }
                    index = end + 12
                } else {
                    guard jsonValue(&index, depth: 0) else { return nil }
                    index = skipWhitespace(from: index)
                    guard starts("</arg_value>", at: index) else { return nil }
                    index += 12
                }
            }
        }

        /// The SDK reads a value raw only when its declared type is `string`
        /// (the declared key byte for byte, as the SDK matches it). A union of
        /// `string` with `object` or `array` could have been written either way,
        /// ending in different places: nil, the frame owns the rest. A union
        /// with bare literals ends where its raw reading does (the SDK refuses
        /// any union with `string`).
        private func readsRaw(name: String, key: String, value: Int) -> Bool? {
            if let parameters = parameters[name] {
                let properties = parameters["properties"] as? [String: any Sendable]
                let schema = properties?.first(where: { $0.key.utf8.elementsEqual(key.utf8) })?.value
                    ?? parameters["additionalProperties"]
                if let type = (schema as? [String: any Sendable])?["type"] {
                    if let type = type as? String { return type == "string" }
                    if let types = type as? [String], types.contains("string") {
                        return types.contains("object") || types.contains("array") ? nil : true
                    }
                    return false
                }
            }
            let first = skipWhitespace(from: value)
            return first >= bytes.count || ![34, 91, 123].contains(bytes[first])
        }

        /// One JSON value from `index`, structurally as the SDK's reader takes
        /// it (strings, objects, arrays, literals, number characters).
        private func jsonValue(_ index: inout Int, depth: Int) -> Bool {
            guard depth <= 64 else { return false }
            index = skipWhitespace(from: index)
            guard index < bytes.count else { return false }
            switch bytes[index] {
            case 34:
                return jsonString(&index)
            case 123:
                index = skipWhitespace(from: index + 1)
                if consume("}", &index) { return true }
                while true {
                    guard jsonString(&index) else { return false }
                    index = skipWhitespace(from: index)
                    guard consume(":", &index), jsonValue(&index, depth: depth + 1) else { return false }
                    index = skipWhitespace(from: index)
                    if consume("}", &index) { return true }
                    guard consume(",", &index) else { return false }
                    index = skipWhitespace(from: index)
                }
            case 91:
                index = skipWhitespace(from: index + 1)
                if consume("]", &index) { return true }
                while true {
                    guard jsonValue(&index, depth: depth + 1) else { return false }
                    index = skipWhitespace(from: index)
                    if consume("]", &index) { return true }
                    guard consume(",", &index) else { return false }
                }
            case 116: return consume("true", &index)
            case 102: return consume("false", &index)
            case 110: return consume("null", &index)
            default:
                let start = index
                while index < bytes.count, Self.isNumberByte(bytes[index]) { index += 1 }
                return index > start
            }
        }

        private func jsonString(_ index: inout Int) -> Bool {
            guard index < bytes.count, bytes[index] == 34 else { return false }
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte < 32 { return false }
                if byte == 34 { return true }
                if byte == 92 { index += 1 }
            }
            return false
        }

        private func containsThinkMarker(_ range: Range<Int>) -> Bool {
            var index = range.lowerBound
            while let tag = find("<", from: index), tag < range.upperBound {
                if starts("<think>", at: tag) || starts("</think>", at: tag) { return true }
                index = tag + 1
            }
            return false
        }

        private func consume(_ literal: String, _ index: inout Int) -> Bool {
            guard starts(literal, at: index) else { return false }
            index += literal.utf8.count
            return true
        }

        private func skipWhitespace(from start: Int) -> Int {
            var index = start
            while index < bytes.count, Self.isWhitespaceByte(bytes[index]) { index += 1 }
            return index
        }

        private func find(_ literal: String, from start: Int) -> Int? {
            let marker = Array(literal.utf8)
            var index = start
            while index + marker.count <= bytes.count {
                if bytes[index] == marker[0], starts(literal, at: index) { return index }
                index += 1
            }
            return nil
        }

        private func starts(_ literal: String, at index: Int) -> Bool {
            let marker = literal.utf8
            return index + marker.count <= bytes.count && bytes[index ..< index + marker.count].elementsEqual(marker)
        }

        static func isWhitespace(_ bytes: ArraySlice<UInt8>) -> Bool {
            bytes.allSatisfy(isWhitespaceByte)
        }

        private static func isWhitespaceByte(_ byte: UInt8) -> Bool {
            byte == 9 || byte == 10 || byte == 13 || byte == 32
        }

        /// The bytes the SDK's JSON number reader takes: digits, `+ - . E e`.
        private static func isNumberByte(_ byte: UInt8) -> Bool {
            (48 ... 57).contains(byte) || byte == 43 || byte == 45 || byte == 46 || byte == 69 || byte == 101
        }
    }
}
