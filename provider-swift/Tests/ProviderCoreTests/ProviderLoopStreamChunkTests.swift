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

@Test("visible-output signal ignores role-only preamble frames")
func visibleOutputSignalIgnoresRoleOnlyPreamble() throws {
    let frame = try encodeChunk(role: "assistant")
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    var contentFrameCount = 0
    var fullResponseText = ""

    if let content = parsed.contentDelta, !content.isEmpty {
        fullResponseText += content
        contentFrameCount += 1
    }

    #expect(!ProviderLoop.hasVisibleStreamOutput(
        contentFrameCount: contentFrameCount,
        fullResponseText: fullResponseText
    ))
}

@Test("visible-output signal counts content frames")
func visibleOutputSignalCountsContentFrames() throws {
    let frame = try encodeChunk(content: "hello")
    let parsed = try #require(ProviderLoop.parseStreamChunk(frame))
    var contentFrameCount = 0
    var fullResponseText = ""

    if let content = parsed.contentDelta, !content.isEmpty {
        fullResponseText += content
        contentFrameCount += 1
    }

    #expect(ProviderLoop.hasVisibleStreamOutput(
        contentFrameCount: contentFrameCount,
        fullResponseText: fullResponseText
    ))
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

// MARK: - injectLogprobs (engine-v2 logprobs passthrough)

private func sampleLogprobEntries() -> [SSETokenLogprob] {
    [
        SSETokenLogprob(
            token: "Hello", logprob: -0.25, bytes: [72, 101, 108, 108, 111],
            topLogprobs: [
                .init(token: "Hello", logprob: -0.25, bytes: [72, 101, 108, 108, 111]),
                .init(token: "Hi", logprob: -1.5, bytes: [72, 105]),
            ]
        )
    ]
}

@Test("injectLogprobs splices the OpenAI logprobs.content shape into a content frame")
func injectLogprobsContentFrame() throws {
    let frame = try encodeChunk(content: "Hello")
    let rewritten = try #require(
        ProviderLoop.injectLogprobs(into: frame, entries: sampleLogprobEntries())
    )
    // Content preserved; the rewritten frame still parses.
    let parsed = try #require(ProviderLoop.parseStreamChunk(rewritten))
    #expect(parsed.contentDelta == "Hello")
    // OpenAI wire shape:
    // choices[0].logprobs.content[].{token, logprob, bytes, top_logprobs}.
    let payload = try #require(ProviderLoop.joinedDataPayload(rewritten))
    let obj = try #require(
        try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let choices = try #require(obj["choices"] as? [[String: Any]])
    let logprobs = try #require(choices[0]["logprobs"] as? [String: Any])
    let content = try #require(logprobs["content"] as? [[String: Any]])
    #expect(content.count == 1)
    #expect((content[0]["token"] as? String) == "Hello")
    let lp = try #require(content[0]["logprob"] as? Double)
    #expect(abs(lp - (-0.25)) < 1e-6)
    #expect((content[0]["bytes"] as? [Int]) == [72, 101, 108, 108, 111])
    let top = try #require(content[0]["top_logprobs"] as? [[String: Any]])
    #expect(top.count == 2)
    #expect((top[1]["token"] as? String) == "Hi")
    #expect((top[1]["bytes"] as? [Int]) == [72, 105])
}

// MARK: - Pending-logprobs bounding (round-3 PR#499 P2)

private func logprobEntry(_ index: Int) -> SSETokenLogprob {
    SSETokenLogprob(token: "t\(index)", logprob: -0.5, bytes: nil, topLogprobs: [])
}

@Test("capPending drops the OLDEST entries past the channel cap and reports the count")
func capPendingDropsOldestPastCap() {
    // A reasoning-only prefix accumulates far past the cap: the buffer must
    // stay bounded at exactly `maxEntries`, evicting the oldest entries.
    let cap = EngineV2LogprobsChannel.maxEntries
    var pending = (0..<(cap + 25)).map(logprobEntry)
    let dropped = EngineV2LogprobsChannel.capPending(&pending)
    #expect(dropped == 25)
    #expect(pending.count == cap)
    // Freshest window kept: the first 25 (oldest) entries are gone.
    #expect(pending.first?.token == "t25")
    #expect(pending.last?.token == "t\(cap + 24)")
    // At/under the cap the buffer is untouched and nothing is dropped.
    #expect(EngineV2LogprobsChannel.capPending(&pending) == 0)
    #expect(pending.count == cap)
    var small = [logprobEntry(0)]
    #expect(EngineV2LogprobsChannel.capPending(&small) == 0)
    #expect(small.count == 1)
}

