// Copyright © 2026 Eigen Labs.
//
// observed_prefill_tps on the v2 bridge (v0.7.5, absorbing PR #454's
// approach): prefill window = first-token time − submit; rate = prompt
// tokens / window; EWMA α = 0.3 like the decode signal; plausibility
// bounds (1 ms window floor, 20k tok/s ceiling) reject degenerate samples
// instead of poisoning the EWMA the coordinator's TTFT estimation reads.

import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

// MARK: - Manual-script engine (controls delta timing)

private final class PrefillScriptEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var _continuations: [AsyncStream<CBv2Event>.Continuation] = []

    var continuations: [AsyncStream<CBv2Event>.Continuation] {
        lock.withLock { _continuations }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { _continuations.append(continuation) }
        return stream
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        CBv2CapacitySnapshot(
            activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0,
            kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

private struct PrefillStubTokenizer: MLXLMCommon.Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "x" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [1, 2, 3] }
}

@Suite("EngineV2 prefill sampling (observed_prefill_tps)")
struct EngineV2PrefillSamplingTests {

    @Test("classifier bounds: floor, ceiling, finite, positive tokens")
    func classifierBounds() {
        // Below the 1 ms window floor → dropped (would divide into absurd rates).
        #expect(EngineV2Bridge.classifyPrefillSample(
            prefilledTokens: 500, prefillSeconds: 0.0005) == nil)
        // Above the 20k tok/s plausibility ceiling → dropped.
        #expect(EngineV2Bridge.classifyPrefillSample(
            prefilledTokens: 400_000, prefillSeconds: 1.0) == nil)
        // Zero/negative tokens → dropped.
        #expect(EngineV2Bridge.classifyPrefillSample(
            prefilledTokens: 0, prefillSeconds: 1.0) == nil)
        // PR #454's fast-cold band (its measured p90 was ~17,707 tok/s) is
        // ACCEPTED under the raised ceiling.
        #expect(EngineV2Bridge.classifyPrefillSample(
            prefilledTokens: 17_707, prefillSeconds: 1.0) == 17_707)
        // A normal cold prefill accepts at its real rate.
        let tps = EngineV2Bridge.classifyPrefillSample(
            prefilledTokens: 1_000, prefillSeconds: 2.0)
        #expect(tps == 500)
    }

    @Test("terminal cache outcome admits only genuinely cold prefills")
    func coldOutcomeClassifier() {
        for outcome in [
            CBv2PrefixCacheOutcome.disabled, .miss, .skippedPolicy,
            .skippedCapacity, .adoptionFailed,
        ] {
            #expect(EngineV2Bridge.isColdPrefillSample(usage: CBv2Usage(
                promptTokens: 100,
                completionTokens: 1,
                prefixCacheOutcome: outcome)))
        }
        #expect(!EngineV2Bridge.isColdPrefillSample(usage: CBv2Usage(
            promptTokens: 100,
            completionTokens: 1,
            prefixCacheOutcome: .hit,
            prefixCacheMatchedTokens: 64,
            prefixCachePrefillTokensSaved: 48)))
        // Saved-token truth is authoritative even if an older/malformed
        // engine reports a non-hit enum.
        #expect(!EngineV2Bridge.isColdPrefillSample(usage: CBv2Usage(
            promptTokens: 100,
            completionTokens: 1,
            prefixCacheOutcome: .miss,
            prefixCachePrefillTokensSaved: 48)))
        // A real hit can be invalidated by preemption before terminal usage.
        // The engine then reports adoptionFailed/saved=0 but retains the raw
        // matched prefix. It is not a trustworthy cold-prefill sample.
        #expect(!EngineV2Bridge.isColdPrefillSample(usage: CBv2Usage(
            promptTokens: 100,
            completionTokens: 1,
            prefixCacheOutcome: .adoptionFailed,
            prefixCacheMatchedTokens: 64,
            prefixCachePrefillTokensSaved: 0)))
    }

    @Test("successful finish feeds the EWMA from submit→first-token timing")
    func ewmaPopulatedFromRealTiming() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: []
        )

        // Baseline: no samples yet.
        #expect(await bridge.backendSlotCapacity().observedPrefillTps == 0)

        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 7, count: 200),
            request: ChatCompletionRequest(
                model: "gpt-oss-20b",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-prefill-1")
        let consumer = Task { for await _ in stream {} }

        // Hold the "prefill" open for a real, floor-clearing window before
        // the first token arrives, then finish.
        try await Task.sleep(for: .milliseconds(50))
        let continuation = try #require(engine.continuations.first)
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop, usage: CBv2Usage(promptTokens: 200, completionTokens: 1)))
        continuation.finish()
        _ = await consumer.value

        let reported = await bridge.backendSlotCapacity().observedPrefillTps
        // 200 tokens over ≥50 ms ⇒ ≤ 4,000 tok/s, comfortably plausible and
        // non-zero. Bound it loosely (scheduling jitter) rather than pin it.
        #expect(reported > 0)
        #expect(reported <= 4_100)
    }

    @Test("cancelled requests never feed the prefill EWMA")
    func cancelledRequestsDoNotSample() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: []
        )
        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 7, count: 200),
            request: ChatCompletionRequest(
                model: "gpt-oss-20b",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-prefill-cancel")
        let consumer = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(20))
        let continuation = try #require(engine.continuations.first)
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(
            reason: .cancelled, usage: CBv2Usage(promptTokens: 200, completionTokens: 1)))
        continuation.finish()
        _ = await consumer.value

        #expect(await bridge.backendSlotCapacity().observedPrefillTps == 0)
    }

    @Test("cache-hit submit-to-first-token timing never feeds the cold prefill EWMA")
    func cacheHitsDoNotSample() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [])
        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 7, count: 200),
            request: ChatCompletionRequest(
                model: "gpt-oss-20b",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: "req-prefill-hit")
        let consumer = Task { for await _ in stream {} }
        try await Task.sleep(for: .milliseconds(50))
        let continuation = try #require(engine.continuations.first)
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(
                promptTokens: 200,
                completionTokens: 1,
                prefixCacheHitTokens: 128,
                prefixCacheOutcome: .hit,
                prefixCacheMatchedTokens: 160,
                prefixCachePrefillTokensSaved: 128)))
        continuation.finish()
        _ = await consumer.value

        #expect(await bridge.backendSlotCapacity().observedPrefillTps == 0)
    }
}
