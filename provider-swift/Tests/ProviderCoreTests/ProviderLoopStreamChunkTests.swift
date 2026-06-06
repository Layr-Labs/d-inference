// Unit tests for `ProviderLoop.parseStreamChunk(_:)`.
//
// These pin the SSE-frame parsing contract that the C1/C2/I3 fixes
// depend on:
//
//   * C1 — usage extraction. If upstream stops emitting the trailing
//     usage chunk, billing collapses to $0 per request. The "usage
//     extracted" test guards that exact regression.
//
//   * C2 — TB-007 response-hash domain includes `reasoning_content`.
//     The hash now commits to `content` + `reasoning_content`
//     concatenated in chunk order, so the parser must surface both
//     deltas independently.
//
//   * I3 — defensive SSE parsing. Comment lines (`:...`), event lines
//     (`event:`), and the `[DONE]` sentinel must not corrupt the
//     accumulated assistant text.
//
//   * P2 #1 — multi-line `data:` event handling. SSE servers can
//     legally split a single payload across multiple `data:` lines
//     that the consumer joins with `\n`. The pre-fix parser kept
//     only the LAST line on each iteration, silently dropping content.
//
//   * P2 #2 — tool_calls delta in attestation hash. Tool-calling
//     responses often have empty `content` with the real assistant
//     output on `delta.tool_calls`; the parser must surface that
//     delta so the inference handler can fold it into the hash.

import Foundation
import MLXLMServer
import Testing
@testable import ProviderCore

// MARK: - Helpers

/// Encode a single `OpenAIChatCompletionChunk` as the exact SSE frame
/// string upstream's `MLXOpenAIService.streamChatCompletionFrames`
/// emits. We re-use upstream's encoder so the test stays wire-faithful
/// even if the JSON formatting (sorted keys, etc.) changes there.
private func encodeChunk(
    role: String? = nil,
    content: String? = nil,
    reasoningContent: String? = nil,
    toolCalls: [OpenAIToolCall]? = nil,
    finishReason: String? = nil,
    usage: OpenAIUsage? = nil,
    model: String = "test-model"
) throws -> String {
    let chunk = OpenAIChatCompletionChunk(
        id: "chatcmpl-test",
        model: model,
        choices: [
            .init(
                index: 0,
                delta: .init(
                    role: role,
                    content: content,
                    reasoningContent: reasoningContent,
                    toolCalls: toolCalls
                ),
                finishReason: finishReason
            )
        ],
        usage: usage,
        created: 0
    )
    return try ServerSentEventEncoder.encode(chunk)
}

// MARK: - Happy-path frame shapes

@Test("parseStreamChunk extracts role-only opening frame")
func parseStreamChunkExtractsRoleOnlyOpeningFrame() throws {
    let frame = try encodeChunk(role: "assistant")
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    #expect(parsed.role == "assistant")
    #expect(parsed.contentDelta == nil)
    #expect(parsed.reasoningDelta == nil)
    #expect(parsed.usage == nil)
    #expect(parsed.finishReason == nil)
}

@Test("parseStreamChunk extracts content delta")
func parseStreamChunkExtractsContentDelta() throws {
    let frame = try encodeChunk(content: "hello")
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    #expect(parsed.contentDelta == "hello")
    #expect(parsed.reasoningDelta == nil)
}

@Test("parseStreamChunk extracts reasoning_content delta")
func parseStreamChunkExtractsReasoningDelta() throws {
    let frame = try encodeChunk(reasoningContent: "I should think about this.")
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    #expect(parsed.contentDelta == nil)
    #expect(parsed.reasoningDelta == "I should think about this.")
}

@Test("parseStreamChunk extracts both content and reasoning_content from the same chunk")
func parseStreamChunkExtractsBothDeltas() throws {
    let frame = try encodeChunk(
        content: "the answer is 42",
        reasoningContent: "let me think..."
    )
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    #expect(parsed.contentDelta == "the answer is 42")
    #expect(parsed.reasoningDelta == "let me think...")
}

@Test("parseStreamChunk extracts finish_reason on terminal choice frame")
func parseStreamChunkExtractsFinishReason() throws {
    let frame = try encodeChunk(finishReason: "stop")
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    #expect(parsed.finishReason == "stop")
}

/// C1 regression guard: if upstream stops emitting the usage chunk the
/// coordinator bills $0. This test pins extraction of the canonical
/// trailing usage frame so a future regression is caught here, not in
/// the billing dashboard.
@Test("parseStreamChunk extracts usage block (C1 billing-regression guard)")
func parseStreamChunkExtractsUsageBlock() throws {
    let frame = try encodeChunk(
        finishReason: "stop",
        usage: OpenAIUsage(promptTokens: 42, completionTokens: 7)
    )
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    let usage = try #require(parsed.usage)
    #expect(usage.promptTokens == 42)
    #expect(usage.completionTokens == 7)
    #expect(usage.totalTokens == 49)
}

