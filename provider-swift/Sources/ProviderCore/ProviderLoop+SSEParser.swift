// SSE-frame parsing helpers for `ProviderLoop`. Split out of
// `ProviderLoop.swift` so the wire-shape contract (W3C EventStream
// rules + the OpenAI chat-completion delta shape) lives in one place
// and can be navigated independently of the actor's run loop.
//
// All members here are `static` and free of actor state — they can
// be called from any context (the inflight Task body uses them via
// `ProviderLoop.parseStreamChunk` / `ProviderLoop.encodeToolCallsForHash`).

import Foundation
import MLXLMServer

extension ProviderLoop {

    /// Subset of streaming chunk fields we extract for telemetry +
    /// response-hash purposes.
    ///
    /// TB-007: We must capture `reasoning_content` in addition to
    /// `content` because the engine emits them as alternate deltas (and
    /// occasionally on the same chunk) when a `reasoning_parser` is
    /// active. The response hash commits to the concatenation of both
    /// streams so the consumer reassembly matches the engine's bytes
    /// exactly.
    ///
    /// P2 #2: `toolCallsDelta` is also surfaced so the inference
    /// handler can fold tool-call payloads into the response hash. A
    /// tool-calling response often carries (near-)empty `content` and
    /// the real assistant output is on `tool_calls`; without folding
    /// them in, the attestation hash commits to a body that doesn't
    /// represent what was actually returned to the consumer. See
    /// `encodeToolCallsForHash(_:)` for the canonical encoding.
    internal struct StreamChunkExtract: Equatable {
        let contentDelta: String?
        let reasoningDelta: String?
        let toolCallsDelta: [OpenAIToolCall]?
        let usage: OpenAIUsage?
        let finishReason: String?
        let role: String?
    }

