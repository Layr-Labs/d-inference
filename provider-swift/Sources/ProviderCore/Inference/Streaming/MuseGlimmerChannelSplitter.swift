// Copyright © 2026 Eigen Labs.

import Foundation

/// Text-level splitter for Muse Glimmer's framed output.
///
/// The generation prompt ends with `<|start|>assistant`. The model then writes
/// one or more messages, each `[ to=<recipient>]<|message|><body>`, joined by
/// `<|eom|><|start|>assistant` and ended by `<|eot|>`, a stop token whose text
/// normally never arrives:
///
///   - `to=self` is reasoning;
///   - `to=user`, or no recipient, is the answer;
///   - any other recipient is a tool channel carrying ATEM invokes.
///
/// No framing reaches reasoning or the answer at any chunking: a tail that
/// could still become a marker or a ` to=` header is held until it resolves.
/// Tool markup is read only on a tool channel, so an invoke quoted in reasoning
/// or in the answer stays text. A body also ends at the next header, with or
/// without `<|eom|>`: the model sometimes leaves reasoning with a bare
/// ` to=<tool><|message|>`, and the call after it must not be lost.
///
/// The engine hands the provider text, not token IDs, so marker-shaped text a
/// model spells with ordinary tokens is read as framing. The reference servers
/// parse the same text and share that limit.
struct MuseGlimmerChannelSplitter {
    enum Piece: Equatable {
        case reasoning(String)
        case content(String)
        /// One complete `<atem:invoke>` element from a tool channel, verbatim.
        case invoke(String)
        /// A tool channel ended holding tool markup that is no complete invoke.
        case malformedToolFrame
    }

    static let start = "<|start|>"
    static let message = "<|message|>"
    static let endOfMessage = "<|eom|>"
    static let endOfTurn = "<|eot|>"
    static let endOfText = "<|end_of_text|>"
    /// Every marker that ends a body or a header.
    static let markers = [start, message, endOfMessage, endOfTurn, endOfText]
    static let invokeOpen = "<atem:invoke"
    static let invokeClose = "</atem:invoke>"
    private static let wrapperTags = ["<atem:function_calls>", "</atem:function_calls>"]
    /// A header is a role and a recipient; anything longer is not one.
    static let maximumHeaderCharacters = 512

    private enum Channel { case reasoning, content, tool, ignored }

    private enum State {
        /// Reading a header up to `<|message|>`. `explicit`: it follows
        /// `<|start|>`, so it must name the assistant role. Otherwise the role
        /// is the generation prompt's, or implied after a message boundary.
        case header(text: String, explicit: Bool)
        case body(Channel)
    }

    private var state: State = .header(text: "", explicit: false)
    /// Input not yet classified: a tail that may still become framing.
    private var buffer = ""
    /// Tool-channel text not yet consumed as invokes.
    private var toolBody = ""
    /// The open body is empty or ends in whitespace, so a ` to=` header may
    /// start at the next character.
    private var bodyAtWordBoundary = true

    var bufferedCharacterCount: Int { buffer.count + toolBody.count }

    mutating func parse(_ text: String) -> [Piece] {
        buffer += text
        return drain(final: false, truncated: false)
    }

    /// End of generation. `truncated`: the output-token limit ended it, so a
    /// tool call cut off mid-invoke is dropped, not reported as malformed.
    mutating func finish(truncated: Bool = false) -> [Piece] {
        var pieces = drain(final: true, truncated: truncated)
        closeFrame(truncated: truncated, into: &pieces)
        state = .header(text: "", explicit: false)
        return pieces
    }

    private mutating func drain(final: Bool, truncated: Bool) -> [Piece] {
        var pieces: [Piece] = []
        while true {
            switch state {
            case .header(let text, let explicit):
                guard drainHeader(text: text, explicit: explicit, final: final) else { return pieces }
            case .body(let channel):
                guard drainBody(channel, final: final, truncated: truncated, into: &pieces) else {
                    return pieces
                }
            }
        }
    }

