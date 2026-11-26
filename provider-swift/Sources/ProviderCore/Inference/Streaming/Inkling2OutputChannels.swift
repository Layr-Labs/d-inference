import Foundation
import MLXLMCommon

/// One classified piece of Inkling 2's native output.
enum Inkling2OutputPiece: Equatable, Sendable {
    case reasoning(String)
    case content(String)
    /// One complete `<|content_invoke_tool_json|>` frame that parsed. Its id
    /// is assigned downstream, as for every other family.
    case toolCall(ToolCall)
}

/// Why a `<|content_invoke_tool_json|>` frame is not a call.
enum Inkling2ToolFrameFailure: String, Error, Equatable, Sendable {
    /// The body is not one JSON object.
    case invalidJSON
    /// The object is not exactly `{"name": string, "args": object}`.
    case wrongShape
    /// The header names a different function than the body.
    case nameMismatch
    /// The JSON nests deeper than `Inkling2OutputChannels.Limits.toolNestingDepth`.
    case nestingTooDeep
    /// The body is longer than `Inkling2OutputChannels.Limits.toolBodyBytes`.
    case bodyTooLarge
    /// Generation ended inside the frame.
    case unterminated
}

/// Lexer for Inkling 2's native output protocol, pinned to
/// `thinkingmachines/Inkling-2-Mini` @ 6e7c8248: `chat_template.jinja` and the
/// `response_template` in `tokenizer_config.json`.
///
/// The output is a run of messages after the prompt's final `<|end_message|>`:
///
///     [<|message_model|>NAME]<|content_KIND|>BODY<|end_message|>
///
/// - `thinking` is reasoning; `text`, `tool_error` and `invoke_tool_text`
///   are content (the response template's `content` field); consecutive
///   messages of one channel join with nothing between them.
/// - `invoke_tool_json` is one call, `{"name":NAME,"args":{...}}`, the shape
///   the template renders for history. A header name, when present, must equal
///   the body's name. With `callsAreText` (an `auto` request that declares no
///   tools, so its prompt has no `tool_declare`), no call can be valid and the
///   frame's body is content, as `invoke_tool_text` is; so is the text of a
///   header no content marker follows (a header-only message).
/// - `<|content_model_end_sampling|>` (EOS) ends the output, and so does the
///   start of another role's turn (`<|message_user|>`, `<|message_system|>`,
///   `<|message_tool|>`, `<|endoftext|>`, `<|begin_of_text|>`): nothing after
///   it is published.
///
/// As in the response template, a body ends only at `<|end_message|>`: a
/// marker inside a thought or an answer is that body's text, so a call drafted
/// in a thought never becomes an invocation and no closer is invented. Inside
/// a call's JSON, `<|end_message|>` within a string is argument data; outside
/// strings it closes the frame. Text outside every message (the response
/// template's unmatched text) and messages of a kind the model never answers
/// with (`image`, `xml`) are dropped and counted, never shown.
///
/// With `readsCallOpeningAnswer` (a request that declares tools), an answer
/// that opens with a function name and `<|content_invoke_tool_json|>`
/// (`<|content_text|>NAME<|content_invoke_tool_json|>{...}<|end_message|>`) is
/// that call: the model opened a text message where the call's header belongs.
/// Only the answer's first bytes are held for this, up to 64 name characters,
/// and released with the text that follows them as one piece.
///
/// With `startsInAnswer` (a prompt that ends with an open answer message,
/// `Inkling2AnswerPrefill`), the output starts inside that answer's body.
///
/// The lexer reads detokenized text with special tokens kept (the CBv2
/// detokenizer's default), so a marker spelled out from ordinary tokens reads
/// like the special token. Every bound is fixed: the header, a call's body and
/// its JSON nesting.
struct Inkling2OutputChannels {
    struct Limits: Equatable, Sendable {
        /// The response template's header is `[^<]*`, a function or assistant name.
        var headerBytes = 256
        /// One call's JSON body.
        var toolBodyBytes = 1 << 20
        /// Objects and arrays open at once inside one call's JSON.
        var toolNestingDepth = 64
    }

    enum Channel: Equatable, Sendable {
        case reasoning, content, toolCall
    }

    static let messageModel = "<|message_model|>"
    static let endMessage = "<|end_message|>"
    static let endOfSampling = "<|content_model_end_sampling|>"

    /// `DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT`: a call frame in the answer to
    /// an `auto` request that declares no tools is text by default; exact `0`
    /// restores its refusal (422 `undeclared_name`, or 500 when it does not parse).
    static let undeclaredCallTextEnvironmentKey = "DARKBLOOM_INKLING_UNDECLARED_CALL_TEXT"
    static let undeclaredCallsAreTextByDefault =
        ProcessInfo.processInfo.environment[undeclaredCallTextEnvironmentKey] != "0"

