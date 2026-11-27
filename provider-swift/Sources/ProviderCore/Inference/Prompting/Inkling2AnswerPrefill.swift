// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMServer

/// Inkling 2 with thinking off, answering at once.
///
/// The template has no thinking switch: thinking off renders effort 0
/// (`Inkling2PromptContract.templateEffort`), at which the model may still
/// write a thought before its answer, and `NativeToolStreamRouter` withholds
/// it. The client then receives nothing visible until the thought ends. When
/// a request answers at once, the rendered prompt of a thinking-off request
/// with no tools in it (none declared, or `tool_choice` `none`) ends with an
/// open answer message (`<|message_model|><|content_text|>`), so the model
/// writes its answer from the first token, and the output lexer starts inside
/// that message (`Inkling2OutputChannels`, `startsInAnswer`).
///
/// Whether it does: the coordinator asks per request (the `answer_prefill`
/// frame hint, `ChatTemplateControls.answerPrefillHint`), and this Mac's
/// switch can override it either way. Unset, the hint decides, so a request
/// without one (the local API, an older coordinator) is unchanged.
///
/// The two tokens are where the next turn's history renders this reply
/// (`<|message_model|><|content_text|>ANSWER<|end_message|>…`), so the prompt
/// stays a prefix of the next turn's and prefix reuse is unchanged. Requests
/// with thinking on, with tools in the prompt (`auto` or forced), with media
/// or with logprobs, and other models are unchanged.
enum Inkling2AnswerPrefill {
    /// `DARKBLOOM_INKLING_THINKING_OFF_ANSWER_PREFILL`.
    static let environmentKey = "DARKBLOOM_INKLING_THINKING_OFF_ANSWER_PREFILL"
    /// The open answer message, as the model writes it after its own thought.
    static let markers = ["<|message_model|>", "<|content_text|>"]

    /// This Mac's override of the coordinator's hint.
    enum Override: Sendable, Equatable {
        /// Every eligible request answers at once, the local API included.
        case on
        /// No request does, whatever the hint.
        case off
        /// The hint decides (the default).
        case followsHint
    }

    /// The override as this process read it, once, at first use. Task-local
    /// so a test can set it around one request.
    @TaskLocal static var localOverride: Override = override()

    /// `1`, `true`, `yes` or `on` turn every eligible request on; `0`,
    /// `false`, `no` or `off` turn them all off (trimmed, any letter case);
    /// unset or anything else follows the coordinator's hint.
    static func override(environment: [String: String] = ProcessInfo.processInfo.environment) -> Override {
        switch environment[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on": .on
        case "0", "false", "no", "off": .off
        default: .followsHint
        }
    }

    /// Whether a request's prompt ends with the open answer message: asked for
    /// (the hint, or this Mac's override), and eligible: Inkling 2, thinking
    /// off by the template context's precedence
    /// (`Inkling2PromptContract.withholdsReasoning`), no tools in the prompt
    /// and no forced call, no media and no logprobs. The hint is
    /// `controls.answerPrefillHint`.
    static func applies(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?,
        prepared: ToolChoicePromptPolicy.Prepared, logprobs: Bool,
        localOverride: Override = Inkling2AnswerPrefill.localOverride
    ) -> Bool {
        let asked = switch localOverride {
        case .on: true
        case .off: false
        case .followsHint: controls.answerPrefillHint
        }
        return asked && !logprobs && prepared.tools?.isEmpty != false && !prepared.requiresToolCall
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
