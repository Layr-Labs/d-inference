import Foundation
import MLXLMCommon

/// GLM-5.3-Flash tool calls exposed while they are generated, to a client
/// that streams (`ToolStreamPreparation.streamsGLMCalls`). The SDK's
/// `GLM5ToolStream` keeps the whole tool suffix to EOS instead; this reads the
/// answer channel (reasoning is split off before it, so a frame drafted in a
/// thought is never a call) frame by frame, with the SDK parser's grammar:
///
/// - Text before a frame streams at once.
/// - A frame is exposed only once it is unambiguous: `<tool_call>`, a valid
///   function name that the request declares exactly once and that
///   `exposesName` accepts, then the frame's own `<arg_key>`. A `<tool_call>`
///   followed by anything else is a mention and stays text.
/// - A value whose only declared type is `string` is raw text to its
///   `</arg_value>`, so it streams as a JSON string while generated. Any other
///   value (a JSON-typed one may quote the frame's own tags as data) ends
///   incremental exposure for the rest of its frame.
/// - A frame closes at the first `</tool_call>` at which the SDK parser reads
///   it as one call (`GLM5ToolCallParser.parse`), which is where its EOS
///   reading of the frame ends. Every exposed call is checked against that
///   parse: `callCompleted` completes the exposed JSON to exactly its
///   arguments; a frame that breaks the grammar after it was exposed fails
///   (`callFailed`) and owns the rest of the output.
/// - A frame never exposed completes in one piece (`call`), or is text when
///   it does not parse.
/// Owned by one request's router and used from one task at a time, as
/// `BatchedToolStreamHandler` is; a router that owns one (Super's output,
/// handed to its collector) stays sendable.
final class GLM5ToolCallStream: @unchecked Sendable {
    private static let open = Array("<tool_call>".utf8)
    private static let close = Array("</tool_call>".utf8)
    private static let keyOpen = Array("<arg_key>".utf8)
    private static let keyClose = Array("</arg_key>".utf8)
    private static let valueOpen = Array("<arg_value>".utf8)
    private static let valueClose = Array("</arg_value>".utf8)
    /// The tags the SDK parser refuses inside a raw value.
    private static let collisions = [open, close, keyOpen, keyClose, valueOpen]
    /// The SDK parser's bound on one tool suffix.
    private static let maximumBytes = 1 << 20

    private enum State: Equatable {
        /// Outside every frame.
        case text
        /// After `<tool_call>`, until the tag after the name decides.
        case header
        /// Exposed: before `<arg_key>` or `</tool_call>`.
        case between
        /// Exposed: inside `<arg_key>`, up to `<arg_value>`.
        case key
        /// Exposed: a raw string value, streamed while generated.
        case string
        /// The rest of the frame, collected until the parse closes it.
        case rest
        /// An exposed frame failed; it owns the rest of the output.
        case failed
    }

    private let tools: [[String: any Sendable]]?
    private let exposesName: (String) -> Bool
    private let parser: GLM5ToolCallParser
    private var state = State.text
    /// Text not yet released outside a frame (a possible split `<tool_call>`).
    private var text: [UInt8] = []
    /// A frame just closed: whitespace after it is framing, dropped when
    /// another frame or the end follows, as in the complete-call path's run
    /// of frames, and released only before other text.
    private var afterFrame = false
    /// The current frame from its `<tool_call>`.
    private var frame: [UInt8] = []
    /// How far into `frame` the incremental reading has gone.
    private var cursor = 0
    /// Where the next `</tool_call>` search in `.rest` starts.
    private var closeSearch = 0
    private var name: String?
    private var exposed = false
    private var parameters: [String: any Sendable] = [:]
    private var keys: Set<String> = []
    private var arguments = StreamedArguments()
    /// `<tool_call>`s never exposed that became text: a frame that did not
    /// parse, was still open at the end or outgrew the bound, or a mention.
    /// The complete-call path reads each as the SDK parser's failure.
    private(set) var unparsedFrames = 0
    /// A frame never exposed was still open at a cut and was dropped.
    private(set) var droppedFrameAtCut = false

