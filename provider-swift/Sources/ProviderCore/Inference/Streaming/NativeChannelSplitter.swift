import Foundation
import MLXLMCommon
import MLXLMServer

/// Bounded native think-channel lexer. Tool frames are opaque argument data:
/// reasoning markers within them are never interpreted as channel controls.
/// Conversely, tool frames inside reasoning remain reasoning, not invocations.
struct NativeChannelSplitter {
    private enum State { case content, reasoning, tool(end: String) }
    private var state: State
    private var buffer = ""
    private let protectToolFrames: Bool
    private let qwenStructuredFrames: Bool
    private var toolScanner: Qwen35ToolFrameScanner?
    private let preserveInnerReasoningSpans: Bool
    private var innerReasoningDepth = 0
    private(set) var reasoningNestingLimitExceeded = false
    static let maximumInnerReasoningDepth = 32
    var bufferedCharacterCount: Int { buffer.count + (toolScanner?.bufferedCharacterCount ?? 0) }

    init(prefix: String, protectToolFrames: Bool, qwenStructuredFrames: Bool = false,
         preserveInnerReasoningSpans: Bool = false) {
        state = prefix == "<think>" ? .reasoning : .content
        self.protectToolFrames = protectToolFrames
        self.qwenStructuredFrames = qwenStructuredFrames
        self.preserveInnerReasoningSpans = preserveInnerReasoningSpans
    }

    mutating func parse(_ text: String) -> [ParsedReasoning] {
        guard !reasoningNestingLimitExceeded else { return [] }
        buffer += text
        return drain(final: false)
    }

    mutating func finish() -> [ParsedReasoning] {
        guard !reasoningNestingLimitExceeded else { return [] }
        let pieces = drain(final: true)
        toolScanner = nil
        return pieces
    }

    private mutating func drain(final: Bool) -> [ParsedReasoning] {
        var result: [ParsedReasoning] = []
        while !buffer.isEmpty {
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
                markers = protectToolFrames ? ["<think>", "<tool_call>", "<function="] : ["<think>"]
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
                    if marker == "<think>" { state = .reasoning }
                    else {
                        append(marker, reasoning: false, to: &result)
                        state = .tool(end: marker == "<tool_call>" ? "</tool_call>" : "</function>")
                        if qwenStructuredFrames && marker == "<tool_call>" {
                            toolScanner = Qwen35ToolFrameScanner()
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

    private func append(_ text: String, reasoning: Bool, to result: inout [ParsedReasoning]) {
        guard !text.isEmpty else { return }
        result.append(.init(content: reasoning ? "" : text, reasoningContent: reasoning ? text : nil))
    }
}