    private enum Kind: Equatable {
        case reasoning, content, toolCall, ignored
    }

    private enum Marker {
        case messageModel
        case content(Kind)
        case endMessage
        case endOfOutput
    }

    private static let markerSpellings: [(String, Marker)] = [
        ("<|message_model|>", .messageModel),
        ("<|content_thinking|>", .content(.reasoning)),
        ("<|content_text|>", .content(.content)),
        ("<|content_tool_error|>", .content(.content)),
        ("<|content_invoke_tool_text|>", .content(.content)),
        ("<|content_invoke_tool_json|>", .content(.toolCall)),
        ("<|content_image|>", .content(.ignored)),
        ("<|content_xml|>", .content(.ignored)),
        ("<|end_message|>", .endMessage),
        ("<|content_model_end_sampling|>", .endOfOutput),
        ("<|message_user|>", .endOfOutput),
        ("<|message_system|>", .endOfOutput),
        ("<|message_tool|>", .endOfOutput),
        ("<|endoftext|>", .endOfOutput),
        ("<|begin_of_text|>", .endOfOutput),
    ]
    private static let markers: [(bytes: [UInt8], marker: Marker)] = markerSpellings.map { (Array($0.0.utf8), $0.1) }

    private static let endMessageBytes = Array(endMessage.utf8)
    private static let invokeToolJSONBytes = Array("<|content_invoke_tool_json|>".utf8)
    /// A function name as requests declare it: `^[a-zA-Z0-9_-]{1,64}$`.
    private static let maximumNameBytes = 64
    private static let endOfSamplingBytes = Array(endOfSampling.utf8)
    private static let lessThan = UInt8(ascii: "<")

    private enum State: Equatable {
        case boundary
        case header
        /// The first bytes of an answer, read as a possible call header.
        case answerStart
        case body(Kind)
        case ended
    }

    private let limits: Limits
    /// `invoke_tool_json` opens a content body instead of a call.
    private let callsAreText: Bool
    /// An answer opening with `NAME<|content_invoke_tool_json|>` is that call.
    private let readsCallOpeningAnswer: Bool
    /// The content body a header-only answer goes on in: it ends at any marker.
    private var answerFromHeader = false
    private var state = State.boundary
    private var pending: [UInt8] = []
    private var header: [UInt8] = []
    private var toolBody: [UInt8] = []
    private var json = BoundedJSONShape()

    /// Calls whose frame closed but did not parse, in order.
    private(set) var toolFailures: [Inkling2ToolFrameFailure] = []
    /// Bytes outside every message, and of messages never published.
    private(set) var droppedBytes = 0
    /// Bytes after the output ended (EOS or another role's turn).
    private(set) var bytesAfterEnd = 0
    /// The output ended at a marker rather than at the engine's stop.
    private(set) var endedByMarker = false
    /// The channel generation ended in, when it ended inside a message.
    private(set) var unterminatedChannel: Channel?
    /// Some reasoning text was published.
    private(set) var hasReasoning = false

    init(limits: Limits = Limits(), callsAreText: Bool = false, readsCallOpeningAnswer: Bool = false,
         startsInAnswer: Bool = false) {
        self.limits = limits
        self.callsAreText = callsAreText
        self.readsCallOpeningAnswer = readsCallOpeningAnswer && !callsAreText
        if startsInAnswer { state = self.readsCallOpeningAnswer ? .answerStart : .body(.content) }
    }

    /// The channel of the message being read, if any.
    var openChannel: Channel? {
        switch state {
        case .body(.reasoning): .reasoning
        case .body(.content), .answerStart: .content
        case .body(.toolCall): .toolCall
        default: nil
        }
    }

    var bufferedByteCount: Int { pending.count + header.count + toolBody.count }

    mutating func parse(_ text: String) -> [Inkling2OutputPiece] {
        pending.append(contentsOf: text.utf8)
        return drain(final: false)
    }

    /// End of generation. A message still open is reported in
    /// `unterminatedChannel`; its text is published, a call is not.
    mutating func finish() -> [Inkling2OutputPiece] {
        var pieces = drain(final: true)
        switch state {
        case .header:
            closeHeaderOnly(into: &pieces)
        case .answerStart:
            unterminatedChannel = .content
        case .body(.reasoning):
            unterminatedChannel = .reasoning
        case .body(.content):
            unterminatedChannel = .content
        case .body(.toolCall):
            unterminatedChannel = .toolCall
            toolFailures.append(.unterminated)
        case .body(.ignored), .boundary, .ended:
            break
        }
        header = []
        toolBody = []
        state = .ended
        return pieces
    }

