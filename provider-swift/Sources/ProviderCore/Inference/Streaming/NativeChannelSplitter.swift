import Foundation
import MLXLMCommon
import MLXLMServer

/// Bounded native think-channel lexer. Tool frames are opaque argument data:
/// reasoning markers within them are never interpreted as channel controls.
/// Conversely, tool frames inside reasoning remain reasoning, not invocations.
///
/// Content-state `</think>` handling follows the vendor-documented Nemotron
/// parser (vLLM `nemotron_v3`, which reuses the qwen3 parser-engine config):
/// when explicitly enabled, a close already in content is absorbed and the text
/// before it stays content. It is never reinterpreted as a reasoning boundary.
struct NativeChannelSplitter {
    private enum State { case content, reasoning, tool(end: String) }
    private var state: State
    private var buffer = ""
    private let protectToolFrames: Bool
    private let qwenStructuredFrames: Bool
    private var toolScanner: Qwen35ToolFrameScanner?
    private let flintFrames: Bool
    private let tools: [[String: any Sendable]]?
    private var flintScanner: FlintToolFrameScanner?
    private let preserveInnerReasoningSpans: Bool
    private let absorbStrayThinkClose: Bool
    private let promotesTrailingCalls: Bool
    /// The open thought's text (kept only with `promotesTrailingCalls`).
    private var openThought = ""
    private var innerReasoningDepth = 0
    private(set) var reasoningNestingLimitExceeded = false
    static let maximumInnerReasoningDepth = 32
    var bufferedCharacterCount: Int {
        buffer.count + (toolScanner?.bufferedCharacterCount ?? 0)
            + (flintScanner?.bufferedCharacterCount ?? 0)
    }

    /// `promotesTrailingCalls`: a thought that never closes and ends in
    /// complete `<tool_call>` frames (whitespace only between and after them)
    /// was the model calling from inside it, a known Qwen 3.5 failure mode;
    /// at the end of the output those frames are also returned as content,
    /// so they parse as calls. A frame followed by more thought, or by
    /// `</think>`, stays reasoning.
    init(prefix: String, protectToolFrames: Bool, qwenStructuredFrames: Bool = false, flintFrames: Bool = false,
         tools: [[String: any Sendable]]? = nil,
         preserveInnerReasoningSpans: Bool = false, absorbStrayThinkClose: Bool = false,
         promotesTrailingCalls: Bool = false) {
        state = prefix == "<think>" ? .reasoning : .content
        self.protectToolFrames = protectToolFrames
        self.qwenStructuredFrames = qwenStructuredFrames
        self.flintFrames = flintFrames
        self.tools = tools
        self.preserveInnerReasoningSpans = preserveInnerReasoningSpans
        self.absorbStrayThinkClose = absorbStrayThinkClose
        self.promotesTrailingCalls = promotesTrailingCalls
    }

    mutating func parse(_ text: String) -> [ParsedReasoning] {
        guard !reasoningNestingLimitExceeded else { return [] }
        buffer += text
        return drain(final: false)
    }

    mutating func finish() -> [ParsedReasoning] {
        guard !reasoningNestingLimitExceeded else { return [] }
        var pieces = drain(final: true)
        toolScanner = nil
        flintScanner = nil
        if promotesTrailingCalls, case .reasoning = state, let calls = Self.trailingCalls(in: openThought) {
            pieces.append(.init(content: calls, reasoningContent: nil))
        }
        openThought = ""
        return pieces
    }

    /// The complete `<tool_call>` frames that end `thought`, with the
    /// whitespace between them, or nil. A frame opens on `<function=` or `{`
    /// (a mentioned tag does not), and its end follows the Qwen tool parser's
    /// own scanner (JSON strings and XML parameter values are opaque, so a tag
    /// inside an argument is not a frame).
    static func trailingCalls(in thought: String) -> String? {
        var start: String.Index?
        var end = thought.endIndex
        while true {
            var last = end
            while last > thought.startIndex, thought[thought.index(before: last)].isWhitespace {
                last = thought.index(before: last)
            }
            guard thought[..<last].hasSuffix("</tool_call>"),
                let frame = outermostFrame(in: thought, closingAt: last) else { break }
            start = frame
            end = frame
        }
        return start.map { String(thought[$0...]) }
    }

    /// The first `<tool_call>` before `end` whose frame opens a call and
    /// closes exactly at `end`.
    private static func outermostFrame(in thought: String, closingAt end: String.Index) -> String.Index? {
        let scalars = thought.unicodeScalars
        var from = thought.startIndex
        while let open = thought.range(of: "<tool_call>", range: from..<end) {
            from = open.upperBound
            let payload = thought[open.upperBound..<end].drop { $0.isWhitespace }
            guard payload.hasPrefix("<function=") || payload.hasPrefix("{") else { continue }
            var scanner = Qwen35ToolFrameScanner(endTag: "</tool_call>")
            var index = open.upperBound
            while index < end {
                let next = scalars.index(after: index)
                if scanner.consume(scalars[index]) {
                    if next == end { return open.lowerBound }
                    break
                }
                index = next
            }
        }
        return nil
    }