    /// Returns false when it needs more input.
    private mutating func drainHeader(text: String, explicit: Bool, final: Bool) -> Bool {
        let found = firstMarker(in: buffer)
        let held = found == nil && !final ? Self.partialMarkerLength(atEndOf: buffer) : 0
        let split = found?.1.lowerBound ?? buffer.index(buffer.endIndex, offsetBy: -held)
        let header = text + buffer[..<split]
        if !explicit, !Self.couldBecomeHeader(found == nil ? header + buffer[split...] : header) {
            // No framing arrived: text outside any message is the answer.
            buffer = header + buffer[split...]
            openBody(.content)
            return true
        }
        if let (marker, range) = found {
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            switch marker {
            case Self.message:
                openBody(Self.channel(forHeader: header, explicit: explicit))
            case Self.start:
                state = .header(text: "", explicit: true)
            default:
                // A header that ended before its body opens nothing.
                state = .header(text: "", explicit: false)
            }
            return true
        }
        buffer.removeSubrange(buffer.startIndex..<split)
        guard header.count <= Self.maximumHeaderCharacters else {
            openBody(.ignored)
            return true
        }
        state = .header(text: header, explicit: explicit)
        return false
    }

    private mutating func openBody(_ channel: Channel) {
        state = .body(channel)
        bodyAtWordBoundary = true
    }

    /// Returns false when it needs more input.
    private mutating func drainBody(
        _ channel: Channel, final: Bool, truncated: Bool, into pieces: inout [Piece]
    ) -> Bool {
        if let (marker, range) = firstMarker(in: buffer) {
            var text = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if marker == Self.message {
                // A header written inside this body: the body ends before it.
                let header = Self.trailingHeader(in: text, atWordBoundary: bodyAtWordBoundary)
                let recipient = String(text[header.recipient...])
                text.removeSubrange(header.lowerBound..<text.endIndex)
                emit(text, on: channel, into: &pieces)
                closeFrame(truncated: false, into: &pieces)
                openBody(Self.channel(forHeader: recipient, explicit: false))
                return true
            }
            emit(text, on: channel, into: &pieces)
            closeFrame(truncated: false, into: &pieces)
            state = .header(text: "", explicit: marker == Self.start)
            return true
        }
        var end = buffer.endIndex
        if !final {
            end = buffer.index(end, offsetBy: -Self.partialMarkerLength(atEndOf: buffer))
            if let candidate = Self.headerCandidate(
                atEndOf: buffer[..<end], atWordBoundary: bodyAtWordBoundary) { end = candidate }
        }
        let text = String(buffer[..<end])
        buffer.removeSubrange(buffer.startIndex..<end)
        emit(text, on: channel, into: &pieces)
        return false
    }

    private mutating func emit(_ text: String, on channel: Channel, into pieces: inout [Piece]) {
        guard let last = text.last else { return }
        bodyAtWordBoundary = last.isWhitespace
        switch channel {
        case .reasoning: pieces.append(.reasoning(text))
        case .content: pieces.append(.content(text))
        case .ignored: break
        case .tool:
            toolBody += text
            while let invoke = Self.firstInvoke(in: toolBody) {
                pieces.append(.invoke(String(toolBody[invoke])))
                toolBody.removeSubrange(toolBody.startIndex..<invoke.upperBound)
            }
        }
    }

    /// Ends the open message. Text left on a tool channel is the wrapper and
    /// whitespace of a complete call, or tool markup that never completed.
    private mutating func closeFrame(truncated: Bool, into pieces: inout [Piece]) {
        defer { toolBody = "" }
        guard !truncated, toolBody.contains("<atem:") else { return }
        var remainder = toolBody
        for tag in Self.wrapperTags { remainder = remainder.replacingOccurrences(of: tag, with: "") }
        if remainder.contains("<atem:") || remainder.contains("</atem:") {
            pieces.append(.malformedToolFrame)
        }
    }

    // MARK: - Framing

    private func firstMarker(in text: String) -> (String, Range<String.Index>)? {
        Self.markers.compactMap { marker in text.range(of: marker).map { (marker, $0) } }
            .min { $0.1.lowerBound < $1.1.lowerBound }
    }

    /// The longest suffix of `text` that is a proper prefix of a marker.
    private static func partialMarkerLength(atEndOf text: String) -> Int {
        let longest = (markers.map(\.count).max() ?? 1) - 1
        guard longest > 0, !text.isEmpty else { return 0 }
        for count in stride(from: min(text.count, longest), through: 1, by: -1) {
            let suffix = text.suffix(count)
            if markers.contains(where: { $0.hasPrefix(suffix) }) { return count }
        }
        return 0
    }