    // MARK: - Lexing

    private mutating func drain(final: Bool) -> [Inkling2OutputPiece] {
        var pieces: [Inkling2OutputPiece] = []
        var index = 0
        loop: while index < pending.count {
            switch state {
            case .ended:
                bytesAfterEnd += pending.count - index
                index = pending.count
            case .boundary:
                guard let step = readBoundary(from: index, final: final) else { break loop }
                index = step
            case .header:
                guard let step = readHeader(from: index, final: final, into: &pieces) else { break loop }
                index = step
            case .answerStart:
                guard let step = readAnswerStart(from: index, final: final) else { break loop }
                index = step
            case .body(let kind) where kind == .toolCall:
                guard let step = readToolBody(from: index, final: final, into: &pieces) else { break loop }
                index = step
            case .body(let kind):
                guard let step = readTextBody(kind, from: index, final: final, into: &pieces) else { break loop }
                index = step
            }
        }
        pending.removeFirst(index)
        if final, !pending.isEmpty {
            // Only a marker prefix can remain; outside a body it is no text.
            droppedBytes += pending.count
            pending = []
        }
        return pieces
    }

    /// Between messages: a marker, or text no message holds.
    private mutating func readBoundary(from index: Int, final: Bool) -> Int? {
        if pending[index] != Self.lessThan {
            let next = pending[index...].firstIndex(of: Self.lessThan) ?? pending.count
            droppedBytes += next - index
            return next
        }
        switch match(at: index) {
        case .partial:
            if final {
                droppedBytes += pending.count - index
                return pending.count
            }
            return nil
        case .none:
            droppedBytes += 1
            return index + 1
        case .marker(let marker, let length):
            switch marker {
            case .messageModel:
                header = []
                state = .header
            case .content(let kind):
                header = []
                enter(kind)
            case .endMessage:
                droppedBytes += length
            case .endOfOutput:
                endedByMarker = true
                state = .ended
            }
            return index + length
        }
    }

    /// After `<|message_model|>`: the name, up to the content marker.
    private mutating func readHeader(
        from index: Int, final: Bool, into pieces: inout [Inkling2OutputPiece]
    ) -> Int? {
        var cursor = index
        while cursor < pending.count, pending[cursor] != Self.lessThan {
            header.append(pending[cursor])
            cursor += 1
            if header.count > limits.headerBytes, !callsAreText || Self.endsOnCharacter(header) {
                if callsAreText {
                    // Too long for a name: the start of a header-only answer.
                    closeHeaderOnly(into: &pieces)
                    state = .body(.content)
                    answerFromHeader = true
                    return cursor
                }
                // Not a header the response template reads: the bytes are
                // text outside every message.
                droppedBytes += header.count + Self.messageModel.utf8.count
                header = []
                state = .boundary
                return cursor
            }
        }
        guard cursor < pending.count else { return cursor }
        switch match(at: cursor) {
        case .partial:
            if final {
                closeHeaderOnly(into: &pieces)
                droppedBytes += pending.count - cursor
                state = .boundary
                return pending.count
            }
            // Keep the bytes read so far; resume at the possible marker.
            return cursor == index ? nil : cursor
        case .none:
            if callsAreText {
                // A `<` that opens no marker: the answer goes on as text.
                closeHeaderOnly(into: &pieces)
                state = .body(.content)
                answerFromHeader = true
                return cursor
            }
            // `[^<]*` cannot hold this `<`: no message starts here.
            droppedBytes += header.count + Self.messageModel.utf8.count
            header = []
            state = .boundary
            return cursor
        case .marker(.content(let kind), let length):
            enter(kind)
            return cursor + length
        case .marker(.messageModel, let length):
            closeHeaderOnly(into: &pieces)
            droppedBytes += length
            return cursor + length
        case .marker(.endMessage, let length):
            closeHeaderOnly(into: &pieces)
            droppedBytes += length
            state = .boundary
            return cursor + length
        case .marker(.endOfOutput, let length):
            closeHeaderOnly(into: &pieces)
            endedByMarker = true
            state = .ended
            return cursor + length
        }
    }

    /// The bytes end on a whole UTF-8 character, so a cut never splits one.
    private static func endsOnCharacter(_ bytes: [UInt8]) -> Bool {
        guard let lead = bytes.lastIndex(where: { $0 & 0xC0 != 0x80 }) else { return true }
        let need = bytes[lead] < 0x80 ? 1 : bytes[lead] >= 0xF0 ? 4 : bytes[lead] >= 0xE0 ? 3 : 2
        return bytes.count - lead >= need
    }

