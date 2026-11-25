// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLMCommon
import MLXLMServer
import ProviderCoreFoundation

/// Inkling 2 Mini's prompt and output contract, from its pinned
/// `chat_template.jinja` and `tokenizer_config.json`
/// (`Inkling2ModelIdentity.upstreamRevision`).
///
/// - Reasoning: the template's `reasoning_effort` takes the seven names a
///   client sends (`none` 0, `minimal` 0.1, `low` 0.2, `medium` 0.7, `high`
///   0.9, `xhigh` and `max` 0.99) or a number in [0, 0.99], and defaults to
///   0.9. It reads the names exactly, so a client's spelling reaches it as its
///   canonical name. The model has no thinking switch: `none`, and a request
///   that turns thinking off, render effort 0, which still lets the model
///   think a little (model card, "Reasoning and compute").
/// - Tools: one `<|message_system|>tool_declare<|content_xml|>` message holds
///   the declarations as compact sorted JSON; history calls render as
///   `<|message_model|>NAME<|content_invoke_tool_json|>{"name":...,"args":{...}}`
///   and require parsed argument objects, printed with Transformers' `tojson`:
///   the caller's member order and `null`s, as sent
///   (`TemplateJSONOrder.callerArgumentModelTypes`); a result renders as
///   `<|message_tool|>NAME<|content_text|>...`.
/// - Content: a list renders each part as its own block, so a message's text
///   parts reach the template as parts, in order (`textParts(of:)`).
/// - System turns: the template renders a system message wherever it stands,
///   but with thinking on the model hunted through its thought for where a
///   later system instruction sat until the loop guard ended the row with no
///   answer. Every system turn is folded into one leading system message, in
///   order (`foldsSystemMessages`).
/// - Output: `Inkling2OutputChannels`. The template has no tool-choice control,
///   so required/named calls are prompt-forced and validated per frame.
enum Inkling2PromptContract {
    /// An off word (`0`, `false`, `off` or `no`, in any case, surrounding
    /// space ignored) renders later system turns in place again, as the
    /// template does. Read once at launch.
    static let foldSystemEnvironmentKey = "DARKBLOOM_INKLING_FOLD_SYSTEM"
    static let foldsSystemMessages = isFoldEnabled(ProcessInfo.processInfo.environment[foldSystemEnvironmentKey])

    static func isFoldEnabled(_ value: String?) -> Bool {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty else { return true }
        return !["0", "false", "off", "no"].contains(value)
    }

    /// The text-only system turns folded into one leading system message, in
    /// order, joined with a blank line (`LeadingSystemMessageNormalizer`, as
    /// for Qwen 3.5 and GPT-OSS); a single later system turn moves to the
    /// front. A list's text parts, which render as separate blocks, are
    /// joined the same way. Other turns keep their order. Nothing changes
    /// when `enabled` is false, when the only system message already leads,
    /// or when a system turn holds anything but text.
    static func normalizeSystemMessages(
        _ messages: [[String: any Sendable]], enabled: Bool = foldsSystemMessages
    ) -> [[String: any Sendable]] {
        guard enabled else { return messages }
        return LeadingSystemMessageNormalizer.normalize(
            messages,
            isSystem: { ($0["role"] as? String) == "system" },
            textContent: { systemText($0["content"]) },
            replacingContent: { message, text in
                var message = message
                message["content"] = text
                return message
            })
    }

    /// The typed messages of the media path, folded the same way.
    static func normalizeSystemMessages(
        _ messages: [OpenAIChatMessage], enabled: Bool = foldsSystemMessages
    ) -> [OpenAIChatMessage] {
        guard enabled else { return messages }
        return LeadingSystemMessageNormalizer.normalize(
            messages,
            isSystem: { $0.role == .system },
            textContent: { message in
                switch message.content {
                case .text(let text): return text
                case .null: return ""
                case .parts(let parts):
                    var texts: [String] = []
                    for part in parts {
                        guard case .text(let text) = part else { return nil }
                        texts.append(text)
                    }
                    return texts.joined(separator: "\n\n")
                }
            },
            replacingContent: { message, text in
                var message = message
                message.content = .text(text)
                return message
            })
    }

    /// A system message's text: a string, or a list's text parts joined with
    /// a blank line; nil for any other content.
    static func systemText(_ content: (any Sendable)?) -> String? {
        guard let content else { return "" }
        if let text = content as? String { return text }
        guard let parts = content as? [any Sendable] else { return nil }
        var texts: [String] = []
        for part in parts {
            guard let object = part as? [String: any Sendable],
                (object["type"] as? String).map({ $0 == "text" || $0 == "input_text" }) ?? true,
                let text = object["text"] as? String
            else { return nil }
            texts.append(text)
        }
        return texts.joined(separator: "\n\n")
    }

    /// The served type. The text and vision sub-configs never serve alone.
    static func applies(modelType: String?) -> Bool {
        Inkling2ModelIdentity.isNativeType(modelType)
    }