@Test("a content frame after a long reasoning-only prefix carries only the retained window")
func cappedPendingWindowSplicesIntoContentFrame() throws {
    // Simulate the frames loop: 6 entries accumulate across reasoning-only
    // frames while the cap (3 here, for the test) evicts the oldest, then
    // the first content-bearing chunk arrives and carries the survivors.
    var pending = (0..<6).map(logprobEntry)
    var droppedTotal = 0
    droppedTotal += EngineV2LogprobsChannel.capPending(&pending, maxEntries: 3)
    #expect(droppedTotal == 3)

    // Reasoning-only frame: entries stay pending (and stay bounded).
    #expect(ProviderLoop.injectLogprobs(
        into: try encodeChunk(reasoningContent: "thinking"), entries: pending) == nil)

    // First content frame: the retained window — and ONLY it — attaches.
    let frame = try encodeChunk(content: "Hello")
    let rewritten = try #require(ProviderLoop.injectLogprobs(into: frame, entries: pending))
    let payload = try #require(ProviderLoop.joinedDataPayload(rewritten))
    let obj = try #require(
        try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let choices = try #require(obj["choices"] as? [[String: Any]])
    let logprobs = try #require(choices[0]["logprobs"] as? [String: Any])
    let content = try #require(logprobs["content"] as? [[String: Any]])
    #expect(content.map { $0["token"] as? String } == ["t3", "t4", "t5"])
}

@Test("injectLogprobs returns nil for non-content frames (entries stay pending)")
func injectLogprobsSkipsNonContentFrames() throws {
    let entries = sampleLogprobEntries()
    // Role-only preamble.
    #expect(ProviderLoop.injectLogprobs(
        into: try encodeChunk(role: "assistant"), entries: entries) == nil)
    // Reasoning-only delta (logprobs.content covers CONTENT tokens).
    #expect(ProviderLoop.injectLogprobs(
        into: try encodeChunk(reasoningContent: "thinking"), entries: entries) == nil)
    // Terminal/usage chunk.
    #expect(ProviderLoop.injectLogprobs(
        into: try encodeChunk(
            finishReason: "stop",
            usage: OpenAIUsage(promptTokens: 1, completionTokens: 2)),
        entries: entries) == nil)
    // Empty content string is not content-bearing.
    #expect(ProviderLoop.injectLogprobs(
        into: try encodeChunk(content: ""), entries: entries) == nil)
    // [DONE] sentinel and unparseable payloads are never touched.
    #expect(ProviderLoop.injectLogprobs(into: "data: [DONE]\n\n", entries: entries) == nil)
    #expect(ProviderLoop.injectLogprobs(into: "data: {not json}\n\n", entries: entries) == nil)
    // No entries → nothing to splice, even into a content frame.
    #expect(ProviderLoop.injectLogprobs(
        into: try encodeChunk(content: "x"), entries: []) == nil)
}

// MARK: - injectUsageDetails (single splice for both usage details)

/// Goldens captured from the two-pass composition
/// (`injectCachedTokens(into: injectReasoningTokens(into:))`) BEFORE the
/// single-splice change: `sortedKeys` output over a hand-built usage frame.
private let usageDetailsBaseFrame =
    #"data: {"id":"x","model":"m","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3}}"#
    + "\n\n"

