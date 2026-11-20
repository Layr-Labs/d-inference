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
/// It follows the canonical XML frame only: `<tool_call>`, framing whitespace,
/// `<function=NAME>`, then `<parameter=KEY>VALUE</parameter>` entries and
/// `</function>`, `</tool_call>`, each separated by framing whitespace alone.
/// A value is read as the parameter scanner reads it: only `</parameter>` ends
/// it. Anything else (the JSON dialect, text between the tags) stops it for the
/// rest of the answer, so it never closes a frame the parser would not read.
/// Only a frame whose function is named is closed, from a value or between
/// tags; text that ends inside a tag is left as it is and the call stays
/// `unterminated`.
struct QwenOpenCallFrame {
    private enum Position: Equatable {
        case outside
        /// After `<tool_call>`, before `<function=`.
        case frameStart
        case functionName
        /// After `<function=NAME>` or a `</parameter>`.
        case betweenParameters
        case parameterName
        case parameter
        /// After `</function>`, before `</tool_call>`.
        case afterFunction
        /// Text this does not read as a canonical XML frame: never closes.
        case stopped
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
    /// The tag being matched, or (outside and in a value) the text that may
    /// still end with the tag looked for.
    private var token: [Unicode.Scalar] = []
    private var lastScalar: Unicode.Scalar?

    mutating func observe(_ text: String) {
        for scalar in text.unicodeScalars {
            lastScalar = scalar
            consume(scalar)
        }
    }

    /// The framing that closes the open frame at the end of the output, or nil
    /// when there is nothing this closes.
    var closingAtEnd: String? {
        switch position {
        case .parameter:
            guard !endsWithProperPrefix(of: Self.parameterClose) else { return nil }
            return (lastScalar == "\n" ? "" : "\n") + "</parameter>\n</function>\n</tool_call>"
        case .betweenParameters:
            return token.isEmpty ? "\n</function>\n</tool_call>" : nil
        case .afterFunction:
            return token.isEmpty ? "\n</tool_call>" : nil
        case .outside, .frameStart, .functionName, .parameterName, .stopped:
            return nil
        }
    }

    private mutating func consume(_ scalar: Unicode.Scalar) {
        switch position {
        case .outside:
            if append(scalar, endsWith: Self.frameOpen) { position = .frameStart }
        case .frameStart:
            match(scalar, against: [(Self.functionOpen, .functionName)])
        case .functionName, .parameterName:
            if scalar == ">" {
                guard !token.isEmpty else { return stop() }
                token = []
                position = position == .functionName ? .betweenParameters : .parameter
            } else if scalar.properties.isWhitespace || token.count >= Self.nameLimit {
                stop()
            } else {
                token.append(scalar)
            }
        case .betweenParameters:
            match(scalar, against: [(Self.parameterOpen, .parameterName), (Self.functionClose, .afterFunction)])
        case .parameter:
            if append(scalar, endsWith: Self.parameterClose) { position = .betweenParameters }
        case .afterFunction:
            match(scalar, against: [(Self.frameClose, .outside)])
        case .stopped:
            return
        }
    }

    /// Between tags: framing whitespace, or one of `tags` scalar by scalar.
    private mutating func match(_ scalar: Unicode.Scalar, against tags: [([Unicode.Scalar], Position)]) {
        if token.isEmpty, scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\r" { return }
        token.append(scalar)
        if let (_, next) = tags.first(where: { $0.0 == token }) {
            token = []
            position = next
        } else if !tags.contains(where: { $0.0.starts(with: token) }) {
            stop()
        }
    }

    /// Free text (outside a frame, or a value): keeps only what can still end
    /// with `tag`; true once it does.
    private mutating func append(_ scalar: Unicode.Scalar, endsWith tag: [Unicode.Scalar]) -> Bool {
        token.append(scalar)
        if token.count >= tag.count, Array(token.suffix(tag.count)) == tag {
            token = []
            return true
        }
        if token.count > tag.count { token.removeFirst(token.count - tag.count) }
        return false
    }

    private mutating func stop() {
        token = []
        position = .stopped
    }

    /// Whether the value ends with a proper, non-empty prefix of `tag`: the
    /// output stopped inside that tag.
    private func endsWithProperPrefix(of tag: [Unicode.Scalar]) -> Bool {
        let longest = min(tag.count - 1, token.count)
        guard longest > 0 else { return false }
        return (1...longest).contains { Array(token.suffix($0)) == Array(tag.prefix($0)) }
    }
}