    init(tools: [[String: any Sendable]]?, exposesName: @escaping (String) -> Bool,
         grammarOnly: Bool = GrammarOnlyToolParsing.isEnabled) {
        self.tools = tools
        self.exposesName = exposesName
        parser = GLM5ToolCallParser(grammarOnly: grammarOnly)
    }

    func process(_ chunk: String) -> [ToolCallStreamSegment] {
        var segments: [ToolCallStreamSegment] = []
        switch state {
        case .failed: return []
        case .text: text += chunk.utf8
        default: frame += chunk.utf8
        }
        advance(into: &segments)
        return segments
    }

    /// End of output: released text, and the frame still open. An exposed
    /// one is `unterminated` (GLM's end tag is not a stop token); one never
    /// exposed is text, or, at a cut (`cutAtLimit`), dropped, as the
    /// complete-call path drops the frames that end a cut output
    /// (`GLM5ToolSuffix.textAtCut`).
    func finish(cutAtLimit: Bool = false) -> [ToolCallStreamSegment] {
        var segments: [ToolCallStreamSegment] = []
        switch state {
        case .text:
            if !(afterFrame && text.allSatisfy(Self.isWhitespace)) { appendText(text, to: &segments) }
        case .failed:
            break
        case .header:
            releaseOpenFrame(cutAtLimit: cutAtLimit, into: &segments)
        default:
            if state == .rest, let (end, call) = finalClose() {
                // No more output: the first close the parse accepts is final.
                _ = complete(at: end, parsed: call, into: &segments)
                advance(into: &segments)
                segments += finish(cutAtLimit: cutAtLimit)
                return segments
            }
            if exposed {
                segments.append(.callFailed(.unterminated))
            } else {
                releaseOpenFrame(cutAtLimit: cutAtLimit, into: &segments)
            }
        }
        text = []
        afterFrame = false
        resetFrame()
        state = .text
        return segments
    }

    private func releaseOpenFrame(cutAtLimit: Bool, into segments: inout [ToolCallStreamSegment]) {
        if cutAtLimit {
            droppedFrameAtCut = true
        } else {
            unparsedFrames += 1
            appendText(frame, to: &segments)
        }
    }

    // MARK: - Reading

    private func advance(into segments: inout [ToolCallStreamSegment]) {
        while true {
            switch state {
            case .failed:
                return
            case .text:
                guard readText(into: &segments) else { return }
            case .header:
                guard readHeader(into: &segments) else { return }
            case .between:
                guard readBetween(into: &segments) else { return }
            case .key:
                guard readKey(into: &segments) else { return }
            case .string:
                guard readString(into: &segments) else { return }
            case .rest:
                guard readRest(into: &segments) else { return }
            }
        }
    }

    /// True when the state changed and reading continues.
    private func readText(into segments: inout [ToolCallStreamSegment]) -> Bool {
        if afterFrame {
            let framing = text.prefix(while: Self.isWhitespace).count
            if Self.starts(text, with: Self.open, at: framing) {
                text.removeFirst(framing)
            } else if framing == text.count || Self.isProperPrefix(text[framing...], of: [Self.open]) {
                return false
            }
            afterFrame = false
        }
        if let start = Self.find(Self.open, in: text, from: 0) {
            appendText(text[..<start], to: &segments)
            frame = Array(text[start...])
            text = []
            cursor = Self.open.count
            state = .header
            return true
        }
        let keep = Self.partialSuffix(of: text, from: 0, matching: [Self.open])
        appendText(text[..<(text.count - keep)], to: &segments)
        text = Array(text[(text.count - keep)...])
        return false
    }

