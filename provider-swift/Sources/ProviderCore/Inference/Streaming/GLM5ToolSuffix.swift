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
/// separated only by whitespace and ending the response, when every frame of
/// it parses. Everything before them is text.
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
            var head = lexer.frames.endIndex
            var from = bytes.count
            while head > 0, Lexer.isWhitespace(bytes[lexer.frames[head - 1].upperBound ..< from]) {
                head -= 1
                from = lexer.frames[head].lowerBound
            }
            let run = head ..< lexer.frames.endIndex
            // The run is the response's call batch: like the SDK, take all of
            // it or none, so a member the SDK refuses runs no other member.
            if !run.isEmpty, run.allSatisfy({ lexer.verdicts[$0] ?? lexer.accepts(lexer.frames[$0]) }) {
                let parsed = GLM5ToolCallParser().parseEOS(
                    String(decoding: bytes[from...], as: UTF8.self), tools: tools)
                // The SDK reads the same frames; anything else stays text.
                if parsed.count == run.count {
                    start = from
                    calls = parsed
                }
            }
        }
        // Decided on exactly the text that will be released.
        if lexer.holdsThinkMarker(before: start) { return .ambiguous }
        return calls.isEmpty
            ? .text(suffix, calls: []) : .text(String(decoding: bytes[..<start], as: UTF8.self), calls: calls)
    }

    /// `suffix` without the frames that end an output the token limit cut:
    /// from the frame that owns the rest (`Lexer.unclosed`: open at the end,
    /// or broken), or from a header the end cut (`Lexer.cutHeader`), or from
    /// the end, back over the closed frames separated from it only by
    /// whitespace. Such frames are never published as text
    /// (`TokenLimitCutPolicy`), and a suffix is not split into calls at a cut
    /// (`split(truncated:)`), so they are dropped. Mentions, frames followed
    /// by text, and the text before them stay.
    static func droppingCutFrames(_ suffix: String, tools: [[String: any Sendable]]?) -> String {
        let bytes = Array(suffix.utf8)
        var lexer = Lexer(bytes: bytes, tools: tools)
        lexer.run()
        var start = lexer.unclosed ?? lexer.cutHeader ?? bytes.count
        var head = lexer.frames.endIndex
        while head > 0, lexer.frames[head - 1].upperBound <= start,
            Lexer.isWhitespace(bytes[lexer.frames[head - 1].upperBound ..< start])
        {
            head -= 1
            start = lexer.frames[head].lowerBound
        }
        return String(decoding: bytes[..<start], as: UTF8.self)
    }

    /// Top-level GLM frames, read by the SDK parser's grammar: a name up to `<`,
    /// then `</tool_call>`, or `<arg_key>` pairs. A `<tool_call>` followed by
    /// anything else is a mention and stays text, unless a frame's own tags
    /// follow it before the next `<tool_call>`, or the response ends in it
    /// after the start of a declared name (`cutHeader`). A string-typed value runs raw
    /// to `</arg_value>` (the template writes strings raw) and may not hold the
    /// frame tags the SDK refuses there; any other value is JSON, structurally
    /// checked as the SDK reads it, so quoted delimiters are data. An argument
    /// whose declared type is unknown is JSON if it opens like JSON, raw
    /// otherwise. Where the SDK accepts a frame, this is its own reading; a
    /// frame it refuses keeps its boundary only when no other reading could
    /// move it.
    struct Lexer {
        let bytes: [UInt8]
        /// Each declaration the SDK's parser accepts, by name, and its schema.
        private let declarations: [String: [String: any Sendable]]
        private let parameters: [String: [String: any Sendable]]
        /// Closed top-level frames, in order.
        private(set) var frames: [Range<Int>] = []
        /// Whether the SDK's parser accepts each frame on its own, where that
        /// was needed while lexing (a frame with a `"`); nil: not asked yet.
        private(set) var verdicts: [Bool?] = []
        /// Start of a frame whose arguments break the grammar, are still open
        /// at the end or end where another reading would not; it owns the
        /// rest of the response. For a frame's tag in top-level text, the
        /// first frame or mention before it, or the tag.
        private(set) var unclosed: Int?
        /// A `<tool_call>` the response ends in, in its name or a cut-off
        /// first tag, after the start of a declared name (or none yet): the
        /// header of a frame the end cut, not a mention.
        private(set) var cutHeader: Int?
        /// The first `<tool_call>` read as a mention.
        private var firstMention: Int?
        private var index = 0

        init(bytes: [UInt8], tools: [[String: any Sendable]]?) {
            self.bytes = bytes
            // Only a declaration the SDK's parser accepts types arguments: one
            // per name, an object schema without indirect types. A `function`
            // that is not an object makes it refuse every name.
            var declarations: [String: [String: any Sendable]] = [:]
            var parameters: [String: [String: any Sendable]] = [:]
            var seen: Set<String> = []
            var duplicates: Set<String> = []
            for tool in tools ?? [] {
                let function: [String: any Sendable]
                if let wrapped = tool["function"] {
                    guard let object = wrapped as? [String: any Sendable] else {
                        declarations = [:]
                        parameters = [:]
                        break
                    }
                    function = object
                } else {
                    function = tool
                }
                guard let name = function["name"] as? String else { continue }
                if !seen.insert(name).inserted { duplicates.insert(name) }
                let schema: [String: any Sendable]
                if let declared = function["parameters"] {
                    guard let object = declared as? [String: any Sendable],
                        object["type"] == nil || object["type"] as? String == "object",
                        !Self.hasIndirectType(object),
                        object["properties"].map({ $0 is [String: any Sendable] }) ?? true
                    else { continue }
                    schema = object
                } else {
                    schema = [:]
                }
                declarations[name] = tool
                parameters[name] = schema
            }
            for name in duplicates {
                declarations[name] = nil
                parameters[name] = nil
            }
            self.declarations = declarations
            self.parameters = parameters
        }

        mutating func run() {
            while true {
                let next = find("<tool_call>", from: index)
                // A frame's tag in top-level text belongs to no frame: what
                // follows it may be that frame's arguments, and a header read
                // as a mention before it, or a closed frame whose raw value
                // runs on through it, may be that frame's. Own from the first.
                if let stray = first(of: Self.frameTags, in: index ..< (next ?? bytes.count)) {
                    unclosed = min(stray, firstMention ?? stray, frames.first?.lowerBound ?? stray)
                    return
                }
                guard let start = next else { return }
                guard let tag = find("<", from: start + 11) else {
                    if beginsDeclaredName(frameName(start ..< bytes.count)) { cutHeader = start }
                    return
                }
                if starts("</tool_call>", at: tag) {
                    index = tag + 12
                    guard record(start ..< index) else { return }
                } else if starts("<arg_key>", at: tag) {
                    let name = frameName(start ..< tag)
                    let declared = Self.isFunctionName(name) ? parameters[name] : nil
                    guard let end = arguments(from: tag, parameters: declared) else {
                        unclosed = start
                        return
                    }
                    index = end
                    guard record(start ..< end) else { return }
                } else {
                    // Anything else after the name is a mention, unless a
                    // frame's own tags follow before the next `<tool_call>`:
                    // then it is a malformed frame, which owns the rest.
                    let following = find("<tool_call>", from: tag) ?? bytes.count
                    if holdsAny(Self.frameTags, in: tag ..< following) {
                        unclosed = start
                        return
                    }
                    if endsInFrameTag(at: tag), beginsDeclaredName(frameName(start ..< tag)) {
                        cutHeader = start
                        return
                    }
                    firstMention = firstMention ?? start
                    index = following
                }
            }
        }

        /// Records a closed frame. A frame the SDK refuses keeps its boundary
        /// only without a `"`: one may open a JSON string that a raw reading
        /// ends inside, or end a raw string that a JSON reading runs past. Only
        /// such a frame is checked here; false when it owns the rest.
        private mutating func record(_ frame: Range<Int>) -> Bool {
            guard bytes[frame].contains(34) else {
                frames.append(frame)
                verdicts.append(nil)
                return true
            }
            guard accepts(frame) else {
                unclosed = frame.lowerBound
                return false
            }
            frames.append(frame)
            verdicts.append(true)
            return true
        }

        /// Whether the SDK's parser accepts `frame` on its own. A name it
        /// would refuse before reading arguments is refused without asking it;
        /// otherwise it is asked with that name's one declaration, which it
        /// resolves the same way as from the whole list, without scanning it.
        func accepts(_ frame: Range<Int>) -> Bool {
            guard let tag = find("<", from: frame.lowerBound + 11) else { return false }
            let name = frameName(frame.lowerBound ..< tag)
            guard Self.isFunctionName(name), let declaration = declarations[name] else { return false }
            return GLM5ToolCallParser().parse(
                content: String(decoding: bytes[frame], as: UTF8.self), tools: [declaration]) != nil
        }

        /// The name of the frame opening at `header.lowerBound`, up to its first `<`.
        private func frameName(_ header: Range<Int>) -> String {
            String(decoding: bytes[header.lowerBound + 11 ..< header.upperBound], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        }

        /// What follows a `<tool_call>` the response ends in: nothing yet, or
        /// the start of a declared function's name.
        private func beginsDeclaredName(_ name: String) -> Bool {
            name.isEmpty || declarations.keys.contains { $0.hasPrefix(name) }
        }

        /// The response ends inside the tag at `tag`, which would have opened
        /// the frame's arguments or closed it.
        private func endsInFrameTag(at tag: Int) -> Bool {
            let rest = bytes[tag...]
            return ["<arg_key>", "</tool_call>"].contains { $0.utf8.count > rest.count && $0.utf8.starts(with: rest) }
        }

        /// The tags of a frame after its `<tool_call>`.
        private static let frameTags = ["</tool_call>", "<arg_key>", "</arg_key>", "<arg_value>", "</arg_value>"]
        /// The tags the SDK refuses inside a raw value.
        private static let rawValueCollisions = ["<tool_call>", "</tool_call>", "<arg_key>", "</arg_key>", "<arg_value>"]

        /// Whether text released before `end` holds a think marker inside a frame.
        func holdsThinkMarker(before end: Int) -> Bool {
            frames.contains { $0.lowerBound < end && containsThinkMarker($0) }
                || unclosed.map { $0 < end && containsThinkMarker($0 ..< bytes.count) } == true
        }

        /// The end of the frame whose first `<arg_key>` is at `start`, read as
        /// the SDK reads it; nil when it breaks that grammar or is open at the end.
        private func arguments(from start: Int, parameters: [String: any Sendable]?) -> Int? {
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
                guard let raw = readsRaw(parameters: parameters, key: key, value: index) else { return nil }
                if raw {
                    // A raw value holding frame tags is refused by the SDK; its
                    // `</arg_value>` may be a nested frame's.
                    guard let end = find("</arg_value>", from: index),
                        !holdsAny(Self.rawValueCollisions, in: index ..< end)
                    else { return nil }
                    index = end + 12
                } else {
                    guard jsonValue(&index, depth: 0) else { return nil }
                    index = skipWhitespace(from: index)
                    guard starts("</arg_value>", at: index) else { return nil }
                    index += 12
                }
            }
        }

        /// The SDK reads a value raw only when its declared type is `string`.
        /// It takes the type of a declared key only from the key as declared,
        /// byte for byte, and refuses one that only canonically equals it (nil:
        /// the frame owns the rest); an undeclared key takes
        /// `additionalProperties`. A union of `string` with `object` or `array`
        /// could have been written either way, ending in different places: nil
        /// too. A union with bare literals ends where its raw reading does (the
        /// SDK refuses any union with `string`). Without a type the SDK accepts,
        /// a value that opens like JSON is read as JSON, which never ends before
        /// its raw reading would; any other value is raw (a JSON literal has no
        /// delimiters to end early on).
        private func readsRaw(parameters: [String: any Sendable]?, key: String, value: Int) -> Bool? {
            if let parameters {
                let schema: (any Sendable)?
                if let properties = parameters["properties"] as? [String: any Sendable],
                    let declared = properties.index(forKey: key)
                {
                    guard properties[declared].key.utf8.elementsEqual(key.utf8) else { return nil }
                    schema = properties[declared].value
                } else {
                    schema = parameters["additionalProperties"]
                }
                if let schema = schema as? [String: any Sendable], !Self.hasIndirectType(schema),
                    let type = schema["type"]
                {
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
            holdsAny(["<think>", "</think>"], in: range)
        }

        private func holdsAny(_ tags: [String], in range: Range<Int>) -> Bool {
            first(of: tags, in: range) != nil
        }

        /// Where one of `tags` (each opening with `<`) first starts in `range`.
        private func first(of tags: [String], in range: Range<Int>) -> Int? {
            var index = range.lowerBound
            while index < range.upperBound {
                if bytes[index] == 60, tags.contains(where: { starts($0, at: index) }) { return index }
                index += 1
            }
            return nil
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

        /// The SDK's function-name rule: 1-64 ASCII letters, digits, `-`, `_`.
        private static func isFunctionName(_ name: String) -> Bool {
            (1 ... 64).contains(name.utf8.count) && name.utf8.allSatisfy {
                (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
            }
        }

        private static func hasIndirectType(_ schema: [String: any Sendable]) -> Bool {
            ["$ref", "$dynamicRef", "anyOf", "oneOf", "allOf", "not", "if", "then", "else"].contains { schema[$0] != nil }
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
