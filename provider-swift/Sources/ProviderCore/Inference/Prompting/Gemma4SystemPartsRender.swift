// Copyright © 2026 Eigen Labs.
//
// Gemma 4's chat template renders a string system message as is
// (`messages[0]['content'] | trim`) but a list of text parts with a space
// after each part (`item['text'] | trim + ' '`), and trims each part of a
// list-shaped user message on its own. vLLM detects this template's content
// format as "openai" and hands it every string as one text part, so most
// OpenRouter endpoints feed, and count, one more token (`▁`) before the system
// turn's `<turn|>` than the string render does: OpenRouter's GPQA request
// ("You are a helpful assistant.") is 88 tokens there and 87 on 0.10.12.
// Transformers renders a client's list content the same per-part way, where
// `OpenAIMessageContent.text` joins the parts first.
//
// For a Gemma 4 text request this renders a system message, and the text parts
// of a list-shaped user message, as the template's text parts: vLLM's prompt
// for string content, and Transformers' and vLLM's for list content.
//
// A request the coordinator planned for its prompt cache keeps the prompt of
// its plan (`ChatTemplateControls.rendersCachePlan`): the prompt sidecar plans
// the string render, and a prompt longer than the plan fails the lookup receipt
// (`prompt_anchor_mismatch`) and fences the Mac's cache routing for the model.
// A media request renders as before. `DARKBLOOM_GEMMA_SYSTEM_PARTS_RENDER=off`
// restores 0.10.12's render everywhere.

import Foundation
import MLXLMServer

enum Gemma4SystemPartsRender {
    /// On unless `off`, `0`, `false` or `no`. Read once at launch.
    static let environmentKey = "DARKBLOOM_GEMMA_SYSTEM_PARTS_RENDER"
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])

    private static let modelTypes: Set<String> = ["gemma4", "gemma4_text"]

    static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "0", "false", "no"].contains(value)
    }

    /// Whether `request` renders its system and user text as parts.
    static func applies(
        to request: OpenAIChatCompletionRequest,
        modelType: String?,
        controls: ChatTemplateControls,
        enabled: Bool = enabled
    ) -> Bool {
        false
    }

    /// The template content of `message` as text parts: a system message's
    /// string or list, a user message's list. Nil keeps its string content.
    static func textParts(of message: OpenAIChatMessage) -> [any Sendable]? {
        nil
    }

    private static func part(_ text: String) -> [String: any Sendable] {
        ["type": "text", "text": text]
    }
}
