// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Inkling 2 with thinking off, answering at once.
///
/// The template has no thinking switch: thinking off renders effort 0
/// (`Inkling2PromptContract.templateEffort`), at which the model may still
/// write a thought before its answer, and `NativeToolStreamRouter` withholds
/// it. The client then receives nothing visible until the thought ends. With
/// the switch on, the rendered prompt of a thinking-off request with no tools
/// in it (none declared, or `tool_choice` `none`) ends with an open answer
/// message (`<|message_model|><|content_text|>`), so the model writes its
/// answer from the first token, and the output lexer starts inside that
/// message (`Inkling2OutputChannels`, `startsInAnswer`).
///
/// The two tokens are where the next turn's history renders this reply
/// (`<|message_model|><|content_text|>ANSWER<|end_message|>…`), so the prompt
/// stays a prefix of the next turn's and prefix reuse is unchanged. Requests
/// with thinking on, with tools in the prompt (`auto` or forced), with media
/// or with logprobs, other models and the switch off are unchanged.
enum Inkling2AnswerPrefill {
    /// `DARKBLOOM_INKLING_THINKING_OFF_ANSWER_PREFILL`.
    static let environmentKey = "DARKBLOOM_INKLING_THINKING_OFF_ANSWER_PREFILL"
    /// The default when the switch is unset. Changes only on measured answer
    /// quality.
    static let prefillsByDefault = false
    /// The open answer message, as the model writes it after its own thought.
    static let markers = ["<|message_model|>", "<|content_text|>"]

    /// The switch as this process read it, once, at first use. Task-local so a
    /// test can set it around one request.
    @TaskLocal static var switchedOn: Bool = enabled()

    /// On for `1`, `true`, `yes` or `on`; off for `0`, `false`, `no` or `off`
    /// (trimmed, any letter case); unset or anything else keeps the default.
    static func enabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        switch environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": true
        case "0", "false", "no", "off": false
        default: prefillsByDefault
        }
    }

    /// Whether a request's prompt ends with the open answer message: Inkling 2,
    /// thinking off by the template context's precedence
    /// (`Inkling2PromptContract.withholdsReasoning`), no tools in the prompt
    /// and no forced call, no media, no logprobs, and the switch on.
    static func applies(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?,
        prepared: ToolChoicePromptPolicy.Prepared, logprobs: Bool,
        switchedOn: Bool = Inkling2AnswerPrefill.switchedOn
    ) -> Bool {
        switchedOn && !logprobs && prepared.tools?.isEmpty != false && !prepared.requiresToolCall
            && !MediaIngest.hasMedia(request)
            && Inkling2PromptContract.withholdsReasoning(request, controls: controls, modelType: modelType)
    }

    /// The open answer message's token ids in the slot's vocabulary, or nil
    /// when either marker is not one token there.
    static func tokens(tokenToId: (String) -> Int?) -> [Int]? {
        let ids = markers.compactMap(tokenToId)
        return ids.count == markers.count && ids.allSatisfy({ $0 >= 0 }) ? ids : nil
    }

    /// Where client stop strings apply in a reply that starts inside the
    /// answer: everywhere but a thought and the control tokens' spellings.
    /// The model's default scope opens at `<|content_text|>`, which this reply
    /// never writes.
    static let stopStringScope = Inkling2PromptContract.undeclaredCallTextStopScope
}
