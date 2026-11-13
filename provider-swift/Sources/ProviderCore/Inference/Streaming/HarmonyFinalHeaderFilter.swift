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
        text
    }

    /// The text still held: an unfinished header or a partial `<|channel|>`.
    mutating func finish() -> String {
        ""
    }
}