    private mutating func drain(final: Bool) -> [ParsedReasoning] {
        var result: [ParsedReasoning] = []
        while !buffer.isEmpty {
            if var scanner = flintScanner {
                var end: String.Index?
                for index in buffer.unicodeScalars.indices {
                    if scanner.consume(buffer.unicodeScalars[index]) {
                        end = buffer.unicodeScalars.index(after: index)
                        break
                    }
                }
                if let end {
                    append(String(buffer[..<end]), reasoning: false, to: &result)
                    buffer.removeSubrange(buffer.startIndex..<end)
                    flintScanner = nil
                    state = .content
                    continue
                }
                append(buffer, reasoning: false, to: &result)
                buffer = ""
                flintScanner = final ? nil : scanner
                break
            }
            if var scanner = toolScanner {
                var end: String.Index?
                for index in buffer.unicodeScalars.indices {
                    if scanner.consume(buffer.unicodeScalars[index]) {
                        end = buffer.unicodeScalars.index(after: index)
                        break
                    }
                }
                if let end {
                    append(String(buffer[..<end]), reasoning: false, to: &result)
                    buffer.removeSubrange(buffer.startIndex..<end)
                    toolScanner = nil
                    state = .content
                    continue
                }
                append(buffer, reasoning: false, to: &result)
                buffer = ""
                toolScanner = final ? nil : scanner
                break
            }
            let markers: [String]
            let reasoning: Bool
            switch state {
            case .content:
                var contentMarkers = ["<think>"]
                if absorbStrayThinkClose { contentMarkers.append("</think>") }
                if protectToolFrames { contentMarkers += ["<tool_call>", "<function="] }
                markers = contentMarkers
                reasoning = false
            case .reasoning:
                markers = preserveInnerReasoningSpans ? ["<think>", "</think>"] : ["</think>"]
                reasoning = true
            case .tool(let end):
                markers = [end]
                reasoning = false
            }
            let found = markers.compactMap { marker -> (String, Range<String.Index>)? in
                buffer.range(of: marker).map { (marker, $0) }
            }.min { $0.1.lowerBound < $1.1.lowerBound }
            if let (marker, range) = found {
                switch state {
                case .content:
                    append(String(buffer[..<range.lowerBound]), reasoning: false, to: &result)
                    if marker == "<think>" { state = .reasoning; openThought = "" }
                    else if marker == "</think>" {
                        // Stray close after a prompt-side `<think></think>` (or a
                        // duplicate close): drop the marker, stay in content.
                    } else {
                        append(marker, reasoning: false, to: &result)
                        state = .tool(end: marker == "<tool_call>" ? "</tool_call>" : "</function>")
                        if qwenStructuredFrames && marker == "<tool_call>" {
                            toolScanner = Qwen35ToolFrameScanner()
                        } else if flintFrames && marker == "<tool_call>" {
                            flintScanner = FlintToolFrameScanner(tools: tools)
                        }
                    }
                case .reasoning:
                    if preserveInnerReasoningSpans && marker == "<think>" {
                        // An explicit inner span never promotes its example tool
                        // text to invocations. Preserve both literal delimiters.
                        guard innerReasoningDepth < Self.maximumInnerReasoningDepth else {
                            reasoningNestingLimitExceeded = true
                            buffer = ""
                            return result
                        }
                        innerReasoningDepth += 1
                        append(String(buffer[..<range.upperBound]), reasoning: true, to: &result)
                    } else if preserveInnerReasoningSpans && innerReasoningDepth > 0 {
                        innerReasoningDepth -= 1
                        append(String(buffer[..<range.upperBound]), reasoning: true, to: &result)
                    } else {
                        append(String(buffer[..<range.lowerBound]), reasoning: true, to: &result)
                        state = .content
                        openThought = ""
                    }
                case .tool:
                    append(String(buffer[..<range.upperBound]), reasoning: false, to: &result)
                    state = .content
                }
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            } else {
                var keep = 0
                if !final {
                    let maximum = min(buffer.count, (markers.map(\.count).max() ?? 1) - 1)
                    if maximum > 0 {
                        for count in (1...maximum).reversed() {
                            let suffix = String(buffer.suffix(count))
                            if markers.contains(where: { $0.hasPrefix(suffix) }) { keep = count; break }
                        }
                    }
                }
                let split = buffer.index(buffer.endIndex, offsetBy: -keep)
                append(String(buffer[..<split]), reasoning: reasoning, to: &result)
                buffer = String(buffer[split...])
                break
            }
        }
        return result
    }

    private mutating func append(_ text: String, reasoning: Bool, to result: inout [ParsedReasoning]) {
        guard !text.isEmpty else { return }
        if reasoning && promotesTrailingCalls { openThought += text }
        result.append(.init(content: reasoning ? "" : text, reasoningContent: reasoning ? text : nil))
    }
}
