import MLXLMServer

/// Reference reasoning split for Super: vLLM `ultra_v3` over `deepseek_r1`.
/// The pinned prompt owns the opening `<think>` (thinking on) or a closed
/// `<think></think>` (thinking off), so generated text starts inside the
/// reasoning channel or in content respectively.
///
/// Streaming follows the token-level parser: in reasoning, `<think>` deltas
/// are dropped and the first `</think>` ends reasoning; every later byte is
/// content, including literal markers. With `force_nonempty_content`, a
/// stream whose reasoning never closes repeats it as content at the end
/// (vLLM `nemotron_v3`). A complete response follows
/// `extract_reasoning`: text before the first `<think>` is discarded, the
/// first `</think>` splits, a leading newline is removed only when the output
/// itself opened the span, and `force_nonempty_content` turns unterminated
/// reasoning into content. Thinking off makes all output content. Markers
/// match literally, as the reference matches code points or marker tokens: a
/// combining mark after `>` does not hide one.
struct NemotronSuperReasoningChannel {
    static let open = "<think>"
    static let close = "</think>"

    struct Split: Equatable {
        var reasoning: String?
        var content: String?
    }

    private let thinking: Bool
    private let forceNonemptyContent: Bool
    private var inReasoning: Bool
    private var held = ""

    init(controls: NemotronSuperPromptContract.Controls) {
        thinking = controls.enableThinking
        forceNonemptyContent = controls.forceNonemptyContent
        inReasoning = controls.enableThinking
    }

    /// Incremental split; concatenated results equal the streamed reference.
    mutating func stream(_ text: String) -> [ParsedReasoning] {
        guard inReasoning else { return text.isEmpty ? [] : [.init(content: text, reasoningContent: nil)] }
        held += text
        var pieces: [ParsedReasoning] = []
        while inReasoning, !held.isEmpty {
            let earliest = [Self.open, Self.close].compactMap { marker in
                held.range(of: marker, options: .literal).map { (marker, $0) }
            }.min { $0.1.lowerBound < $1.1.lowerBound }
            guard let (marker, range) = earliest else {
                let keep = Self.partialMarkerSuffix(held)
                let split = held.index(held.endIndex, offsetBy: -keep)
                append(String(held[..<split]), reasoning: true, to: &pieces)
                held = String(held[split...])
                return pieces
            }
            append(String(held[..<range.lowerBound]), reasoning: true, to: &pieces)
            held = String(held[range.upperBound...])
            if marker == Self.close { inReasoning = false }
        }
        if !inReasoning {
            append(held, reasoning: false, to: &pieces)
            held = ""
        }
        return pieces
    }

    /// End of a streamed response: an incomplete marker is ordinary text.
    mutating func finishStream() -> [ParsedReasoning] {
        defer { held = "" }
        var pieces: [ParsedReasoning] = []
        append(held, reasoning: inReasoning, to: &pieces)
        return pieces
    }

    /// At the end of a stream: thinking never reached `</think>`, so no
    /// content exists, and the request forces content from its reasoning.
    var promotesUnterminatedReasoning: Bool { forceNonemptyContent && inReasoning }

    /// `UltraV3ReasoningParser.extract_reasoning` for a complete output.
    func complete(_ output: String) -> Split {
        guard thinking else { return Split(reasoning: nil, content: output.isEmpty ? nil : output) }
        var body = Substring(output)
        let opened = output.range(of: Self.open, options: .literal)
        if let opened { body = output[opened.upperBound...] }
        var split: Split
        if let closed = body.range(of: Self.close, options: .literal) {
            let content = body[closed.upperBound...]
            split = Split(reasoning: String(body[..<closed.lowerBound]),
                          content: content.isEmpty ? nil : String(content))
        } else {
            split = Split(reasoning: String(body), content: nil)
        }
        if opened != nil, let reasoning = split.reasoning, reasoning.hasPrefix("\n") {
            split.reasoning = String(reasoning.dropFirst())
        }
        if split.content == nil, forceNonemptyContent {
            split = Split(reasoning: nil, content: split.reasoning)
        }
        return split
    }

    private func append(_ text: String, reasoning: Bool, to pieces: inout [ParsedReasoning]) {
        guard !text.isEmpty else { return }
        pieces.append(reasoning ? .init(content: "", reasoningContent: text)
                                : .init(content: text, reasoningContent: nil))
    }

    private static func partialMarkerSuffix(_ text: String) -> Int {
        let limit = min(text.count, close.count - 1)
        guard limit > 0 else { return 0 }
        for count in (1...limit).reversed() {
            let suffix = text.suffix(count)
            if open.hasPrefix(suffix) || close.hasPrefix(suffix) { return count }
        }
        return 0
    }
}
