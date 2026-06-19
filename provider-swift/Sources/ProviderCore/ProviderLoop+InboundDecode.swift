// Inbound chat-request decoding. Accepts the upstream OpenAI shape
// (`OpenAIChatCompletionRequest`) and, on the cold path, normalises a
// handful of valid-but-strictly-rejected OpenAI shapes (hosted/custom
// tools, content-less messages, the `developer` role) before retrying.
//
// #252: the previous implementation fell back to the legacy
// `ChatCompletionRequest` decoder inside the `catch` and threw *its*
// error, masking the real reason the primary decode failed — the classic
// "Key 'function' not found … tools[0]" red herring that comes from the
// legacy `ToolDefinition` decoder, not the parser that actually runs
// first. The legacy lift also silently dropped `tools` whenever it
// succeeded. Both problems are gone here: we surface the primary
// decoder's error, and we preserve tools/content through the
// normalisation retry (see ``InboundChatNormalization``).

import Foundation
import MLXLMServer

extension ProviderLoop {

    /// Decode an inbound chat request into the upstream
    /// `OpenAIChatCompletionRequest`.
    ///
    /// Fast path: a strict decode, unchanged for well-formed requests
    /// (zero overhead, identical behaviour). Cold path: if the strict
    /// decode fails, normalise the known valid-but-rejected OpenAI shapes
    /// and retry. We never substitute a misleading fallback error — if
    /// normalisation can't repair the body, the strict-decoder error is
    /// surfaced as-is.
    internal static func decodeOpenAIRequest(
        _ data: Data
    ) throws -> OpenAIChatCompletionRequest {
        // Inject default `type`s into tool parameter schemas so a Gemma-style
        // chat template's `{{ value['type'] | upper }}` can't crash on a typeless
        // property (DAR-130). No-op for requests without tools.
        let data = ToolSchemaNormalization.ensureParameterTypes(in: data)
        let decoder = JSONDecoder()
        do {
            return try decoder.decode(OpenAIChatCompletionRequest.self, from: data)
        } catch let primaryError {
            let normalized: Data
            do {
                normalized = try InboundChatNormalization.normalize(data)
            } catch let roleError as MultiModelBatchSchedulerEngineError {
                // A clear, typed 400 (e.g. an unsupported role naming the
                // offending value) is more useful than the raw decoder
                // error — surface it directly.
                throw roleError
            } catch {
                // The body isn't a JSON object we can repair. Surface the
                // genuine strict-decoder error, never a masked fallback.
                throw primaryError
            }
            // Re-run the strict decoder on the repaired body. If it still
            // fails, that error is the real, unmasked problem: hosted
            // tools, content-less messages, and role aliases have already
            // been handled, so it cannot be the #252 `tools[0].function`
            // red herring.
            return try decoder.decode(OpenAIChatCompletionRequest.self, from: normalized)
        }
    }

    /// Pull the OpenAI `reasoning_effort` field out of a raw request body.
    ///
    /// This lives outside `OpenAIChatCompletionRequest` (the upstream type
    /// doesn't model it), so we decode it directly. Returns a trimmed,
    /// non-empty string or `nil`. The value is passed through verbatim —
    /// the valid set (`low`/`medium`/`high` for gpt-oss; other models
    /// differ) is enforced by each model's chat template, not here, so we
    /// stay format-agnostic rather than hardcoding a per-model allowlist.
    internal static func extractReasoningEffort(from data: Data) -> String? {
        struct Probe: Decodable { let reasoning_effort: String? }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data),
              let raw = probe.reasoning_effort
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Per-tenant prefix-cache scope for this request. Like `reasoning_effort`,
    /// `prompt_cache_key` isn't on the upstream `OpenAIChatCompletionRequest`,
    /// so decode it (and `user` as fallback) directly from the sealed body.
    /// Policy: `SHA256(prompt_cache_key)` if present, else `SHA256(user)`, else
    /// "" (unscoped — shared cache, current behavior). The hash keeps the scope
    /// opaque + fixed-width. Reuses `ChatCompletionRequest.cacheScope` so the
    /// policy lives in exactly one place.
    internal static func extractCacheScope(from data: Data) -> String {
        struct Probe: Decodable { let prompt_cache_key: String?; let user: String? }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return "" }
        if let k = probe.prompt_cache_key, !k.isEmpty {
            return ChatCompletionRequest.scopeHash(k)
        }
        if let u = probe.user, !u.isEmpty {
            return ChatCompletionRequest.scopeHash(u)
        }
        return ""
    }

    /// Prompt-token floor for requests whose usage chunk never arrived (cancelled
    /// stream / upstream regression). Re-runs the engine's exact applyChatTemplate
    /// path so the count matches what was prefilled; VLM parts aren't in the text
    /// template so vision under-counts (a floor, never an overcharge). 0 on failure.
    internal static func promptTokenFloor(
        request: OpenAIChatCompletionRequest,
        tokenizer: TokenizerHandle,
        reasoningEffort: String?
    ) -> Int {
        let messages = request.messages.map { $0.templateMessageDict() }
        let toolSpecs = request.tools?.map { $0.toolSpec() }
        let additionalContext: [String: any Sendable]? =
            reasoningEffort.map { ["reasoning_effort": $0] }
        // Must mirror the production tokenize path (sanitize JSON
        // null / Optional leaves) so this recount matches what was prefilled
        // and doesn't itself throw on a null-bearing request.
        guard let ids = try? tokenizer.inner.applyChatTemplate(
            messages: sanitizeJinjaMessages(messages),
            tools: sanitizeJinjaTools(toolSpecs),
            additionalContext: additionalContext
        ) else { return 0 }
        return ids.count
    }
}
