import Foundation
import MLXLMServer

/// Bounded native think-channel lexer. Tool frames are opaque argument data:
/// reasoning markers within them are never interpreted as channel controls.
/// Conversely, tool frames inside reasoning remain reasoning, not invocations.
struct NativeChannelSplitter {
    private enum State { case content, reasoning, tool(end: String) }
    private var state: State
    private var buffer = ""
    private let protectToolFrames: Bool
    var bufferedCharacterCount: Int { buffer.count }

    init(prefix: String, protectToolFrames: Bool) {
        state = prefix == "<think>" ? .reasoning : .content
        self.protectToolFrames = protectToolFrames
    }

    mutating func parse(_ text: String) -> [ParsedReasoning] {
        buffer += text
        return drain(final: false)
    }

    mutating func finish() -> [ParsedReasoning] { drain(final: true) }

    private mutating func drain(final: Bool) -> [ParsedReasoning] {
        var result: [ParsedReasoning] = []
        while !buffer.isEmpty {
            let markers: [String]
            let reasoning: Bool
            switch state {
            case .content:
                markers = protectToolFrames ? ["<think>", "<tool_call>", "<function="] : ["<think>"]
                reasoning = false
            case .reasoning:
                markers = ["</think>"]
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
                    }
                case .reasoning:
                    append(String(buffer[..<range.lowerBound]), reasoning: true, to: &result)
                    state = .content
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