@Test("injectUsageDetails matches the two-pass composition for every detail combination")
func injectUsageDetailsMatchesTwoPassGoldens() {
    let both = ProviderLoop.injectUsageDetails(
        into: usageDetailsBaseFrame, reasoningTokens: 2, cachedTokens: 4)
    #expect(both == #"data: {"choices":[],"id":"x","model":"m","usage":{"completion_tokens":3,"completion_tokens_details":{"reasoning_tokens":2},"prompt_tokens":5,"prompt_tokens_details":{"cached_tokens":4}}}"# + "\n\n")

    let reasoningOnly = ProviderLoop.injectUsageDetails(
        into: usageDetailsBaseFrame, reasoningTokens: 2, cachedTokens: 0)
    #expect(reasoningOnly == #"data: {"choices":[],"id":"x","model":"m","usage":{"completion_tokens":3,"completion_tokens_details":{"reasoning_tokens":2},"prompt_tokens":5}}"# + "\n\n")

    let cachedOnly = ProviderLoop.injectUsageDetails(
        into: usageDetailsBaseFrame, reasoningTokens: 0, cachedTokens: 4)
    #expect(cachedOnly == #"data: {"choices":[],"id":"x","model":"m","usage":{"completion_tokens":3,"prompt_tokens":5,"prompt_tokens_details":{"cached_tokens":4}}}"# + "\n\n")

    // Neither detail: the frame is returned untouched WITHOUT a JSON round
    // trip (byte-identical to the input, not merely equivalent).
    let neither = ProviderLoop.injectUsageDetails(
        into: usageDetailsBaseFrame, reasoningTokens: 0, cachedTokens: 0)
    #expect(neither == usageDetailsBaseFrame)

    // The single-detail entry points are now thin wrappers and must agree
    // with the composed form.
    let composed = ProviderLoop.injectCachedTokens(
        into: ProviderLoop.injectReasoningTokens(into: usageDetailsBaseFrame, reasoningTokens: 2),
        cachedTokens: 4)
    #expect(composed == both)
}

@Test("injectUsageDetails leaves frames without a usage block untouched")
func injectUsageDetailsNoUsageIsNoop() throws {
    let frame = try encodeChunk(content: "hello")
    #expect(ProviderLoop.injectUsageDetails(into: frame, reasoningTokens: 3, cachedTokens: 9) == frame)
}

@Test("injectUsageDetails merges into pre-existing details objects")
func injectUsageDetailsMergesExisting() throws {
    let raw = #"data: {"id":"x","model":"m","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":2,"completion_tokens_details":{"audio_tokens":3},"prompt_tokens_details":{"audio_tokens":7}}}"# + "\n\n"
    let rewritten = ProviderLoop.injectUsageDetails(into: raw, reasoningTokens: 4, cachedTokens: 5)
    let payload = try #require(ProviderLoop.joinedDataPayload(rewritten))
    let obj = try #require(
        try JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any]
    )
    let usage = try #require(obj["usage"] as? [String: Any])
    let completion = try #require(usage["completion_tokens_details"] as? [String: Any])
    let prompt = try #require(usage["prompt_tokens_details"] as? [String: Any])
    #expect((completion["reasoning_tokens"] as? Int) == 4)
    #expect((completion["audio_tokens"] as? Int) == 3)
    #expect((prompt["cached_tokens"] as? Int) == 5)
    #expect((prompt["audio_tokens"] as? Int) == 7)
}

// MARK: - parseStreamChunk with a caller-owned decoder

@Test("parseStreamChunk reuses one caller-owned decoder across frames")
func parseStreamChunkSharedDecoder() throws {
    let decoder = JSONDecoder()
    let frames = [
        try encodeChunk(role: "assistant"),
        try encodeChunk(content: "Hello"),
        try encodeChunk(reasoningContent: "why"),
        try encodeChunk(finishReason: "stop", usage: OpenAIUsage(promptTokens: 2, completionTokens: 2)),
    ]
    for frame in frames {
        let shared = ProviderLoop.parseStreamChunk(frame, decoder: decoder)
        let fresh = ProviderLoop.parseStreamChunk(frame)
        #expect(shared?.contentDelta == fresh?.contentDelta)
        #expect(shared?.reasoningDelta == fresh?.reasoningDelta)
        #expect(shared?.usage?.promptTokens == fresh?.usage?.promptTokens)
        #expect(shared?.finishReason == fresh?.finishReason)
        #expect(shared?.role == fresh?.role)
    }
    #expect(ProviderLoop.parseStreamChunk(ServerSentEventEncoder.done, decoder: decoder) == nil)
}

@Test("an unparsed frame is a parse failure unless it is the [DONE] sentinel")
func unparsedFrameClassification() throws {
    #expect(!ProviderLoop.isUnparsedStreamFrame(ServerSentEventEncoder.done, parsed: nil))
    #expect(!ProviderLoop.isUnparsedStreamFrame("data: [DONE]\n\n", parsed: nil))
    #expect(ProviderLoop.isUnparsedStreamFrame("data: {not json\n\n", parsed: nil))
    #expect(ProviderLoop.isUnparsedStreamFrame(": keepalive only\n\n", parsed: nil))
    let good = try encodeChunk(content: "x")
    #expect(!ProviderLoop.isUnparsedStreamFrame(good, parsed: ProviderLoop.parseStreamChunk(good)))
}
