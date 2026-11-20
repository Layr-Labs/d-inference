import Foundation

/// Where the last Qwen 3.5–3.8 XML call frame stands in the answer text the
/// tool handler has read, and the framing that closes it when the output ends
/// inside it (`QwenOpenCallClosurePolicy`).
///
/// The model sometimes ends its turn inside a call: on long forced writes (a
/// whole file through one string parameter), it stops right after the last
/// line of the value, before `</parameter>`, `</function>` and
/// `</tool_call>`. The value and the call are complete; only the closing
/// framing is missing. Such a frame is closed when generation ends on its own,
/// as the Qwen3-Coder reference parser reads a frame the text ends inside.
///
/// Only a frame whose function is named is closed, and only from a string
/// value or from between parameters. Text that ends inside a tag (a parameter
/// or function name, or a partial closing tag) is left as it is, so the call
/// stays `unterminated`. A value is read as the parameter scanner reads it:
/// only `</parameter>` ends it.
struct QwenOpenCallFrame {
    private enum Position: Equatable {
        case outside
        case frame
        case functionName
        case function
        case parameterName
        case parameter
        case functionClosed
    }

    private static let frameOpen = Array("<tool_call>".unicodeScalars)
    private static let frameClose = Array("</tool_call>".unicodeScalars)
    private static let functionOpen = Array("<function=".unicodeScalars)
    private static let functionClose = Array("</function>".unicodeScalars)
    private static let parameterOpen = Array("<parameter=".unicodeScalars)
    private static let parameterClose = Array("</parameter>".unicodeScalars)
    /// The argument streamer's tag limit: a longer name is not a frame it reads.
    private static let nameLimit = 256

    private var position = Position.outside
    /// Text after the last resolved position that may still start a tag.
    private var pending: [Unicode.Scalar] = []
    private var lastScalar: Unicode.Scalar?

    mutating func observe(_ text: String) {
        for scalar in text.unicodeScalars {
            lastScalar = scalar
            pending.append(scalar)
            resolve()
        }
    }

    /// The framing that closes the open frame at the end of the output, or nil
    /// when there is nothing this closes.
    var closingAtEnd: String? {
        switch position {
        case .parameter:
            guard !endsInsideTag(Self.parameterClose) else { return nil }
            return (lastScalar == "\n" ? "" : "\n") + "</parameter>\n</function>\n</tool_call>"
        case .function:
            guard !endsInsideTag(Self.functionClose), !endsInsideTag(Self.parameterOpen) else { return nil }
            return "\n</function>\n</tool_call>"
        case .functionClosed:
            guard !endsInsideTag(Self.frameClose) else { return nil }
            return "\n</tool_call>"
        case .outside, .frame, .functionName, .parameterName:
            return nil
        }
    }

    private mutating func resolve() {
        switch position {
        case .outside:
            if advance(past: Self.frameOpen) { position = .frame }
        case .frame:
            if advance(past: Self.functionOpen) { position = .functionName }
            else if advance(past: Self.frameClose) { position = .outside }
        case .functionName:
            if pending.last == ">" { pending = []; position = .function }
            else if pending.count > Self.nameLimit { pending = []; position = .outside }
        case .function:
            if advance(past: Self.parameterOpen) { position = .parameterName }
            else if advance(past: Self.functionClose) { position = .functionClosed }
        case .parameterName:
            if pending.last == ">" { pending = []; position = .parameter }
            else if pending.count > Self.nameLimit { pending = []; position = .outside }
        case .parameter:
            if advance(past: Self.parameterClose) { position = .function }
        case .functionClosed:
            if advance(past: Self.frameClose) { position = .outside }
        }
        // Keep only what can still begin a tag.
        let keep = Self.frameClose.count
        if pending.count > keep, position != .functionName, position != .parameterName {
            pending.removeFirst(pending.count - keep)
        }
    }

    /// Whether `pending` ends with `tag`; if so, clears it.
    private mutating func advance(past tag: [Unicode.Scalar]) -> Bool {
        guard pending.count >= tag.count, Array(pending.suffix(tag.count)) == tag else { return false }
        pending = []
        return true
    }

    /// Whether the text ends with a proper, non-empty prefix of `tag` (at least
    /// its `<`): the output stopped inside that tag.
    private func endsInsideTag(_ tag: [Unicode.Scalar]) -> Bool {
        for length in stride(from: min(tag.count - 1, pending.count), through: 1, by: -1)
        where Array(pending.suffix(length)) == Array(tag.prefix(length)) {
            return true
        }
        return false
    }
}