// MARK: - Defensive parsing (I3)

@Test("parseStreamChunk returns nil on the [DONE] sentinel")
func parseStreamChunkReturnsNilOnDoneSentinel() {
    #expect(ProviderLoop.parseStreamChunk(ServerSentEventEncoder.done) == nil)
}

/// SSE comment lines start with `:` and carry no payload (used today
/// by some servers for keepalives). They must not produce a parsed
/// extract and must not corrupt accumulated content.
@Test("parseStreamChunk ignores SSE keepalive comment lines")
func parseStreamChunkIgnoresSSEComment() {
    let frame = ":keepalive\n\n"
    #expect(ProviderLoop.parseStreamChunk(frame) == nil)
}

/// An `event:` line in front of `data:` must not block payload
/// extraction. Upstream does not emit named events today, but the
/// parser must not silently swallow the payload if it ever does.
@Test("parseStreamChunk parses payload through an event: prefix line")
func parseStreamChunkParsesPayloadThroughEventLine() throws {
    let inner = try encodeChunk(content: "hi")
    // Strip the framing newlines so we can build a multi-field frame.
    let payload = inner
        .replacingOccurrences(of: "data: ", with: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let frame = "event: chat.completion.chunk\ndata: \(payload)\n\n"
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    #expect(parsed.contentDelta == "hi")
}

@Test("parseStreamChunk happy-path single-line frame")
func parseStreamChunkHappyPathSingleLine() throws {
    let frame = try encodeChunk(content: "ok")
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    #expect(parsed.contentDelta == "ok")
}

@Test("parseStreamChunk returns nil for garbage payload")
func parseStreamChunkReturnsNilForGarbagePayload() {
    let frame = "data: not-json-at-all\n\n"
    #expect(ProviderLoop.parseStreamChunk(frame) == nil)
}

@Test("parseStreamChunk returns nil for empty data line")
func parseStreamChunkReturnsNilForEmptyData() {
    let frame = "data: \n\n"
    #expect(ProviderLoop.parseStreamChunk(frame) == nil)
}

// MARK: - P2 #1: multi-line `data:` event handling

/// W3C EventStream spec: an event with multiple `data:` lines must
/// have its payloads concatenated with `\n` before the consumer
/// interprets the result. Pre-fix the parser stomped on each previous
/// line, decoding only the last — silently dropping payload bytes.
@Test("parseStreamChunk handles multi-line data event")
func parseStreamChunkHandlesMultiLineDataEvent() throws {
    // Pretty-print a single JSON chunk across multiple lines, then
    // emit one `data:` per line. The joined payload should be
    // re-assembled into the original JSON and decode cleanly.
    let json = """
        {
        "id":"chatcmpl-test",
        "object":"chat.completion.chunk",
        "created":0,
        "model":"test-model",
        "choices":[{"index":0,"delta":{"content":"split-payload"},"finish_reason":null}]
        }
        """
    let frame = json.split(separator: "\n")
        .map { "data: \($0)" }
        .joined(separator: "\n") + "\n\n"
    let parsed = try #require(
        ProviderLoop.parseStreamChunk(frame),
        "multi-line data frame must decode after joining lines with \\n (P2 #1)"
    )
    #expect(parsed.contentDelta == "split-payload",
        "joined JSON must round-trip to the original content delta")
}

/// SSE spec: an empty `data:` line within an event MUST be preserved
/// as an empty string when the lines are joined. So
/// `data: foo / data: / data: bar` joins to `"foo\n\nbar"` (a blank
/// line in the middle, NOT `"foo\nbar"`).
@Test("parseStreamChunk preserves empty data lines as newlines")
func parseStreamChunkPreservesEmptyDataLines() {
    let frame = "data: foo\ndata: \ndata: bar\n\n"
    let joined = ProviderLoop.joinedDataPayload(frame)
    #expect(joined == "foo\n\nbar",
        "empty data: line must surface as an empty string in the joined payload (P2 #1)")
}

// MARK: - P2 #2: tool_calls delta surfacing for attestation hash

/// The parser must surface `delta.tool_calls` so the inference
/// handler can fold it into the response-hash accumulator. Without
/// this, tool-calling responses commit to (often empty) `content`
/// bytes that don't represent the actual assistant output.
@Test("parseStreamChunk extracts tool_calls delta")
func parseStreamChunkExtractsToolCallsDelta() throws {
    let toolCall = OpenAIToolCall(
        id: "call_1",
        type: "function",
        function: .init(name: "get_weather", arguments: #"{"city":"SF"}"#)
    )
    let frame = try encodeChunk(toolCalls: [toolCall])
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    let extracted = try #require(parsed.toolCallsDelta,
        "tool_calls delta must surface from delta.tool_calls (P2 #2)")
    #expect(extracted.count == 1)
    #expect(extracted[0].id == "call_1")
    #expect(extracted[0].function.name == "get_weather")
    #expect(extracted[0].function.arguments == #"{"city":"SF"}"#)
}

