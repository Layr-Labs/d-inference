import MLXLMServer

/// The trained thought envelope may open only at the response boundary.
/// Once visible content/tool framing starts, all marker-looking bytes are data.
/// EOS/turn tokens are handled by the native generator, not string replacement.
struct DiffusionGemmaChannelSplitter {
    private enum State { case boundary, reasoning, content }
    private let opening = "<|channel>thought\n"
    private let emptyEnvelope = "<|channel>thought<channel|>"
    private let closing = "<channel|>"
    private var state: State = .boundary
    private var pending = ""

    mutating func parse(_ text: String) -> [ParsedReasoning] {
        pending += text
        return drain(final: false)
    }
    mutating func finish() -> [ParsedReasoning] { drain(final: true) }

    private mutating func drain(final: Bool) -> [ParsedReasoning] {
        var pieces = [ParsedReasoning]()
        while !pending.isEmpty {
            switch state {
            case .boundary:
                let first = pending.firstIndex { $0 != " " && $0 != "\t" && $0 != "\r" && $0 != "\n" }
                guard let first else {
                    if final { pieces.append(.init(content: pending, reasoningContent: nil)); pending = "" }
                    return pieces
                }
                let tail = String(pending[first...])
                if final, tail.hasPrefix("<|channel>"),
                    [opening, emptyEnvelope].contains(where: { $0.hasPrefix(tail) && tail.count < $0.count })
                {
                    // A length stop can land inside the initial protocol
                    // header. It contains no answer/argument bytes to publish.
                    let framing = String(pending[..<first])
                    if !framing.isEmpty { pieces.append(.init(content: framing, reasoningContent: nil)) }
                    pending = ""
                    return pieces
                }
                if !final, [opening, emptyEnvelope].contains(where: { $0.hasPrefix(tail) && tail.count < $0.count }) {
                    return pieces
                }
                if tail.hasPrefix(emptyEnvelope) {
                    let framing = String(pending[..<first])
                    if !framing.isEmpty { pieces.append(.init(content: framing, reasoningContent: nil)) }
                    pending = String(tail.dropFirst(emptyEnvelope.count))
                    state = .content
                } else if tail.hasPrefix(opening) {
                    let framing = String(pending[..<first])
                    if !framing.isEmpty { pieces.append(.init(content: framing, reasoningContent: nil)) }
                    pending = String(tail.dropFirst(opening.count))
                    state = .reasoning
                } else {
                    state = .content
                }
            case .reasoning:
                if let end = pending.range(of: closing) {
                    let thought = String(pending[..<end.lowerBound])
                    if !thought.isEmpty { pieces.append(.init(content: "", reasoningContent: thought)) }
                    pending = String(pending[end.upperBound...])
                    state = .content
                } else {
                    let held = final ? 0 : suffixPrefixLength(pending, marker: closing)
                    let thought = String(pending.dropLast(held))
                    if !thought.isEmpty { pieces.append(.init(content: "", reasoningContent: thought)) }
                    pending = String(pending.suffix(held))
                    return pieces
                }
            case .content:
                pieces.append(.init(content: pending, reasoningContent: nil))
                pending = ""
            }
        }
        return pieces
    }

    private func suffixPrefixLength(_ value: String, marker: String) -> Int {
        let maximum = min(value.count, marker.count - 1)
        guard maximum > 0 else { return 0 }
        for length in stride(from: maximum, through: 1, by: -1) {
            if value.suffix(length) == marker.prefix(length) { return length }
        }
        return 0
    }
}
