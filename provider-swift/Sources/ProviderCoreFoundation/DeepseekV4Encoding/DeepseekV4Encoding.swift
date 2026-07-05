// Copyright © 2026 Eigen Labs.
//
// DeepSeek-V4 prompt encoding. DeepSeek-V4 ships no Jinja `chat_template` —
// the model family's reference implementation (`encoding_dsv4.py`, mirrored
// at `docs/spikes/` fixtures / the DeepSeek-V4-Flash HF repo's `encoding/`
// folder) is a bespoke Python encoder instead. This is a native Swift port
// of `encode_messages`, split across:
//
//   - `DeepseekV4EncodingTokens.swift`         special tokens + fixed template text
//   - `DeepseekV4JSON.swift`                   canonical JSON serialization
//   - `DeepseekV4EncodingPreprocessing.swift`  tool-message merge/sort/drop-thinking
//   - `DeepseekV4EncodingRenderer.swift`       per-message rendering (the core port)
//
// Lives in `ProviderCoreFoundation` (not `ProviderCore/Inference`, despite
// being purely about inference prompts) for the same reason
// `TemplateRenderCheck` does: it is pure Foundation string/dict logic with
// no MLX/Jinja/Darwin dependency, and `ProviderCoreFoundation` cannot depend
// on `ProviderCore` (the dependency arrow points the other way — see
// `Package.swift`). Putting it here lets `TemplateRenderCheck`'s scan-time
// self-check call the EXACT SAME encoder `ProviderCore`'s
// `MultiModelBatchSchedulerEngine`/`BatchScheduler` use at request time
// (via `DeepseekV4TemplateFix.swift` in `ProviderCore/Inference`, which
// hooks this in place of `Tokenizer.applyChatTemplate`), so
// `template_render_ok` keeps meaning "this provider can actually encode a
// tool-bearing request for this model" instead of vacuously passing a
// template-less snapshot.
//
// Supported roles match what the OpenAI wire can express: `system`, `user`,
// `assistant` (including `tool_calls`), and `tool` (merged into `user` per
// `merge_tool_messages`). `developer` and `latest_reminder` are supported at
// the encoder level (exercised directly by `DeepseekV4EncodingTests`) since
// the OpenAI wire has no representation for them.

import Foundation

public enum DeepseekV4EncodingError: Error, LocalizedError, Equatable {
    case invalidThinkingMode(String)
    case invalidReasoningEffort(String)
    case invalidMessage(String)
    case invalidTask(String)
    case unsupportedRole(String, index: Int)
    case unmergedToolMessage(index: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidThinkingMode(let mode):
            return "DeepseekV4Encoding: invalid thinking_mode '\(mode)' (expected 'chat' or 'thinking')"
        case .invalidReasoningEffort(let effort):
            return "DeepseekV4Encoding: invalid reasoning_effort '\(effort)' (expected 'max', 'high', or omitted)"
        case .invalidMessage(let detail):
            return "DeepseekV4Encoding: \(detail)"
        case .invalidTask(let task):
            return "DeepseekV4Encoding: invalid task '\(task)'"
        case .unsupportedRole(let role, let index):
            return "DeepseekV4Encoding: unsupported role '\(role)' at message index \(index)"
        case .unmergedToolMessage(let index):
            return
                "DeepseekV4Encoding: message at index \(index) has role 'tool' after preprocessing "
                + "(mergeToolMessages should have folded it into a user turn — this is an encoder bug)"
        }
    }
}

