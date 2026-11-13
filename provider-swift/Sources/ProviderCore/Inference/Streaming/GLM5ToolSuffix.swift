import Foundation
import MLXLMCommon

/// The calls in a GLM tool suffix that does not parse as one batch.
///
/// The SDK's `GLM5ToolStream` withholds a response from its first
/// `<tool_call>` to EOS and parses that suffix as one call batch. On the legacy
/// text path the suffix also holds reasoning, so a `<tool_call>` the model only
/// mentioned or drafted in its thought, or one its answer mentions, fails the
/// batch. Like reference GLM parsers (vLLM, SGLang), which never fail a
/// response on tool syntax, such a suffix is text here, but with a stricter,
/// provider-specific rule for what still counts as a call: the calls are the
/// trailing run of top-level frames, separated only by whitespace and ending
/// the response, from just after the last frame of that run that does not
/// parse. Everything before them is text; a suffix with no such run (a cut-off
/// or malformed final frame, text after the calls) is all text.
///
/// A frame that has started its arguments owns everything up to its own
/// `</tool_call>`: a `<tool_call>` inside an argument, or after one, is data,
/// never a call (`Lexer`). A frame is never completed or salvaged.
enum GLM5ToolSuffix {
    /// `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the whole-suffix failure:
    /// an `auto` response whose suffix does not parse fails with a 500.
    static let environmentKey = "DARKBLOOM_GLM_TOOL_TEXT_FALLBACK"
    static let returnsUnparsedOutputAsTextByDefault =
        ProcessInfo.processInfo.environment[environmentKey] != "0"

    enum Split: Equatable {
        /// `text` precedes `calls`, which may be empty.
        case text(String, calls: [ToolCall])
        /// Released text would put a think marker from inside a tool frame
        /// before the service's reasoning parser, which reads it as a channel
        /// boundary. Such a suffix keeps failing, as before.
        case ambiguous
    }

    static func split(_ suffix: String, tools: [[String: any Sendable]]?) -> Split {
        let bytes = Array(suffix.utf8)
        var lexer = Lexer(bytes: bytes, tools: tools)
        lexer.run()
        // The run of whitespace-separated frames that ends the response.
        var run: [Lexer.Frame] = []
        var end = bytes.count
        if !lexer.openAtEnd {
            for frame in lexer.frames.reversed() {
                guard Lexer.isWhitespace(bytes[frame.range.upperBound ..< end]) else { break }
                run.insert(frame, at: 0)
                end = frame.range.lowerBound
            }
        }
        let parser = GLM5ToolCallParser()
        let text = { (start: Int) in String(decoding: bytes[..<start], as: UTF8.self) }
        // Each frame parses on its own, so the starts that parse to the end
        // are exactly those after the run's last frame that does not.
        let first = run.lastIndex { parser.parse(content: Lexer.string(bytes, $0.range), tools: tools) == nil }
            .map { $0 + 1 } ?? 0
        if first < run.count {
            let start = run[first].range.lowerBound
            let calls = parser.parseEOS(String(decoding: bytes[start...], as: UTF8.self), tools: tools)
            // The SDK reads the same frames; anything else stays text.
            if calls.count == run.count - first {
                return lexer.releasesThinkMarker(before: start) ? .ambiguous : .text(text(start), calls: calls)
            }
        }
        return lexer.releasesThinkMarker(before: bytes.count) ? .ambiguous : .text(suffix, calls: [])
    }

    /// `suffix` without the run of whitespace-separated frames that ends an
    /// output the token limit cut, whose last frame closed or was left
    /// unfinished by the end (`Lexer.cutFrameStart`). Such frames are never
    /// published as text (`TokenLimitCutPolicy`), and a suffix that did not
    /// parse is not split into calls at a cut, so they are dropped. Mentions,
    /// frames followed by text, and the text before the run stay.
    static func droppingCutFrames(_ suffix: String, tools: [[String: any Sendable]]?) -> String {
        let bytes = Array(suffix.utf8)
        var lexer = Lexer(bytes: bytes, tools: tools)
        lexer.run()
        var start = lexer.cutFrameStart ?? bytes.count
        for frame in lexer.frames.reversed() where frame.range.upperBound <= start {
            guard Lexer.isWhitespace(bytes[frame.range.upperBound ..< start]) else { break }
            start = frame.range.lowerBound
        }
        return String(decoding: bytes[..<start], as: UTF8.self)
    }

    /// Top-level GLM frames, read as the SDK's parser reads them: a name up to
    /// `<`, then `<arg_key>`/`<arg_value>` pairs to `</tool_call>`. A
    /// `<tool_call>` not followed by a name and `<arg_key>` or `</tool_call>`
    /// is a mention and stays text, unless the response ends in it after the
    /// start of a declared name (`cutFrameStart`). Once a frame has an
    /// argument it owns everything up to its `</tool_call>`; a string-typed
    /// value runs to `</arg_value>` (the template writes strings raw), any
    /// other value is JSON, whose quoted delimiters are data.
    struct Lexer {
        struct Frame {
            let range: Range<Int>
            /// A think marker inside the frame's arguments.
            let holdsThinkMarker: Bool
        }

        let bytes: [UInt8]
        let tools: [[String: any Sendable]]?
        private(set) var frames: [Frame] = []
        /// A frame's arguments were still open at the end of the response.
        private(set) var openAtEnd = false
        /// Where the frame the end of the response left unfinished starts: one
        /// whose arguments are still open (`openAtEnd`), or one that ends in
        /// its name or a cut-off first tag, the name being the start of a
        /// declared one (otherwise the `<tool_call>` is a mention).
        private(set) var cutFrameStart: Int?
        private var openFrameHoldsThinkMarker = false
        private var index = 0