    /// A message whose header no content marker followed. With `callsAreText`
    /// the model answered in the header itself (a request without declared
    /// tools, e.g. `<|message_model|>get_weather(city: Paris)<|end_message|>`):
    /// its text is the answer. Otherwise it is text outside every message.
    /// A header never holds `<`, so no control token reaches the answer.
    private mutating func closeHeaderOnly(into pieces: inout [Inkling2OutputPiece]) {
        if callsAreText, !header.isEmpty {
            pieces.append(.content(String(decoding: header, as: UTF8.self)))
        } else {
            droppedBytes += header.count
        }
        header = []
    }

    private mutating func enter(_ marked: Kind) {
        let kind = marked == .toolCall && callsAreText ? Kind.content : marked
        answerFromHeader = false
        if kind == .toolCall {
            toolBody = []
            json = BoundedJSONShape()
        } else {
            header = []
        }
        state = .body(kind)
        if marked == .content, readsCallOpeningAnswer {
            state = .answerStart
        }
    }

    /// The start of an answer: a function name then `<|content_invoke_tool_json|>`
    /// makes the message that call, with the name as its header. The name's
    /// bytes stay unread until that is decided; any other byte, or a name too
    /// long, leaves them to the answer, read with what follows as one piece.
    private mutating func readAnswerStart(from index: Int, final: Bool) -> Int? {
        var cursor = index
        while cursor < pending.count, cursor - index <= Self.maximumNameBytes {
            let byte = pending[cursor]
            if byte == Self.lessThan {
                if cursor > index, hasPrefix(Self.invokeToolJSONBytes, at: cursor) {
                    let name = Array(pending[index..<cursor])
                    enter(.toolCall)
                    header = name
                    return cursor + Self.invokeToolJSONBytes.count
                }
                if !final, cursor > index, isStrictPrefix(at: cursor, of: Self.invokeToolJSONBytes) { return nil }
                break
            }
            guard Self.isNameByte(byte) else { break }
            cursor += 1
        }
        if cursor == pending.count, !final, cursor - index <= Self.maximumNameBytes { return nil }
        state = .body(.content)
        return index
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
            UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"):
            true
        default:
            false
        }
    }

    /// A thought or an answer: published as read, up to `<|end_message|>`.
    private mutating func readTextBody(
        _ kind: Kind, from index: Int, final: Bool, into pieces: inout [Inkling2OutputPiece]
    ) -> Int? {
        var cursor = index
        var end: Int?
        var close: (length: Int, endsOutput: Bool)?
        while cursor < pending.count {
            if pending[cursor] == Self.lessThan {
                if hasPrefix(Self.endMessageBytes, at: cursor) {
                    close = (Self.endMessageBytes.count, false)
                    end = cursor
                    break
                }
                if hasPrefix(Self.endOfSamplingBytes, at: cursor) {
                    close = (Self.endOfSamplingBytes.count, true)
                    end = cursor
                    break
                }
                if !final,
                    isStrictPrefix(at: cursor, of: Self.endMessageBytes)
                        || isStrictPrefix(at: cursor, of: Self.endOfSamplingBytes)
                {
                    end = cursor
                    break
                }
                if answerFromHeader {
                    // Any marker ends it, unread: the boundary takes it, as after a dropped header.
                    // A marker's prefix waits for its bytes, and at the end it is never text.
                    let next = match(at: cursor)
                    if case .marker = next { close = (0, false); end = cursor; break }
                    if case .partial = next { end = cursor; if final { close = (pending.count - cursor, false) }; break }
                }
            }
            cursor += 1
        }
        let textEnd = end ?? pending.count
        if textEnd > index {
            let text = String(decoding: pending[index..<textEnd], as: UTF8.self)
            switch kind {
            case .reasoning:
                hasReasoning = true
                pieces.append(.reasoning(text))
            case .content:
                pieces.append(.content(text))
            case .ignored:
                droppedBytes += textEnd - index
            case .toolCall:
                break
            }
        }
        guard let close else {
            // Either all read, or a possible closing marker waits for bytes.
            return textEnd == index && end != nil ? nil : textEnd
        }
        if close.endsOutput {
            // The engine's stop arrived as text inside the message.
            switch kind {
            case .reasoning: unterminatedChannel = .reasoning
            case .content: unterminatedChannel = .content
            default: break
            }
            endedByMarker = true
            state = .ended
        } else {
            state = .boundary
        }
        return textEnd + close.length
    }

    /// One call's JSON, up to `<|end_message|>` outside its strings.
    private mutating func readToolBody(
        from index: Int, final: Bool, into pieces: inout [Inkling2OutputPiece]
    ) -> Int? {
        var cursor = index
        while cursor < pending.count {
            let byte = pending[cursor]
            if byte == Self.lessThan, !json.inString {
                if hasPrefix(Self.endMessageBytes, at: cursor) {
                    closeToolFrame(into: &pieces)
                    state = .boundary
                    return cursor + Self.endMessageBytes.count
                }
                if hasPrefix(Self.endOfSamplingBytes, at: cursor) {
                    toolFailures.append(.unterminated)
                    unterminatedChannel = .toolCall
                    toolBody = []
                    endedByMarker = true
                    state = .ended
                    return cursor + Self.endOfSamplingBytes.count
                }
                if !final,
                    isStrictPrefix(at: cursor, of: Self.endMessageBytes)
                        || isStrictPrefix(at: cursor, of: Self.endOfSamplingBytes)
                {
                    return cursor == index ? nil : cursor
                }
            }
            json.consume(byte, depthLimit: limits.toolNestingDepth)
            toolBody.append(byte)
            cursor += 1
            if toolBody.count > limits.toolBodyBytes {
                // The frame owns the rest of the output; nothing after it is read.
                toolFailures.append(.bodyTooLarge)
                toolBody = []
                state = .ended
                bytesAfterEnd += pending.count - cursor
                return pending.count
            }
        }
        return cursor
    }

    private mutating func closeToolFrame(into pieces: inout [Inkling2OutputPiece]) {
        defer {
            toolBody = []
            header = []
        }
        if json.exceededDepth {
            toolFailures.append(.nestingTooDeep)
            return
        }
        switch Self.parseCall(body: toolBody, header: header) {
        case .success(let call): pieces.append(.toolCall(call))
        case .failure(let failure): toolFailures.append(failure)
        }
    }

    /// `{"name": NAME, "args": {...}}`, exactly the two keys the template
    /// renders. Nesting is bounded before this runs.
    static func parseCall(body: [UInt8], header: [UInt8]) -> Result<ToolCall, Inkling2ToolFrameFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: Data(body)) else {
            return .failure(.invalidJSON)
        }
        guard let root = object as? [String: Any], root.count == 2,
            let name = root["name"] as? String, !name.isEmpty,
            let arguments = root["args"] as? [String: Any]
        else { return .failure(.wrongShape) }
        if !header.isEmpty, String(decoding: header, as: UTF8.self) != name {
            return .failure(.nameMismatch)
        }
        return .success(ToolCall(function: .init(name: name, arguments: arguments.mapValues { MLXLMCommon.JSONValue.from($0) })))
    }

    // MARK: - Markers

    private enum Match {
        case marker(Marker, length: Int)
        case partial
        case none
    }

    private func match(at index: Int) -> Match {
        var partial = false
        for (bytes, marker) in Self.markers {
            if hasPrefix(bytes, at: index) { return .marker(marker, length: bytes.count) }
            if isStrictPrefix(at: index, of: bytes) { partial = true }
        }
        return partial ? .partial : .none
    }

    private func hasPrefix(_ bytes: [UInt8], at index: Int) -> Bool {
        guard pending.count - index >= bytes.count else { return false }
        return pending[index..<(index + bytes.count)].elementsEqual(bytes)
    }

    /// The rest of `pending` from `index` is a proper prefix of `bytes`.
    private func isStrictPrefix(at index: Int, of bytes: [UInt8]) -> Bool {
        let available = pending.count - index
        guard available > 0, available < bytes.count else { return false }
        return pending[index...].elementsEqual(bytes[0..<available])
    }
}

/// String and nesting state of one JSON text, byte by byte, without decoding.
/// Enough to tell a marker in a string (data) from one between values, and to
/// refuse nesting deeper than a bound before any decoder sees the text.
struct BoundedJSONShape: Equatable, Sendable {
    private(set) var inString = false
    private var escaped = false
    private var depth = 0
    private(set) var exceededDepth = false

    mutating func consume(_ byte: UInt8, depthLimit: Int) {
        if inString {
            if escaped {
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: "\"") {
                inString = false
            }
            return
        }
        switch byte {
        case UInt8(ascii: "\""):
            inString = true
        case UInt8(ascii: "{"), UInt8(ascii: "["):
            depth += 1
            if depth > depthLimit { exceededDepth = true }
        case UInt8(ascii: "}"), UInt8(ascii: "]"):
            depth = max(0, depth - 1)
        default:
            break
        }
    }
}
