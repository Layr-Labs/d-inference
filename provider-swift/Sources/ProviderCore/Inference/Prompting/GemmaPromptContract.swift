// Copyright © 2026 Eigen Labs.
//
// Gemma 4 prompt contracts. The chat template renders a string system message
// as is (`messages[0]['content'] | trim`) but a list of text parts with a space
// after each part (`item['text'] | trim + ' '`), and trims each part of any
// other list-shaped message on its own.
//
// - Version 1 (0.10.12 and the coordinator's prompt sidecar today): content as
//   one string, list parts joined first (`OpenAIMessageContent.text`).
// - Version 2: every system message (string or list) and a user message's list
//   content as the template's text parts; assistant and tool content as in
//   version 1. vLLM reads this template as OpenAI content format and hands it
//   every string as one text part, so for system and user content, and for
//   strings of any role, this is vLLM's prompt: OpenRouter's GPQA prompt is 88
//   tokens, not 87. vLLM renders list-shaped assistant content part by part;
//   version 2 keeps it joined, because `Gemma4TurnStructure` merges only
//   string assistant turns. The template joins tool parts as they are, so tool
//   lists render the same either way.
//
// A provider advertises version 2 at registration and renders it only for a
// coordinator request that asks for it (`InferenceRequest.gemmaPromptContract`),
// for the model types `gemma4` and `gemma4_text` (not `gemma4_vision` or
// `diffusion_gemma`, which the coordinator's prompt sidecar also renders in
// version 1 either way) and only for text requests. The coordinator asks only
// a provider that registered version 2, only for text requests, and chooses
// again for every attempt, with that version's cache plan and exact count. So
// a cache plan or exact count never meets a prompt it was not made for. Every
// other request renders version 1, so the provider stays dormant until the
// coordinator switches a model on. `DARKBLOOM_GEMMA_PROMPT_CONTRACT_V2=off`
// stops advertising version 2 and renders version 1 everywhere.

import Foundation
import MLXLMServer

enum GemmaPromptContract {
    static let environmentKey = "DARKBLOOM_GEMMA_PROMPT_CONTRACT_V2"
    /// On unless `off`, `0`, `false` or `no`. Read once at launch.
    static let enabled = isEnabled(ProcessInfo.processInfo.environment[environmentKey])
    static let partsVersion = 2

    private static let modelTypes: Set<String> = ["gemma4", "gemma4_text"]

    static func isEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["off", "0", "false", "no"].contains(value)
    }

    /// The registration's `gemma_prompt_contract`: nil when only version 1 renders.
    static var advertisedVersion: Int? { advertisedVersion(enabled: enabled) }

    static func advertisedVersion(enabled: Bool) -> Int? {
        enabled ? partsVersion : nil
    }

    /// Whether `request` renders version 2: the coordinator asked for it, and
    /// it is a Gemma 4 text request.
    static func rendersParts(
        _ request: OpenAIChatCompletionRequest, modelType: String?, controls: ChatTemplateControls
    ) -> Bool {
        guard controls.gemmaPromptContract == partsVersion, let modelType,
              modelTypes.contains(modelType.lowercased()) else { return false }
        return !MediaIngest.hasMedia(request)
    }

    /// The version 2 template content of `message`: a system message's string
    /// or list, or a user message's list, as text parts. Nil keeps its version
    /// 1 string: user strings, and assistant and tool content.
    static func textParts(of message: OpenAIChatMessage) -> [any Sendable]? {
        switch (message.role, message.content) {
        case (.system, .text(let text)):
            return [part(text)]
        case (.system, .parts(let parts)), (.user, .parts(let parts)):
            let texts = parts.compactMap { item -> (any Sendable)? in
                if case .text(let text) = item { return part(text) }
                return nil
            }
            return texts.isEmpty ? nil : texts
        default:
            return nil
        }
    }

    private static func part(_ text: String) -> [String: any Sendable] {
        ["type": "text", "text": text]
    }
}