    private func readHeader(into segments: inout [ToolCallStreamSegment]) -> Bool {
        guard let tag = frame[cursor...].firstIndex(of: 60) else {
            if frame.count > Self.maximumBytes { return mention(at: frame.count, into: &segments) }
            return false
        }
        if Self.isProperPrefix(frame[tag...], of: [Self.keyOpen, Self.close]) { return false }
        let rawName = String(decoding: frame[Self.open.count ..< tag], as: UTF8.self)
        let trimmed = rawName.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
        if Self.starts(frame, with: Self.close, at: tag) {
            return complete(at: tag + Self.close.count, into: &segments)
        }
        guard Self.starts(frame, with: Self.keyOpen, at: tag) else { return mention(at: tag, into: &segments) }
        name = trimmed
        cursor = tag
        if Self.isFunctionName(trimmed), exposesName(trimmed), let declared = declaredParameters(trimmed) {
            parameters = declared
            exposed = true
            segments.append(.callStarted(name: trimmed))
            state = .between
        } else {
            parameters = Self.isFunctionName(trimmed) ? declaredParameters(trimmed) ?? [:] : [:]
            closeSearch = cursor
            state = .rest
        }
        return true
    }

    /// A `<tool_call>` that does not open a frame: text, read again from `end`.
    private func mention(at end: Int, into segments: inout [ToolCallStreamSegment]) -> Bool {
        unparsedFrames += 1
        appendText(frame[..<end], to: &segments)
        text = Array(frame[end...])
        resetFrame()
        state = .text
        return true
    }

    private func readBetween(into segments: inout [ToolCallStreamSegment]) -> Bool {
        while cursor < frame.count, Self.isWhitespace(frame[cursor]) { cursor += 1 }
        guard cursor < frame.count else { return false }
        if Self.starts(frame, with: Self.close, at: cursor) {
            return complete(at: cursor + Self.close.count, into: &segments)
        }
        if Self.starts(frame, with: Self.keyOpen, at: cursor) {
            cursor += Self.keyOpen.count
            state = .key
            return true
        }
        if Self.isProperPrefix(frame[cursor...], of: [Self.close, Self.keyOpen]) { return false }
        return fail(.malformed, into: &segments)
    }

    private func readKey(into segments: inout [ToolCallStreamSegment]) -> Bool {
        guard let end = Self.find(Self.keyClose, in: frame, from: cursor) else {
            // A key may not hold `<`, so only the start of its end tag waits.
            if let angle = frame[cursor...].firstIndex(of: 60),
                !Self.isProperPrefix(frame[angle...], of: [Self.keyClose]) {
                return fail(.malformed, into: &segments)
            }
            return false
        }
        let valueStart = end + Self.keyClose.count
        guard frame.count >= valueStart + Self.valueOpen.count else {
            if Self.isProperPrefix(frame[valueStart...], of: [Self.valueOpen]) || valueStart == frame.count {
                return false
            }
            return fail(.malformed, into: &segments)
        }
        let key = String(decoding: frame[cursor ..< end], as: UTF8.self)
        guard !key.isEmpty, !frame[cursor ..< end].contains(60), Self.starts(frame, with: Self.valueOpen, at: valueStart),
            keys.insert(key).inserted
        else { return fail(.malformed, into: &segments) }
        cursor = valueStart + Self.valueOpen.count
        if GLM5ToolCallParser.argumentTypes(key, parameters: parameters) == ["string"] {
            segments.append(.callArguments(arguments.beginString(key)))
            state = .string
        } else {
            // A typed value may quote the frame's tags: the parse decides.
            closeSearch = cursor
            state = .rest
        }
        return true
    }

    private func readString(into segments: inout [ToolCallStreamSegment]) -> Bool {
        let start = cursor
        if let end = Self.find(Self.valueClose, in: frame, from: start) {
            guard !Self.holdsCollision(frame[start ..< end]) else { return fail(.malformed, into: &segments) }
            segments.append(.callArguments(arguments.appendString(frame[start ..< end]) + arguments.endString()))
            cursor = end + Self.valueClose.count
            state = .between
            return true
        }
        // A raw value holding a frame tag never parses.
        if Self.holdsCollision(frame[start...]) { return fail(.malformed, into: &segments) }
        if frame.count > Self.maximumBytes { return fail(.malformed, into: &segments) }
        // A tag split across chunks is held: the value's end, or a collision.
        let keep = Self.partialSuffix(of: frame, from: start, matching: [Self.valueClose] + Self.collisions)
        let release = frame.count - keep
        guard release > start else { return false }
        let fragment = arguments.appendString(frame[start ..< release])
        cursor = release
        if !fragment.isEmpty { segments.append(.callArguments(fragment)) }
        return false
    }

