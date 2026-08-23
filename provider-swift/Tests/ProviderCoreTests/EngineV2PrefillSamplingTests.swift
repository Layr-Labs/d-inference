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
        await bridge.backdateSubmissionForTesting(
            requestId: "req-prefill-hit", byMilliseconds: 50)
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

// MARK: - Queue-excluded companion EWMA

/// `observedPrefillTpsEwma` above is load-INCLUSIVE by contract (window starts
/// at admission; `protocol/messages.go:277`). The prefill-deadline gate adds an
/// explicit queued-tokens term, so dividing by that rate counts contention
/// twice. `isolatedPrefillTpsEwma` is the queue-excluded companion the gate
/// divides by: same samples, but only from rows that were admitted with no
/// other prefill in flight.
@Suite("EngineV2 isolated prefill EWMA (queue-excluded)")
struct EngineV2IsolatedPrefillSamplingTests {

    private func makeBridge(_ engine: PrefillScriptEngine) -> EngineV2Bridge {
        EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [])
    }

    private func submit(
        _ bridge: EngineV2Bridge, _ id: String
    ) async -> Task<Void, Never> {
        let stream = await bridge.submitTokenized(
            promptTokens: Array(repeating: 7, count: 200),
            request: ChatCompletionRequest(
                model: "gpt-oss-20b",
                messages: [ChatMessage(role: "user", content: "hi")]),
            requestId: id)
        return Task { for await _ in stream {} }
    }

    private func finish(_ continuation: AsyncStream<CBv2Event>.Continuation) {
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop, usage: CBv2Usage(promptTokens: 200, completionTokens: 1)))
        continuation.finish()
    }

    @Test("a row admitted onto an idle engine feeds both EWMAs")
    func uncontendedRowFeedsIsolatedEwma() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine)
        #expect(await bridge.isolatedPrefillTpsEwma == 0)

        let consumer = await submit(bridge, "solo")
        await bridge.backdateSubmissionForTesting(
            requestId: "solo", byMilliseconds: 50)
        finish(try #require(engine.continuations.first))
        _ = await consumer.value

        #expect(await bridge.observedPrefillTpsEwma > 0)
        #expect(await bridge.isolatedPrefillTpsEwma > 0)
    }

    /// The discriminating case. `second` is admitted while `first` is still
    /// prefilling, so its submit→first-token window is mostly queue wait. That
    /// sample is fine for the load-inclusive signal and must NOT calibrate the
    /// rate the deadline projection divides by — feeding it there is exactly
    /// the double-count this companion exists to remove.
    @Test("a row admitted behind an in-flight prefill feeds only the load-inclusive EWMA")
    func contendedRowIsExcluded() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine)

        let firstConsumer = await submit(bridge, "first")
        // `first` has not reached its first token, so `second` is contended.
        let secondConsumer = await submit(bridge, "second")
        #expect(engine.continuations.count == 2)

        await bridge.backdateSubmissionForTesting(
            requestId: "second", byMilliseconds: 50)
        finish(engine.continuations[1])
        _ = await secondConsumer.value

        #expect(await bridge.observedPrefillTpsEwma > 0)
        #expect(
            await bridge.isolatedPrefillTpsEwma == 0,
            "a queued row must not calibrate the queue-excluded rate")

        // ...and the predicate discriminates rather than being off entirely:
        // `first` WAS admitted onto an idle engine, so it still qualifies.
        await bridge.backdateSubmissionForTesting(
            requestId: "first", byMilliseconds: 50)
        finish(engine.continuations[0])
        _ = await firstConsumer.value
        #expect(await bridge.isolatedPrefillTpsEwma > 0)
    }

    /// Fail-open: a box that has never seen an idle prefill has no
    /// queue-excluded rate, so the gate must admit rather than guess.
    @Test("the gate fails open while the isolated EWMA is unmeasured")
    func gateFailsOpenWhileUnmeasured() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine)
        let firstConsumer = await submit(bridge, "first")
        let secondConsumer = await submit(bridge, "second")
        await bridge.backdateSubmissionForTesting(
            requestId: "second", byMilliseconds: 50)
        finish(engine.continuations[1])
        _ = await secondConsumer.value

        // Load-inclusive rate is measured, queue-excluded is not.
        #expect(await bridge.observedPrefillTpsEwma > 0)
        #expect(await bridge.prefillDeadlineRefusal(promptTokens: 8192) == nil)

        finish(engine.continuations[0])
        _ = await firstConsumer.value
    }
}
