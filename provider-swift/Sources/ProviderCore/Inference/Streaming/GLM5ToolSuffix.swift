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
/// rule for what is still a call: a frame of the trailing run of top-level
/// frames, separated only by whitespace and ending the response, that parses
/// on its own. Everything before the run, and each frame of it that does not
/// parse, is text.
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
        /// The text, then the calls, which may be empty. The text is what
        /// precedes the calls, followed by the frames among them that do not
        /// parse.
        case text(String, calls: [ToolCall])
        /// The text to release holds a think marker inside a tool frame, which
        /// the service's reasoning parser would read as a channel boundary.
        /// Such a suffix keeps failing, as before.
        case ambiguous
    }

    /// `truncated`: the token limit cut the output off; its suffix is text.
    /// `grammarOnly` false (`DARKBLOOM_GRAMMAR_ONLY_TOOL_PARSING=0`) restores
    /// 0.10.13's rule with the parser's schema refusals: the run is taken
    /// whole or not at all.
    static func split(_ suffix: String, tools: [[String: any Sendable]]?, truncated: Bool = false,
                      grammarOnly: Bool = GrammarOnlyToolParsing.isEnabled) -> Split {
        let bytes = Array(suffix.utf8)
        var lexer = Lexer(bytes: bytes, tools: tools, grammarOnly: grammarOnly)
        lexer.run()
        // Start of the run of whitespace-separated frames that ends the response.
        var runStart = bytes.count
        var calls: [ToolCall] = []
        var refused: [Range<Int>] = []
        if !truncated, lexer.unclosed == nil {
            var head = lexer.frames.endIndex
            while head > 0, Lexer.isWhitespace(bytes[lexer.frames[head - 1].upperBound ..< runStart]) {
                head -= 1
                runStart = lexer.frames[head].lowerBound
            }
            // Decided call by call: a frame the SDK refuses is text and keeps
            // none of the others from being calls.
            for frame in head ..< lexer.frames.endIndex {
                if let call = lexer.call(frame) { calls.append(call) } else { refused.append(lexer.frames[frame]) }
            }
            if !grammarOnly, !refused.isEmpty { calls = [] }
        }
        // Decided on exactly the text that will be released.
        guard !calls.isEmpty else {
            return lexer.holdsThinkMarker(before: bytes.count) ? .ambiguous : .text(suffix, calls: [])
        }
        if lexer.holdsThinkMarker(before: runStart) || refused.contains(where: lexer.containsThinkMarker) {
            return .ambiguous
        }
        let text = refused.reduce(into: Array(bytes[..<runStart])) { $0 += bytes[$1] }
        return .text(String(decoding: text, as: UTF8.self), calls: calls)
    }

    /// The text an output the token limit cut releases, when the cut ends it
    /// as `length` (`TokenLimitCutPolicy`): it is not split into calls, as in
    /// `split(truncated:)`, and the frames that end it are dropped, never
    /// published as text: from the frame that owns the rest (`Lexer.unclosed`:
    /// open at the end or broken, or from the first frame or mention before a
    /// frame's tag in top-level text), or from a header the end cut
    /// (`Lexer.cutHeader`), or from the end, back over the closed frames
    /// separated from it only by whitespace. Mentions, frames followed by
    /// text, and the text before them stay. Nil when that text would still
    /// put a think marker from inside a frame before the reasoning parser:
    /// the whole suffix is then dropped. Decided on exactly the text released.
    static func textAtCut(_ suffix: String, tools: [[String: any Sendable]]?) -> String? {
        let bytes = Array(suffix.utf8)
        var lexer = Lexer(bytes: bytes, tools: tools, grammarOnly: GrammarOnlyToolParsing.isEnabled)
        lexer.run()
        var start = lexer.unclosed ?? lexer.cutHeader ?? bytes.count
        var head = lexer.frames.endIndex
        while head > 0, lexer.frames[head - 1].upperBound <= start,
            Lexer.isWhitespace(bytes[lexer.frames[head - 1].upperBound ..< start])
        {
            head -= 1
            start = lexer.frames[head].lowerBound
        }
        if lexer.holdsThinkMarker(before: start) { return nil }
        return String(decoding: bytes[..<start], as: UTF8.self)
    }

    /// The closed frames that end a thought that never closed (whitespace
    /// only between and after them), from the first after which every one
    /// parses on its own: GLM calling from inside its thought. Nil when there
    /// are none, or when a frame is still open or broken at the end.
    static func trailingCalls(in thought: String, tools: [[String: any Sendable]]?) -> String? {
        let bytes = Array(thought.utf8)
        var lexer = Lexer(bytes: bytes, tools: tools, grammarOnly: GrammarOnlyToolParsing.isEnabled)
        lexer.run()
        guard lexer.unclosed == nil, lexer.cutHeader == nil else { return nil }
        var runStart = bytes.count
        var head = lexer.frames.endIndex
        while head > 0, Lexer.isWhitespace(bytes[lexer.frames[head - 1].upperBound ..< runStart]) {
            head -= 1
            runStart = lexer.frames[head].lowerBound
        }
        var first = lexer.frames.endIndex
        while first > head, lexer.call(first - 1) != nil { first -= 1 }
        guard first < lexer.frames.endIndex else { return nil }
        return String(decoding: bytes[lexer.frames[first].lowerBound...], as: UTF8.self)
    }

    /// Top-level GLM frames, read by the SDK parser's grammar: a name up to `<`,
    /// then `</tool_call>`, or `<arg_key>` pairs. A `<tool_call>` followed by
    /// anything else is a mention and stays text, unless a frame's own tags
    /// follow it before the next `<tool_call>`, or the response ends in it
    /// after the start of a declared name (`cutHeader`). A value runs raw to
    /// `</arg_value>` (the template writes strings raw) and may not hold the
    /// frame tags the SDK refuses there, unless a type other than `string` is
    /// declared for it and it opens a JSON value, structurally checked as the
    /// SDK reads it, that `</arg_value>` follows: quoted delimiters in it are
    /// data. Where the SDK accepts a frame, this is its own reading; a frame it
    /// refuses keeps its boundary only when no other reading could move it.
    struct Lexer {
        let bytes: [UInt8]
        /// Each declaration the SDK's parser accepts, by name, and its schema.
        private let declarations: [String: [String: any Sendable]]
        private let parameters: [String: [String: any Sendable]]
        /// Closed top-level frames, in order.
        private(set) var frames: [Range<Int>] = []
        /// The call the SDK's parser reads from each frame on its own, where
        /// that was needed while lexing (a frame with a `"`); nil: not asked yet.
        private var checkedCalls: [ToolCall?] = []
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
        /// Every function name the request declares, whether or not the SDK
        /// accepts its declaration: what a header the end cut may be the start of.
        private let declaredNames: [String]
        private let parser: GLM5ToolCallParser
        /// False: the SDK checks schemas (`GrammarOnlyToolParsing` off), and
        /// values are read as 0.10.13 read them.
        private let grammarOnly: Bool
        private var index = 0

        init(bytes: [UInt8], tools: [[String: any Sendable]]?, grammarOnly: Bool) {
            self.bytes = bytes
            self.grammarOnly = grammarOnly
            parser = GLM5ToolCallParser(grammarOnly: grammarOnly)
            declaredNames = (tools ?? []).compactMap { (($0["function"] as? [String: any Sendable]) ?? $0)["name"] as? String }
            // The SDK's parser accepts one declaration per name, whose
            // parameter object only types arguments. A `function` that is not
            // an object makes it refuse every name.
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
                var schema: [String: any Sendable] = [:]
                if let declared = function["parameters"] {
                    let object = declared as? [String: any Sendable]
                    // Checking schemas, the SDK refuses every call of a
                    // declaration whose parameters are not a plain object schema.
                    if !grammarOnly, !(object.map(Self.isPlainObjectSchema) ?? false) { continue }
                    schema = object ?? [:]
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
                checkedCalls.append(nil)
                return true
            }
            guard let call = call(in: frame) else {
                unclosed = frame.lowerBound
                return false
            }
            frames.append(frame)
            checkedCalls.append(call)
            return true
        }

        /// The call the SDK's parser reads from `frames[index]` on its own, or
        /// nil when it refuses that frame.
        func call(_ index: Int) -> ToolCall? {
            checkedCalls[index] ?? call(in: frames[index])
        }

        /// A name the SDK's parser would refuse before reading arguments is
        /// refused without asking it; otherwise it is asked with that name's
        /// one declaration, which it resolves the same way as from the whole
        /// list, without scanning it.
        private func call(in frame: Range<Int>) -> ToolCall? {
            guard let tag = find("<", from: frame.lowerBound + 11) else { return nil }
            let name = frameName(frame.lowerBound ..< tag)
            guard Self.isFunctionName(name), let declaration = declarations[name] else { return nil }
            return parser.parse(content: String(decoding: bytes[frame], as: UTF8.self), tools: [declaration])
        }

        /// The name of the frame opening at `header.lowerBound`, up to its first `<`.
        private func frameName(_ header: Range<Int>) -> String {
            String(decoding: bytes[header.lowerBound + 11 ..< header.upperBound], as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        }

        /// What follows a `<tool_call>` the response ends in: nothing yet, or
        /// the start of a declared function's name.
        private func beginsDeclaredName(_ name: String) -> Bool {
            name.isEmpty || declaredNames.contains { $0.hasPrefix(name) }
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
                if grammarOnly {
                    if readsJSONFirst(key, parameters: parameters, value: index), let end = jsonValueEnd(from: index) {
                        index = end
                        continue
                    }
                } else {
                    guard let raw = readsRawCheckingSchemas(parameters: parameters, key: key, value: index)
                    else { return nil }
                    if !raw {
                        guard let end = jsonValueEnd(from: index) else { return nil }
                        index = end
                        continue
                    }
                }
                // A raw value holding frame tags is refused by the SDK; its
                // `</arg_value>` may be a nested frame's.
                guard let end = find("</arg_value>", from: index),
                    !holdsAny(Self.rawValueCollisions, in: index ..< end)
                else { return nil }
                index = end + 12
            }
        }

        /// The end of a JSON value at `start` and the `</arg_value>` after it.
        private func jsonValueEnd(from start: Int) -> Int? {
            var end = start
            guard jsonValue(&end, depth: 0) else { return nil }
            end = skipWhitespace(from: end)
            return starts("</arg_value>", at: end) ? end + 12 : nil
        }

        /// 0.10.13's reading, for a parser that checks schemas: raw only for a
        /// declared `string`; nil (the frame owns the rest) for a key that only
        /// canonically equals a declared one, or a union of `string` with
        /// `object` or `array`; without a type the parser accepts, JSON if it
        /// opens like JSON, raw otherwise.
        private func readsRawCheckingSchemas(parameters: [String: any Sendable]?, key: String, value: Int) -> Bool? {
            if let parameters {
                var schema = parameters["additionalProperties"]
                if let properties = parameters["properties"] as? [String: any Sendable],
                    let declared = properties.index(forKey: key)
                {
                    guard properties[declared].key.utf8.elementsEqual(key.utf8) else { return nil }
                    schema = properties[declared].value
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

        private static func isPlainObjectSchema(_ schema: [String: any Sendable]) -> Bool {
            (schema["type"] == nil || schema["type"] as? String == "object") && !hasIndirectType(schema)
                && (schema["properties"].map { $0 is [String: any Sendable] } ?? true)
        }

        private static func hasIndirectType(_ schema: [String: any Sendable]) -> Bool {
            ["$ref", "$dynamicRef", "anyOf", "oneOf", "allOf", "not", "if", "then", "else"].contains { schema[$0] != nil }
        }

        /// The SDK keeps a value's JSON reading when a type other than only
        /// `string` is declared for it (`GLM5ToolCallParser.argumentTypes`) and
        /// the value is one of those types, or, with no `string` declared, any
        /// JSON but a string; any other value is raw. The JSON kind is read
        /// from its first byte; an object or array of no declared type ends
        /// where its raw reading does unless it holds a `"`, and then `record`
        /// asks the SDK.
        private func readsJSONFirst(_ key: String, parameters: [String: any Sendable]?, value: Int) -> Bool {
            guard let parameters else { return false }
            let types = GLM5ToolCallParser.argumentTypes(key, parameters: parameters)
            guard !types.isEmpty, types != ["string"] else { return false }
            let first = skipWhitespace(from: value)
            guard first < bytes.count else { return false }
            switch bytes[first] {
            case 34: return false
            case 123: return types.contains("object") || !types.contains("string")
            case 91: return types.contains("array") || !types.contains("string")
            default: return true
            }
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

        func containsThinkMarker(_ range: Range<Int>) -> Bool {
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
