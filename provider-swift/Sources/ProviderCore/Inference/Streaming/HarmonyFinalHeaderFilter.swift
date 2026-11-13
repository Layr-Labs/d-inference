// Copyright © 2026 Eigen Labs.

import MLXLMServer

/// Rewrites a GPT-OSS answer header that carries attributes, such as
/// `<|channel|>final <|constrain|>json<|message|>`, to the plain
/// `<|channel|>final<|message|>`. The Harmony reasoning parser routes only the
/// exact header `final` to content and drops every other message, so such an
/// answer reached the client as empty content. Other headers, and all text
/// outside headers, pass through byte for byte.
struct HarmonyFinalHeaderFilter: Sendable {
    static let channelMarker = "<|channel|>"
    static let messageMarker = "<|message|>"
    /// A header is a few tokens; longer text after `<|channel|>` passes unchanged.
    static let maximumHeaderBytes = 256

    private var pending = ""
    private var inHeader = false

    /// A GPT-OSS stream the Harmony reasoning parser splits (every coordinator
    /// request, and local requests that name no other parser).
    static func applies(to request: OpenAIChatCompletionRequest, modelId: String, modelType: String?) -> Bool {
        request.reasoningParser == .harmony
            && GPTOSSHarmonyTemplateFix.applies(to: ChatTemplateFixContext(modelId: modelId, modelType: modelType))
    }

    mutating func ingest(_ text: String) -> String {
        pending += text
        var output = ""
        while true {
            if inHeader {
                guard let end = pending.range(of: Self.messageMarker) else {
                    if pending.utf8.count > Self.maximumHeaderBytes {
                        output += pending
                        pending = ""
                        inHeader = false
                    }
                    return output
                }
                output += Self.answerHeader(String(pending[..<end.lowerBound])) + Self.messageMarker
                pending = String(pending[end.upperBound...])
                inHeader = false
            } else if let start = pending.range(of: Self.channelMarker) {
                output += pending[..<start.upperBound]
                pending = String(pending[start.upperBound...])
                inHeader = true
            } else {
                let held = Self.markerPrefixLength(pending)
                output += pending.dropLast(held)
                pending = String(pending.suffix(held))
                return output
            }
        }
    }

    /// The text still held: an unfinished header or a partial `<|channel|>`.
    mutating func finish() -> String {
        defer { pending = ""; inHeader = false }
        return pending
    }

    /// `final` for an answer header with attributes; any other header as given.
    /// A header with a recipient (`to=`) is a call, not an answer.
    static func answerHeader(_ header: String) -> String {
        let name = header.prefix { !$0.isWhitespace && $0 != "<" }
        guard name == "final", header != "final", !header.contains("to=") else { return header }
        return "final"
    }

    /// Length of the longest suffix of `text` that is a proper prefix of `<|channel|>`.
    private static func markerPrefixLength(_ text: String) -> Int {
        let marker = Array(channelMarker.utf8)
        let bytes = Array(text.utf8.suffix(marker.count - 1))
        for length in stride(from: bytes.count, through: 1, by: -1)
        where marker.starts(with: bytes.suffix(length)) {
            return String(decoding: bytes.suffix(length), as: UTF8.self).count
        }
        return 0
    }
}