/// The hash-encoding helper must produce a deterministic, framed
/// string for each tool call. The inference handler appends the
/// returned string to `fullResponseText` (the attestation hash
/// accumulator); a non-deterministic encoding would break attestation
/// reproducibility across providers and across rebuilds of the same
/// release.
@Test("encodeToolCallsForHash produces stable framed JSON")
func encodeToolCallsForHashProducesStableEncoding() {
    let call = OpenAIToolCall(
        id: "call_abc",
        type: "function",
        function: .init(name: "get_weather", arguments: #"{"city":"SF"}"#)
    )
    let encoded = ProviderLoop.encodeToolCallsForHash([call])

    // Wrapped with \u{1F} markers (Unit Separator — invalid in
    // normal chat content, so cannot collide).
    #expect(encoded.hasPrefix("\u{1F}tool_call:"),
        "tool-call encoding must start with the framing marker (TB-007 P2 #2)")
    #expect(encoded.hasSuffix("\u{1F}"),
        "tool-call encoding must end with the framing marker (TB-007 P2 #2)")
    #expect(encoded.contains(#""id":"call_abc""#))
    #expect(encoded.contains(#""name":"get_weather""#))

    // Idempotent encoding — same input must always produce the same
    // bytes (sortedKeys output formatting).
    let encoded2 = ProviderLoop.encodeToolCallsForHash([call])
    #expect(encoded == encoded2,
        "encoding must be deterministic across invocations (sortedKeys)")
}

/// Empty tool-call list returns an empty string so the hash domain
/// is unchanged when the response has no tool calls.
@Test("encodeToolCallsForHash returns empty string for empty input")
func encodeToolCallsForHashEmptyInputReturnsEmptyString() {
    #expect(ProviderLoop.encodeToolCallsForHash([]) == "")
}

// MARK: - injectReasoningTokens

@Test("injectReasoningTokens adds completion_tokens_details to a usage frame")
func injectReasoningTokensAddsDetails() throws {
    let frame = try encodeChunk(
        finishReason: "stop",
        usage: OpenAIUsage(promptTokens: 10, completionTokens: 30)
    )
    let rewritten = ProviderLoop.injectReasoningTokens(into: frame, reasoningTokens: 12)

    // The rewritten frame must still parse and preserve the original counts.
    let parsed = try #require(ProviderLoop.parseStreamChunk(rewritten))
    let usage = try #require(parsed.usage)
    #expect(usage.promptTokens == 10)
    #expect(usage.completionTokens == 30)

    // And carry the OpenAI-standard reasoning detail on the wire.
    let payload = try #require(ProviderLoop.joinedDataPayload(rewritten))
    let obj = try #require(
        try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let usageObj = try #require(obj["usage"] as? [String: Any])
    let details = try #require(usageObj["completion_tokens_details"] as? [String: Any])
    #expect((details["reasoning_tokens"] as? Int) == 12)
}

@Test("injectReasoningTokens is a no-op for zero reasoning tokens")
func injectReasoningTokensZeroIsNoop() throws {
    let frame = try encodeChunk(
        finishReason: "stop",
        usage: OpenAIUsage(promptTokens: 5, completionTokens: 5)
    )
    #expect(ProviderLoop.injectReasoningTokens(into: frame, reasoningTokens: 0) == frame)
}

@Test("injectReasoningTokens leaves frames without a usage block untouched")
func injectReasoningTokensNoUsageIsNoop() throws {
    let frame = try encodeChunk(content: "hello")
    #expect(ProviderLoop.injectReasoningTokens(into: frame, reasoningTokens: 9) == frame)
}

@Test("injectReasoningTokens preserves a pre-existing details object")
func injectReasoningTokensMergesExistingDetails() throws {
    // Hand-craft a usage frame that already carries an unrelated detail
    // field; the reasoning_tokens splice must not drop it.
    let raw = #"data: {"id":"x","model":"m","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"completion_tokens_details":{"audio_tokens":3}}}"# + "\n\n"
    let rewritten = ProviderLoop.injectReasoningTokens(into: raw, reasoningTokens: 4)
    let payload = try #require(ProviderLoop.joinedDataPayload(rewritten))
    let obj = try #require(
        try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let details = try #require(
        (obj["usage"] as? [String: Any])?["completion_tokens_details"] as? [String: Any]
    )
    #expect((details["reasoning_tokens"] as? Int) == 4)
    #expect((details["audio_tokens"] as? Int) == 3)
}