    /// Collect every `data:` payload in `frame` and join them with
    /// `\n` per the W3C EventStream spec
    /// (https://html.spec.whatwg.org/multipage/server-sent-events.html#dispatchMessage).
    /// Returns nil if no `data:` line is present.
    ///
    /// P2 #1: previously the parser kept only the LAST `data:` line on
    /// each iteration, silently dropping payloads that the spec
    /// requires us to concatenate. SSE servers (including upstream's
    /// `MLXOpenAIService.streamChatCompletionFrames` once it starts
    /// pretty-printing) can legally split a single JSON chunk across
    /// multiple `data:` lines; the consumer is responsible for
    /// re-assembling them with `\n` separators before JSON-decoding.
    ///
    /// Empty `data:` lines are preserved as empty strings so the
    /// canonical "blank line within an event is a newline" rule
    /// holds: `data: foo / data: / data: bar` joins to `"foo\n\nbar"`.
    ///
    /// Comment lines (`:...`) and `event:` lines are ignored.
    internal static func joinedDataPayload(_ frame: String) -> String? {
        var dataLines: [String] = []
        for rawLine in frame.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if rawLine.first == ":" {
                // SSE comment line (e.g. ":keepalive"). Ignore.
                continue
            }
            if rawLine.hasPrefix("event:") {
                // Named-event line. Ignore the event type — upstream's
                // chat-completion stream is a single-event flow today.
                continue
            }
            if rawLine.hasPrefix("data:") {
                var line = rawLine.dropFirst("data:".count)
                // Per SSE spec: a single leading space after the
                // colon is stripped if present.
                if line.first == " " { line = line.dropFirst() }
                dataLines.append(String(line))
            }
            // Other field names (id:, retry:) are ignored.
        }
        guard !dataLines.isEmpty else { return nil }
        return dataLines.joined(separator: "\n")
    }

    /// Parse an SSE frame string emitted by
    /// `MLXOpenAIService.streamChatCompletionFrames` and pull out the
    /// assistant content + reasoning + tool calls + (optional) usage
    /// block. Returns nil for SSE comments, the terminal `data:
    /// [DONE]` sentinel, and for any frame that fails to parse.
    ///
    /// I3: SSE frame parsing follows the W3C EventStream contract.
    /// Lines starting with `:` are comments and must be ignored. Lines
    /// of the form `event:` carry the event type (we ignore the value
    /// today). The payload is on the `data:` line(s) — multiple `data:`
    /// lines within the same event are joined with `\n` (P2 #1).
    /// Upstream currently never emits comments, `event:` lines, or
    /// multi-line `data:` payloads, but a future keepalive / named-
    /// event / pretty-print addition must not silently corrupt our
    /// `fullResponseText` accumulation.
    internal static func parseStreamChunk(_ frame: String) -> StreamChunkExtract? {
        guard let joined = joinedDataPayload(frame) else {
            // Frame contained no `data:` line. This is unexpected from
            // upstream; warn so a future upstream change that emits
            // standalone comments or event lines without payload is
            // visible in logs.
            standaloneStreamChunkLogger.warning(
                "parseStreamChunk: SSE frame contained no data: line; "
                + "ignoring. frame=\(frame.prefix(80))"
            )
            return nil
        }
        let payload = joined.trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" || payload.isEmpty { return nil }
        guard let bytes = payload.data(using: .utf8) else { return nil }
        guard let chunk = try? JSONDecoder().decode(
            OpenAIChatCompletionChunk.self,
            from: bytes
        ) else {
            return nil
        }
        // Concatenate deltas across ALL choices so multi-choice (n > 1)
        // responses contribute fully to the attestation hash. For n=1
        // (the common case), this collapses to the same behavior as
        // reading choices.first. Choice ordering matches upstream's
        // encoder so the hash is stable.
        var contentParts: [String] = []
        var reasoningParts: [String] = []
        var toolCalls: [OpenAIToolCall] = []
        for choice in chunk.choices {
            if let c = choice.delta.content { contentParts.append(c) }
            if let r = choice.delta.reasoningContent { reasoningParts.append(r) }
            if let tcs = choice.delta.toolCalls { toolCalls.append(contentsOf: tcs) }
        }
        let firstChoice = chunk.choices.first
        return StreamChunkExtract(
            contentDelta: contentParts.isEmpty ? nil : contentParts.joined(),
            reasoningDelta: reasoningParts.isEmpty ? nil : reasoningParts.joined(),
            toolCallsDelta: toolCalls.isEmpty ? nil : toolCalls,
            usage: chunk.usage,
            // finishReason and role are choice-0 properties on this
            // wire shape — using the first choice matches upstream.
            finishReason: firstChoice?.finishReason,
            role: firstChoice?.delta.role
        )
    }

    /// True only after the stream has produced visible assistant output
    /// (content, reasoning content, or tool calls). Role/lifecycle/usage-only
    /// preamble frames are emitted to the coordinator but must not count as
    /// output for cancellation/error outcome counters.
    internal static func hasVisibleStreamOutput(
        contentFrameCount: Int,
        fullResponseText: String
    ) -> Bool {
        contentFrameCount > 0 || !fullResponseText.isEmpty
    }

    /// Inject `usage.completion_tokens_details.reasoning_tokens` into a
    /// final SSE chunk that already carries a `usage` block.
    ///
    /// Upstream's `OpenAIUsage` only models `prompt_tokens` /
    /// `completion_tokens`, so we can't add the detail by re-encoding a
    /// typed value. Instead we edit the JSON payload generically: decode
    /// the `data:` line to a dictionary, splice the OpenAI-standard
    /// `completion_tokens_details` object onto the existing `usage`, and
    /// re-serialize. This preserves every other field (id, model, choices,
    /// finish_reason, the existing token counts) untouched.
    ///
    /// The consumer-facing chat-completions usage object is the wire
    /// surface OpenAI clients read for reasoning-token accounting; the
    /// coordinator forwards this chunk verbatim, so editing it here is the
    /// single source of truth for the streaming path. On any parse/encode
    /// failure we return the original frame unchanged — a missing detail is
    /// strictly better than a corrupted usage chunk (which would break
    /// billing extraction downstream).
    internal static func injectReasoningTokens(
        into frame: String, reasoningTokens: Int
    ) -> String {
        guard reasoningTokens > 0,
              let payload = joinedDataPayload(frame),
              let bytes = payload.data(using: .utf8),
              var obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
              var usage = obj["usage"] as? [String: Any]
        else {
            return frame
        }
        // Merge into any existing details object rather than clobbering it.
        var details = usage["completion_tokens_details"] as? [String: Any] ?? [:]
        details["reasoning_tokens"] = reasoningTokens
        usage["completion_tokens_details"] = details
        obj["usage"] = usage
        guard let out = try? JSONSerialization.data(
                withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]
              ),
              let json = String(data: out, encoding: .utf8)
        else {
            return frame
        }
        return "data: \(json)\n\n"
    }

    /// TB-007 P2 #2: deterministic serialization of a `tool_calls`
    /// delta for inclusion in the response-hash accumulator.
    ///
    /// The attestation hash domain is `content + reasoning_content +
    /// tool_calls (canonicalized)`. Tool-call payloads must be folded
    /// in because the assistant's actual output for a tool-calling
    /// response often lives entirely on `tool_calls` with an empty
    /// `content`/`reasoning_content`, so a hash that ignored them
    /// would commit to the wrong bytes.
    ///
    /// Encoding: each call is wrapped in
    /// `\u{1F}tool_call:<JSON>\u{1F}` (Unit Separator) markers. The
    /// Unit Separator (U+001F) is a C0 control character that is
    /// invalid both in JSON strings (must be escaped) and in normal
    /// chat content, so it cannot collide with legitimate output.
    /// JSON encoding uses `[.sortedKeys, .withoutEscapingSlashes]`
    /// so two equivalent tool-call payloads always produce the same
    /// byte sequence regardless of Foundation's internal field order.
    ///
    /// Encoding failure (which shouldn't happen for the closed
    /// `OpenAIToolCall` shape) falls back to a fixed sentinel so the
    /// hash domain stays disjoint from "no tool calls at all".
    internal static func encodeToolCallsForHash(_ calls: [OpenAIToolCall]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = ""
        for call in calls {
            if let data = try? encoder.encode(call),
               let json = String(data: data, encoding: .utf8)
            {
                out += "\u{1F}tool_call:\(json)\u{1F}"
            } else {
                out += "\u{1F}tool_call:encoding_failed\u{1F}"
            }
        }
        return out
    }
}

/// Process-wide logger used by ``ProviderLoop/parseStreamChunk(_:)``,
/// which is a `static` method and so cannot access the per-instance
/// logger.
private let standaloneStreamChunkLogger = ProviderLogger(
    subsystem: "dev.darkbloom.provider",
    category: "ProviderLoop.parseStreamChunk"
)