    private func readRest(into segments: inout [ToolCallStreamSegment]) -> Bool {
        while let found = Self.find(Self.close, in: frame, from: closeSearch) {
            let end = found + Self.close.count
            closeSearch = found + 1
            if let call = closes(at: end) { return complete(at: end, parsed: call, into: &segments) }
        }
        closeSearch = max(closeSearch, frame.count - Self.close.count + 1, 0)
        if frame.count > Self.maximumBytes {
            if exposed { return fail(.malformed, into: &segments) }
            return mention(at: frame.count, into: &segments)
        }
        return false
    }

    /// The call the frame closes with at `end`: the parser reads
    /// `frame[..<end]` as one call, and that reading is its reading of the
    /// whole output there; nil when it does not close there.
    private func closes(at end: Int, final: Bool = false) -> ToolCall? {
        guard settles(at: end, final: final) else { return nil }
        return parser.parse(content: String(decoding: frame[..<end], as: UTF8.self), tools: tools)
    }

    /// Whether the parser's reading of `frame[..<end]` is its reading of the
    /// whole output there: it reads a typed value as JSON first, and a JSON
    /// value still open where the prefix ends (a quoted `</tool_call>`) would
    /// fall back to raw text on the prefix only. Every typed value in the
    /// prefix must have ended as JSON, or broken it, before `end`; at the end
    /// of output (`final`), it may also be open or broken over the whole
    /// frame. Keys are found textually, so one may be quoted inside a typed
    /// value; its value then never ends as JSON, and only the final close,
    /// where the raw reading is the prefix's own, accepts it.
    private func settles(at end: Int, final: Bool = false) -> Bool {
        var index = Self.open.count
        while let key = Self.find(Self.keyOpen, in: frame, from: index), key < end {
            index = key + Self.keyOpen.count
            guard let keyEnd = Self.find(Self.keyClose, in: frame, from: index), keyEnd < end,
                !frame[index ..< keyEnd].contains(60), Self.starts(frame, with: Self.valueOpen, at: keyEnd + Self.keyClose.count)
            else { continue }
            let types = GLM5ToolCallParser.argumentTypes(
                String(decoding: frame[index ..< keyEnd], as: UTF8.self), parameters: parameters)
            let value = keyEnd + Self.keyClose.count + Self.valueOpen.count
            if !types.isEmpty, types != ["string"] {
                var cursor = value
                if Self.scanJSON(Array(frame[..<end]), &cursor, depth: 0) == .open {
                    guard final else { return false }
                    cursor = value
                    if Self.scanJSON(frame, &cursor, depth: 0) == .closed { return false }
                }
            }
            index = value
        }
        return true
    }

    private enum JSONScan: Equatable { case closed, broken, open }