    private static func channel(forHeader header: String, explicit: Bool) -> Channel {
        var fields = header.split(whereSeparator: \.isWhitespace)
        if fields.first == "assistant" {
            fields.removeFirst()
        } else if explicit {
            // Another role's message is not assistant output.
            return .ignored
        }
        guard let recipient = fields.last(where: { $0.hasPrefix("to=") })?.dropFirst(3) else {
            return .content
        }
        switch recipient {
        case "self": return .reasoning
        case "user": return .content
        case "": return .ignored
        default: return .tool
        }
    }

    /// Whether text outside any message may still grow into a header whose
    /// role is implied: optional whitespace, an optional `to=<recipient>`,
    /// then `<|message|>`.
    private static func couldBecomeHeader(_ text: String) -> Bool {
        var rest = text[...].drop(while: \.isWhitespace)
        if rest.isEmpty || "to=".hasPrefix(rest) { return true }
        if rest.hasPrefix("to=") {
            rest = rest.dropFirst(3)
            rest = rest.drop(while: { !$0.isWhitespace && $0 != "<" })
            rest = rest.drop(while: \.isWhitespace)
        }
        return rest.isEmpty || markers.contains { $0.hasPrefix(rest) }
    }

    /// The ` to=<recipient>` a body ends with when `<|message|>` follows it,
    /// with the whitespace before it; empty text when the header names none.
    private static func trailingHeader(
        in text: String, atWordBoundary: Bool
    ) -> (lowerBound: String.Index, recipient: String.Index) {
        let word = lastWordStart(in: text[...])
        guard text[word...].hasPrefix("to="),
            startsWord(word, in: text[...], atWordBoundary: atWordBoundary)
        else { return (text.endIndex, text.endIndex) }
        return (horizontalSpaceStart(before: word, in: text[...]), word)
    }

    /// Where a still-growing body's tail may be the start of such a header:
    /// spaces, then nothing yet, `t`, `to` or `to=<recipient so far>`.
    private static func headerCandidate(atEndOf text: Substring, atWordBoundary: Bool) -> String.Index? {
        let start = lastWordStart(in: text)
        let word = text[start...]
        if word.isEmpty {
            let space = horizontalSpaceStart(before: start, in: text)
            return space < text.endIndex ? space : nil
        }
        guard word.hasPrefix("to=") || "to=".hasPrefix(word),
            startsWord(start, in: text, atWordBoundary: atWordBoundary)
        else { return nil }
        return horizontalSpaceStart(before: start, in: text)
    }

    /// Where the run of characters ending `text` begins: after its last
    /// whitespace or `<`.
    private static func lastWordStart(in text: Substring) -> String.Index {
        var start = text.endIndex
        while start > text.startIndex {
            let previous = text.index(before: start)
            if text[previous].isWhitespace || text[previous] == "<" { break }
            start = previous
        }
        return start
    }

    /// Whether whitespace, or the start of the body, precedes `index`.
    private static func startsWord(_ index: String.Index, in text: Substring, atWordBoundary: Bool) -> Bool {
        index == text.startIndex ? atWordBoundary : text[text.index(before: index)].isWhitespace
    }

    private static func horizontalSpaceStart(before index: String.Index, in text: Substring) -> String.Index {
        var start = index
        while start > text.startIndex, text[text.index(before: start)].isHorizontalSpace {
            start = text.index(before: start)
        }
        return start
    }

    /// The first complete `<atem:invoke …>…</atem:invoke>` element.
    private static func firstInvoke(in text: String) -> Range<String.Index>? {
        var search = text.startIndex
        while let open = text.range(of: invokeOpen, range: search..<text.endIndex) {
            let boundary = open.upperBound
            guard boundary < text.endIndex else { return nil }
            if text[boundary].isWhitespace || text[boundary] == ">" {
                guard let close = text.range(of: invokeClose, range: boundary..<text.endIndex) else {
                    return nil
                }
                return open.lowerBound..<close.upperBound
            }
            search = boundary
        }
        return nil
    }
}

private extension Character {
    var isHorizontalSpace: Bool { self == " " || self == "\t" }
}
