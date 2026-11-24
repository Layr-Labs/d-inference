// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// One empty answer delta when an Inkling 2 request starts withholding its
/// reasoning (`Inkling2PromptContract.withholdsReasoning`).
///
/// With reasoning off the model still thinks, and the provider streams
/// nothing until the answer: the only frame before it is the role-only
/// preamble, which the coordinator holds as boilerplate, so a long thought
/// ends at its first-content deadline. When withholding starts, the router
/// emits `event` once; the coordinator serving path rewrites its frame to a
/// plain chunk whose delta is `{"content": ""}` (`frame(rewriting:)`): no
/// `role`, no reasoning field, no finish reason, no usage, and nothing
/// derived from the withheld text. An empty `content` delta is a legal
/// OpenAI streaming chunk that clients append as nothing.
///
/// Only the coordinator serving path turns it on (`enabled`, set around the
/// stream's start); every other path, every other model and reasoning-on
/// Inkling streams are unchanged.
enum InklingWithheldReasoningHeartbeat {
    /// Set by the coordinator serving path while it starts a stream.
    @TaskLocal static var enabled = false

    /// The router's event. The SDK's stream encoder writes it as a chunk whose
    /// delta holds only the two reasoning fields, both empty, a frame no other
    /// event produces (empty reasoning is never emitted).
    static let event = MLXServerGenerationEvent.parsed(.init(content: "", reasoningContent: ""))

    /// `frame` with its delta replaced by `{"content": ""}` when it is the
    /// encoded `event`, keeping the chunk's id, model and creation time; nil
    /// for every other frame.
    static func frame(rewriting frame: String) -> String? {
        guard frame.contains(#""reasoning_content":"""#), frame.hasPrefix("data: ") else { return nil }
        let json = frame.dropFirst("data: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let chunk = try? JSONDecoder().decode(OpenAIChatCompletionChunk.self, from: Data(json.utf8)),
              chunk.object == "chat.completion.chunk", chunk.usage == nil, chunk.choices.count == 1,
              let choice = chunk.choices.first, choice.finishReason == nil, choice.logprobs == nil,
              choice.delta == .init(role: nil, content: nil, reasoningContent: "", toolCalls: nil)
        else { return nil }
        let heartbeat = OpenAIChatCompletionChunk(
            id: chunk.id, model: chunk.model,
            choices: [.init(index: choice.index,
                            delta: .init(role: nil, content: "", reasoningContent: nil, toolCalls: nil),
                            finishReason: nil)],
            usage: nil, created: chunk.created)
        return try? ServerSentEventEncoder.encode(heartbeat)
    }
}