        init(bytes: [UInt8], tools: [[String: any Sendable]]?) {
            self.bytes = bytes
            self.tools = tools
        }

        mutating func run() {
            while let start = find("<tool_call>", from: index) {
                index = start + 11
                guard let tag = find("<", from: index) else {
                    if beginsDeclaredName(Self.string(bytes, index ..< bytes.count)) { cutFrameStart = start }
                    return
                }
                let name = Self.string(bytes, index ..< tag)
                if starts("</tool_call>", at: tag) {
                    index = tag + 12
                    frames.append(Frame(range: start ..< index, holdsThinkMarker: false))
                } else if starts("<arg_key>", at: tag) {
                    index = tag
                    guard let frame = arguments(start: start, name: Self.trimmed(name)) else { return }
                    frames.append(frame)
                } else if endsInFrameTag(at: tag), beginsDeclaredName(name) {
                    cutFrameStart = start
                    return
                } else {
                    index = tag
                }
            }
        }

        /// Whether text released up to `end` holds a think marker inside a frame.
        func releasesThinkMarker(before end: Int) -> Bool {
            frames.contains { $0.holdsThinkMarker && $0.range.lowerBound < end }
                || (openAtEnd && openFrameHoldsThinkMarker)
        }

        /// The frame from `start`, whose arguments begin at `index`; nil when
        /// it is still open at the end of the response.
        private mutating func arguments(start: Int, name: String) -> Frame? {
            var key: String?
            var thinkMarker = false
            while let tag = find("<", from: index) {
                if starts("</tool_call>", at: tag) {
                    index = tag + 12
                    return Frame(range: start ..< index, holdsThinkMarker: thinkMarker)
                }
                if starts("<arg_key>", at: tag) {
                    guard let close = find("</arg_key>", from: tag + 9) else { break }
                    key = Self.string(bytes, tag + 9 ..< close)
                    index = close + 10
                } else if starts("<arg_value>", at: tag) {
                    let value = tag + 11
                    guard let end = isString(name: name, key: key)
                        ? find("</arg_value>", from: value) : jsonEnd(from: value)
                    else { break }
                    thinkMarker = thinkMarker || containsThinkMarker(value ..< end)
                    index = end
                    key = nil
                } else {
                    thinkMarker = thinkMarker || starts("<think>", at: tag) || starts("</think>", at: tag)
                    index = tag + 1
                }
            }
            openAtEnd = true
            cutFrameStart = start
            openFrameHoldsThinkMarker = thinkMarker || containsThinkMarker(index ..< bytes.count)
            return nil
        }

        /// The end of a JSON value: after its closing bracket or string, or at
        /// a `<` outside any string (malformed JSON ends there); nil when it
        /// is still open at the end of the response.
        private func jsonEnd(from start: Int) -> Int? {
            var index = start
            var depth = 0
            var inString = false
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if inString {
                    if byte == 92 { index += 1 } else if byte == 34 {
                        inString = false
                        if depth == 0 { return index }
                    }
                    continue
                }
                switch byte {
                case 34: inString = true
                case 123, 91: depth += 1
                case 125, 93:
                    depth -= 1
                    if depth <= 0 { return index }
                case 60: return index - 1
                default: break
                }
            }
            return nil
        }

        /// What follows a `<tool_call>` the response ends in: nothing yet, or
        /// the start of a declared function's name.
        private func beginsDeclaredName(_ text: String) -> Bool {
            let name = Self.trimmed(text)
            return name.isEmpty || (tools ?? []).contains {
                ((($0["function"] as? [String: any Sendable]) ?? $0)["name"] as? String)?.hasPrefix(name) == true
            }
        }

        /// The response ends inside the tag at `tag`, which would have opened
        /// the frame's arguments or closed it.
        private func endsInFrameTag(at tag: Int) -> Bool {
            let rest = bytes[tag...]
            return ["<arg_key>", "</tool_call>"].contains { $0.utf8.count > rest.count && $0.utf8.starts(with: rest) }
        }

        /// The template writes a string value raw and any other value as JSON;
        /// the SDK reads it the same way, by the declared type.
        private func isString(name: String, key: String?) -> Bool {
            guard let key, let tools else { return false }
            let functions = tools.map { ($0["function"] as? [String: any Sendable]) ?? $0 }
                .filter { $0["name"] as? String == name }
            guard functions.count == 1, let parameters = functions[0]["parameters"] as? [String: any Sendable]
            else { return false }
            let schema = (parameters["properties"] as? [String: any Sendable])?[key] ?? parameters["additionalProperties"]
            // A union with `string` is written raw too; the SDK then refuses the frame.
            let type = (schema as? [String: any Sendable])?["type"]
            return type as? String == "string" || (type as? [String])?.contains("string") == true
        }

        private func containsThinkMarker(_ range: Range<Int>) -> Bool {
            var index = range.lowerBound
            while let tag = find("<", from: index), tag < range.upperBound {
                if starts("<think>", at: tag) || starts("</think>", at: tag) { return true }
                index = tag + 1
            }
            return false
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
            bytes.allSatisfy { [9, 10, 13, 32].contains($0) }
        }

        static func string(_ bytes: [UInt8], _ range: Range<Int>) -> String {
            String(decoding: bytes[range], as: UTF8.self)
        }

        static func trimmed(_ name: String) -> String {
            name.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        }
    }
}