    /// The template content of a message sent as a list: its text parts in
    /// order, each of which the template renders as its own
    /// `<|content_text|>` block, as the reference does. Nil for string
    /// content. Media parts reach the template only on the media path.
    static func textParts(of message: OpenAIChatMessage) -> [any Sendable]? {
        guard case .parts(let parts) = message.content else { return nil }
        return parts.compactMap { part -> (any Sendable)? in
            guard case .text(let text) = part else { return nil }
            return ["type": "text", "text": text] as [String: any Sendable]
        }
    }

    /// The `reasoning_effort` the template receives: the canonical name of an
    /// effort, `none` when thinking is switched off, nil to keep the
    /// template's default (0.9). A value that is no name passes as sent; the
    /// effort validation refuses it before the template renders.
    static func templateEffort(_ effort: String?, thinking: Bool?) -> String? {
        if thinking == false { return ReasoningEffort.none.rawValue }
        guard let effort else { return nil }
        return ReasoningEffort(clientValue: effort)?.rawValue ?? effort
    }

    /// The caller turned thinking off, by the precedence the template context
    /// uses (`templateAdditionalContext`): `reasoning.enabled`, then
    /// `enable_thinking`, then an effort of `none`, `off` or `0`. The prompt
    /// then asks for effort 0, and whatever the model still thinks is counted
    /// as reasoning but never returned (`NativeToolStreamRouter`).
    static func withholdsReasoning(
        _ request: OpenAIChatCompletionRequest, controls: ChatTemplateControls, modelType: String?
    ) -> Bool {
        guard applies(modelType: modelType) else { return false }
        if let enabled = request.reasoning?.enabled { return !enabled }
        if let enabled = controls.enableThinking { return !enabled }
        return (request.reasoning?.effort ?? controls.reasoningEffort).map(ReasoningEffort.switchesThinkingOff) ?? false
    }

    /// Another role's turn is never the model's to write: generation stops
    /// there, as at `<|content_model_end_sampling|>`, instead of running to
    /// the output limit. `Inkling2OutputChannels` ends the output at the same
    /// markers.
    static let extraStopTokens = ["<|message_user|>", "<|message_system|>", "<|message_tool|>", "<|endoftext|>"]

    /// The openers of a call message: where the loop guard stops watching, so
    /// a call's repeated arguments are never cut.
    static let toolCallMarkers = ["<|content_invoke_tool_json|>", "<|content_invoke_tool_text|>"]

    static func extraEOSTokenIds(tokenToId: (String) -> Int?) -> Set<Int> {
        Set(extraStopTokens.compactMap(tokenToId))
    }

    /// Client stop strings apply to the answer, the text clients receive as
    /// `content`: matching them in a thought or a call's arguments ended a
    /// request before any answer existed (as GPT-OSS's analysis channel did).
    static let answerStopScope = CBv2StopStringScope(
        opener: "<|content_text|>",
        closers: ["<|end_message|>", "<|content_model_end_sampling|>", "<|message_model|>"])

    /// An `auto` request that declares no tools: its prompt has no
    /// `tool_declare`, so no call can be valid and a call frame is answer text
    /// (`Inkling2OutputChannels`, `callsAreText`). `enabled` is the rollback
    /// switch (`Inkling2OutputChannels.undeclaredCallsAreTextByDefault`).
    static func callsAreText(_ prepared: ToolChoicePromptPolicy.Prepared, enabled: Bool) -> Bool {
        enabled && prepared.mode == .auto && prepared.tools?.isEmpty != false
    }

    /// The thought, where client stop strings never apply.
    static let thoughtSpan = CBv2StopStringScope.Span(
        opener: "<|content_thinking|>", closers: ["<|end_message|>", "<|content_model_end_sampling|>"])

    /// Where client stop strings apply when call frames are answer text: in
    /// every body the client receives as content, so everywhere but the
    /// thought (`answerStopScope` would skip a call frame's text).
    static let undeclaredCallTextStopScope = CBv2StopStringScope(excluding: [thoughtSpan] + controlTokenSpans)

    /// Inkling's other control tokens, each up to its closing `|>`, so a
    /// client stop such as "end" never matches inside `<|end_message|>`. The
    /// thought's opener keeps its own span; none of these openers is a prefix
    /// of it.
    static let controlTokenSpans: [CBv2StopStringScope.Span] = [
        "message_model", "content_text", "content_tool_error", "content_invoke_tool_text",
        "content_invoke_tool_json", "content_image", "content_xml", "end_message",
        "content_model_end_sampling", "message_user", "message_system", "message_tool",
        "endoftext", "begin_of_text",
    ].map { CBv2StopStringScope.Span(opener: "<|" + $0, closers: ["|>"]) }

    /// This request's stop scope, when it is not the model's (`answerStopScope`).
    static func stopStringScope(
        modelType: String?, prepared: ToolChoicePromptPolicy.Prepared,
        enabled: Bool = Inkling2OutputChannels.undeclaredCallsAreTextByDefault
    ) -> CBv2StopStringScope? {
        applies(modelType: modelType) && callsAreText(prepared, enabled: enabled) ? undeclaredCallTextStopScope : nil
    }
}