    /// One JSON value from `index`, structurally as the parser reads it;
    /// `open` when `bytes` ends before it does.
    private static func scanJSON(_ bytes: [UInt8], _ index: inout Int, depth: Int) -> JSONScan {
        guard depth <= 64 else { return .broken }
        skipWhitespace(bytes, &index)
        guard index < bytes.count else { return .open }
        switch bytes[index] {
        case 34:
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                index += 1
                if byte < 32 { return .broken }
                if byte == 34 { return .closed }
                if byte == 92 { index += 1 }
            }
            return .open
        case 123, 91:
            let object = bytes[index] == 123
            index += 1
            skipWhitespace(bytes, &index)
            guard index < bytes.count else { return .open }
            if bytes[index] == (object ? 125 : 93) { index += 1; return .closed }
            while true {
                if object {
                    skipWhitespace(bytes, &index)
                    guard index < bytes.count else { return .open }
                    guard bytes[index] == 34 else { return .broken }
                    let key = scanJSON(bytes, &index, depth: depth + 1)
                    guard key == .closed else { return key }
                    skipWhitespace(bytes, &index)
                    guard index < bytes.count else { return .open }
                    guard bytes[index] == 58 else { return .broken }
                    index += 1
                }
                let member = scanJSON(bytes, &index, depth: depth + 1)
                guard member == .closed else { return member }
                skipWhitespace(bytes, &index)
                guard index < bytes.count else { return .open }
                if bytes[index] == (object ? 125 : 93) { index += 1; return .closed }
                guard bytes[index] == 44 else { return .broken }
                index += 1
            }
        case 116, 102, 110:
            let literal = Array((bytes[index] == 116 ? "true" : bytes[index] == 102 ? "false" : "null").utf8)
            let available = min(literal.count, bytes.count - index)
            guard bytes[index ..< index + available].elementsEqual(literal[..<available]) else { return .broken }
            guard available == literal.count else { return .open }
            index += literal.count
            return .closed
        default:
            let start = index
            while index < bytes.count,
                (48 ... 57).contains(bytes[index]) || [43, 45, 46, 69, 101].contains(bytes[index]) {
                index += 1
            }
            guard index < bytes.count else { return .open }
            return index > start ? .closed : .broken
        }
    }

    private static func skipWhitespace(_ bytes: [UInt8], _ index: inout Int) {
        while index < bytes.count, isWhitespace(bytes[index]) { index += 1 }
    }

    /// At the end of output, the `</tool_call>` where the parser's reading of
    /// the frame ends.
    private func finalClose() -> (Int, ToolCall)? {
        var search = Self.open.count
        while let found = Self.find(Self.close, in: frame, from: search) {
            let end = found + Self.close.count
            if let call = closes(at: end, final: true) { return (end, call) }
            search = found + 1
        }
        return nil
    }

    /// The frame ends at `end`: the parse decides what it was (`parsed`,
    /// when the close already read it).
    private func complete(at end: Int, parsed: ToolCall? = nil, into segments: inout [ToolCallStreamSegment]) -> Bool {
        let call = parsed ?? parser.parse(content: String(decoding: frame[..<end], as: UTF8.self), tools: tools)
        if exposed {
            guard let call else { return fail(.malformed, into: &segments) }
            guard call.function.name == name, let remainder = arguments.remainder(completing: call.function.arguments)
            else { return fail(.diverged, into: &segments) }
            segments.append(.callCompleted(call: call, remainingArguments: remainder))
        } else if let call {
            segments.append(.call(call))
        } else {
            unparsedFrames += 1
            appendText(frame[..<end], to: &segments)
        }
        text = Array(frame[end...])
        afterFrame = exposed || call != nil
        resetFrame()
        state = .text
        return true
    }

    private func fail(_ failure: ToolCallStreamFailure, into segments: inout [ToolCallStreamSegment]) -> Bool {
        segments.append(.callFailed(failure))
        resetFrame()
        state = .failed
        return false
    }

    private func resetFrame() {
        frame = []
        cursor = 0
        closeSearch = 0
        name = nil
        exposed = false
        parameters = [:]
        keys = []
        arguments = StreamedArguments()
    }

    /// The parameter schema of the one declaration of `name`, as the SDK
    /// parser resolves it; nil when it would refuse the name.
    private func declaredParameters(_ name: String) -> [String: any Sendable]? {
        guard let tools else { return nil }
        var matches: [[String: any Sendable]] = []
        for tool in tools {
            let function: [String: any Sendable]
            if let wrapped = tool["function"] {
                guard let value = wrapped as? [String: any Sendable] else { return nil }
                function = value
            } else {
                function = tool
            }
            if function["name"] as? String == name { matches.append(function) }
        }
        guard matches.count == 1 else { return nil }
        guard let raw = matches[0]["parameters"] else { return [:] }
        guard let parameters = raw as? [String: any Sendable] else { return parser.grammarOnly ? [:] : nil }
        return parameters
    }

    private func appendText<C: Collection>(_ bytes: C, to segments: inout [ToolCallStreamSegment])
    where C.Element == UInt8 {
        guard !bytes.isEmpty else { return }
        segments.append(.text(String(decoding: bytes, as: UTF8.self)))
    }

    // MARK: - Bytes

    private static func find(_ marker: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard start >= 0, bytes.count >= marker.count else { return nil }
        var index = start
        while index + marker.count <= bytes.count {
            if bytes[index] == marker[0], starts(bytes, with: marker, at: index) { return index }
            index += 1
        }
        return nil
    }

    private static func starts(_ bytes: [UInt8], with marker: [UInt8], at index: Int) -> Bool {
        index + marker.count <= bytes.count && bytes[index ..< index + marker.count].elementsEqual(marker)
    }

    /// `bytes` is shorter than one of `markers` and starts it.
    private static func isProperPrefix(_ bytes: ArraySlice<UInt8>, of markers: [[UInt8]]) -> Bool {
        markers.contains { $0.count > bytes.count && $0.starts(with: bytes) }
    }

    /// Length of the longest suffix of `bytes[start...]` that is a proper
    /// prefix of one of `markers`. Every marker starts with `<`, so the split
    /// is a character boundary.
    private static func partialSuffix(of bytes: [UInt8], from start: Int, matching markers: [[UInt8]]) -> Int {
        let longest = (markers.map(\.count).max() ?? 1) - 1
        for length in stride(from: min(longest, bytes.count - start), to: 0, by: -1)
        where isProperPrefix(bytes[(bytes.count - length)...], of: markers) {
            return length
        }
        return 0
    }

    private static func holdsCollision(_ bytes: ArraySlice<UInt8>) -> Bool {
        var index = bytes.startIndex
        while let angle = bytes[index...].firstIndex(of: 60) {
            if collisions.contains(where: { bytes[angle...].starts(with: $0) }) { return true }
            index = angle + 1
        }
        return false
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 13 || byte == 32
    }

    /// The SDK parser's function-name rule: 1-64 ASCII letters, digits, `-`, `_`.
    private static func isFunctionName(_ name: String) -> Bool {
        (1 ... 64).contains(name.utf8.count) && name.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0) || $0 == 45 || $0 == 95
        }
    }
}