public enum DeepseekV4Encoding {
    /// Encode a conversation into the DeepSeek-V4 prompt string.
    ///
    /// - Parameters:
    ///   - messages: OpenAI-wire-shaped message dicts (the same shape
    ///     `OpenAIChatMessage.templateMessageDict()` produces: `role`,
    ///     `content`, optional `tool_calls`/`tool_call_id`/
    ///     `reasoning_content`), or, for encoder-level testing, hand-built
    ///     dicts using the encoder's full field set (`content_blocks`,
    ///     `task`, `wo_eos`, `tools`, `developer`/`latest_reminder` roles).
    ///   - tools: OpenAI-wire tool specs (`{"type": "function", "function":
    ///     {...}}`), attached to the first `system` message (or a
    ///     synthesized empty one, if none exists) before rendering — mirrors
    ///     how the test harness for `encoding_dsv4.py` does
    ///     `messages[0]["tools"] = tools`.
    ///   - thinkingMode: `"chat"` (immediately closes `<think>`) or
    ///     `"thinking"` (interleaved reasoning). Default `"thinking"`.
    ///   - dropThinking: strip `reasoning_content` from assistant turns
    ///     before the last user message. Automatically disabled whenever any
    ///     message declares `tools` (tool-calling conversations need full
    ///     reasoning history) — matches the reference's
    ///     `effective_drop_thinking` computation exactly.
    ///   - addDefaultBosToken: prepend `<｜begin▁of▁sentence｜>`. Default
    ///     `true`; the reference's `context` (incremental prefix re-use)
    ///     parameter is not supported — every call encodes the full
    ///     conversation from scratch, consistent with how every other model
    ///     family is tokenized in this provider (KV-cache prefix reuse
    ///     happens beneath the tokenizer, not by carrying forward an encoded
    ///     string prefix).
    ///   - reasoningEffort: `"max"` prepends the fixed reasoning-effort
    ///     prefix (only takes effect in `"thinking"` mode). `"high"` is
    ///     accepted (matches the reference's assertion) but has no
    ///     additional text effect, matching the reference. Any other
    ///     non-nil value throws.
    /// - Returns: The encoded prompt string. Tokenization is the caller's
    ///   job: `tokenizer.inner.encode(text: prompt, addSpecialTokens: false)`
    ///   — this string already carries its own BOS/EOS/special tokens, so
    ///   `addSpecialTokens: true` would double them.
    public static func encode(
        messages: [DSV4Msg],
        tools: [DSV4Msg]? = nil,
        thinkingMode: String = "thinking",
        dropThinking: Bool = true,
        addDefaultBosToken: Bool = true,
        reasoningEffort: String? = nil
    ) throws -> String {
        guard thinkingMode == "chat" || thinkingMode == "thinking" else {
            throw DeepseekV4EncodingError.invalidThinkingMode(thinkingMode)
        }
        guard reasoningEffort == nil || reasoningEffort == "max" || reasoningEffort == "high" else {
            throw DeepseekV4EncodingError.invalidReasoningEffort(reasoningEffort!)
        }

        var withTools = messages
        if let tools, !tools.isEmpty {
            if let systemIdx = withTools.firstIndex(where: { ($0["role"] as? String) == "system" }) {
                withTools[systemIdx]["tools"] = tools
            } else {
                withTools.insert(["role": "system", "content": "", "tools": tools], at: 0)
            }
        }

        var fullMessages = DeepseekV4EncodingPreprocessing.sortToolResultsByCallOrder(
            DeepseekV4EncodingPreprocessing.mergeToolMessages(withTools))

        var effectiveDropThinking = dropThinking
        if fullMessages.contains(where: { !(($0["tools"] as? [DSV4Msg])?.isEmpty ?? true) }) {
            effectiveDropThinking = false
        }

        if thinkingMode == "thinking" && effectiveDropThinking {
            fullMessages = DeepseekV4EncodingPreprocessing.dropThinkingMessages(fullMessages)
        }

        var prompt = addDefaultBosToken ? DeepseekV4Tokens.bos : ""
        for idx in fullMessages.indices {
            prompt += try DeepseekV4EncodingRenderer.renderMessage(
                index: idx,
                messages: fullMessages,
                thinkingMode: thinkingMode,
                dropThinking: effectiveDropThinking,
                reasoningEffort: reasoningEffort
            )
        }
        return prompt
    }
}
