import Foundation
import MLXLMCommon

/// The calls in a GLM tool suffix that does not parse as one batch.
///
/// The SDK's `GLM5ToolStream` withholds a response from its first
/// `<tool_call>` to EOS and parses that suffix as one call batch. On the legacy
/// text path the suffix also holds reasoning, so a `<tool_call>` the model only
/// mentioned or drafted in its thought, or one its answer mentions, fails the
/// batch. Reference GLM parsers (vLLM, SGLang) return such unmatched markers as
/// text. Here the calls are the frames from the earliest `<tool_call>` whose
/// rest parses as calls to the end of the response; everything before them is
/// text, and a suffix with no such rest is all text. A frame is never completed
/// or salvaged, and a call followed by anything but more calls commits nothing,
/// so a malformed final frame leaves the whole suffix as text.
enum GLM5ToolSuffix {
    /// `DARKBLOOM_GLM_TOOL_TEXT_FALLBACK=0` restores the whole-suffix failure:
    /// an `auto` response whose suffix does not parse fails with a 500.
    static let environmentKey = "DARKBLOOM_GLM_TOOL_TEXT_FALLBACK"
    static let returnsUnparsedOutputAsTextByDefault =
        ProcessInfo.processInfo.environment[environmentKey] != "0"

    /// `<tool_call>` positions tried as the calls' first frame. Each attempt
    /// parses the rest of the suffix (at most `GLM5ToolCallParser`'s 1 MiB), so
    /// this bounds the work; calls after this many or more tags stay text.
    static let maximumStarts = 64

    private static let opening = "<tool_call>"

    static func split(_ suffix: String, tools: [[String: any Sendable]]?) -> (text: String, calls: [ToolCall]) {
        let parser = GLM5ToolCallParser()
        var searchStart = suffix.startIndex
        for _ in 0 ..< maximumStarts {
            guard let start = suffix.range(of: opening, range: searchStart ..< suffix.endIndex) else { break }
            let calls = parser.parseEOS(String(suffix[start.lowerBound...]), tools: tools)
            if !calls.isEmpty { return (String(suffix[..<start.lowerBound]), calls) }
            searchStart = start.upperBound
        }
        return (suffix, [])
    }
}