/// The OpenAI `arguments` JSON text exposed so far: complete string members,
/// then at most one open string. `remainder(completing:)` closes it against
/// the parsed arguments, adding every member never exposed in key order.
private struct StreamedArguments {
    private var opened = false
    private var members: [(key: String, value: String)] = []
    private var openKey: String?
    private var openValue: [UInt8] = []

    mutating func beginString(_ key: String) -> String {
        let text = (opened ? (members.isEmpty ? "" : ",") : "{") + Self.quoted(key) + ":\""
        opened = true
        openKey = key
        openValue = []
        return text
    }

    /// Raw UTF-8 bytes of the open string; always whole characters.
    mutating func appendString(_ bytes: ArraySlice<UInt8>) -> String {
        openValue += bytes
        return Self.escaped(String(decoding: bytes, as: UTF8.self))
    }

    mutating func endString() -> String {
        guard let key = openKey else { return "" }
        members.append((key, String(decoding: openValue, as: UTF8.self)))
        openKey = nil
        openValue = []
        return "\""
    }

    func remainder(completing arguments: [String: MLXLMCommon.JSONValue]) -> String? {
        guard openKey == nil,
            members.allSatisfy({ arguments[$0.key] == .string($0.value) })
        else { return nil }
        var text = opened ? "" : "{"
        var count = members.count
        let exposed = Set(members.map(\.key))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for key in arguments.keys.sorted() where !exposed.contains(key) {
            guard let value = arguments[key], let data = try? encoder.encode(value) else { return nil }
            text += (count > 0 ? "," : "") + Self.quoted(key) + ":" + String(decoding: data, as: UTF8.self)
            count += 1
        }
        return text + "}"
    }

    static func quoted(_ text: String) -> String { "\"" + escaped(text) + "\"" }

    /// JSON string content; any valid escaping decodes to the same value.
    static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) }
                else { out.unicodeScalars.append(scalar) }
            }
        }
        return out
    }
}
