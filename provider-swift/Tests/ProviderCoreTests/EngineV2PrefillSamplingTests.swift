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

private final class PrefillRetirementGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var retirement: CBv2RequestRetirement {
        CBv2RequestRetirement { await self.wait() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock {
                if released {
                    return true
                }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately {
                continuation.resume()
            }
        }
    }

    func release() {
        let pending = lock.withLock {
            released = true
            let pending = waiters
            waiters.removeAll()
            return pending
        }
        for waiter in pending {
            waiter.resume()
        }
    }
}

// MARK: - Manual-script engine (controls delta timing)

private final class PrefillScriptEngine: CBv2Engine, @unchecked Sendable {
    enum DeadlineBehavior: Equatable {
        case admit
        case reject
        case suspendThenAdmit
        case suspendThenReject
    }

    private let lock = NSLock()
    private var _continuations: [AsyncStream<CBv2Event>.Continuation] = []
    private var _ordinarySubmissionCount = 0
    private var _deadlineAdmissions: [CBv2FirstTokenDeadlineAdmission] = []
    private var _deadlineRequestIDs: [CBv2RequestID] = []
    private var _cancelledRequestIDs: [CBv2RequestID] = []
    private var _admittedAt: ContinuousClock.Instant?
    private var _deadlineBehavior: DeadlineBehavior = .admit
    private var _retirement: CBv2RequestRetirement = .acknowledged
    private var _releaseSuspendedSubmissions = false
    private var _deadlineWaiters: [CheckedContinuation<Void, Never>] = []

    var continuations: [AsyncStream<CBv2Event>.Continuation] {
        lock.withLock { _continuations }
    }

    var ordinarySubmissionCount: Int {
        lock.withLock { _ordinarySubmissionCount }
    }

    var deadlineAdmissions: [CBv2FirstTokenDeadlineAdmission] {
        lock.withLock { _deadlineAdmissions }
    }

    var deadlineRequestIDs: [CBv2RequestID] {
        lock.withLock { _deadlineRequestIDs }
    }

    var cancelledRequestIDs: [CBv2RequestID] {
        lock.withLock { _cancelledRequestIDs }
    }

    func setDeadlineBehavior(_ behavior: DeadlineBehavior) {
        lock.withLock {
            _deadlineBehavior = behavior
            _releaseSuspendedSubmissions = false
        }
    }

    func setAdmittedAt(_ instant: ContinuousClock.Instant?) {
        lock.withLock { _admittedAt = instant }
    }

    func setRetirement(_ retirement: CBv2RequestRetirement) {
        lock.withLock { _retirement = retirement }
    }

    func releaseSuspendedDeadlineSubmissions() {
        let waiters = lock.withLock {
            _releaseSuspendedSubmissions = true
            let waiters = _deadlineWaiters
            _deadlineWaiters.removeAll()
            return waiters
        }
        for waiter in waiters {
            waiter.resume()
        }
    }

    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { _ordinarySubmissionCount += 1 }
        return makeStream()
    }

    func submit(
        _ request: CBv2Request,
        firstTokenDeadline: CBv2FirstTokenDeadlineAdmission
    ) async throws -> CBv2FirstTokenDeadlineResult {
        let behavior = lock.withLock {
            _deadlineAdmissions.append(firstTokenDeadline)
            _deadlineRequestIDs.append(request.id)
            return _deadlineBehavior
        }
        let (admittedAt, retirement) = lock.withLock {
            (_admittedAt ?? .now, _retirement)
        }

        if behavior == .suspendThenAdmit || behavior == .suspendThenReject {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if _releaseSuspendedSubmissions {
                        return true
                    }
                    _deadlineWaiters.append(continuation)
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
            try Task.checkCancellation()
        }

        let projectedWork = CBv2FirstTokenProjectedWork.bounded(
            work: CBv2FirstTokenScheduledWork(
                prefillTokens: request.promptTokens.count,
                decodeTokens: 0,
                scheduledSteps: 1,
                mixedSteps: 0),
            serviceDuration: .milliseconds(1))
        switch behavior {
        case .admit, .suspendThenAdmit:
            return .admitted(
                stream: makeStream(),
                projectedWork: projectedWork,
                admittedAt: admittedAt,
                retirement: retirement)
        case .reject, .suspendThenReject:
            return .deadlineUnreachable(projectedWork: projectedWork)
        }
    }

    private func makeStream() -> AsyncStream<CBv2Event> {
        let (stream, continuation) = AsyncStream<CBv2Event>.makeStream()
        lock.withLock { _continuations.append(continuation) }
        return stream
    }
    func cancel(_ id: CBv2RequestID) {
        let continuation = lock.withLock {
            _cancelledRequestIDs.append(id)
            return _continuations.last
        }
        continuation?.yield(.finished(
            reason: .cancelled,
            usage: CBv2Usage(promptTokens: 0, completionTokens: 0)))
        continuation?.finish()
    }
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

    @Test("scheduler prefill rate excludes rows submitted behind any active phase")
    func isolatedRateExcludesActiveAndQueuedWork() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [])
        let request = ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")])
        let tokens = Array(repeating: 7, count: 200)

        let firstStream = await bridge.submitTokenized(
            promptTokens: tokens, request: request, requestId: "isolated-first")
        let firstConsumer = Task { for await _ in firstStream {} }
        await bridge.backdateSubmissionForTesting(
            requestId: "isolated-first", byMilliseconds: 1_000)

        let queuedStream = await bridge.submitTokenized(
            promptTokens: tokens, request: request, requestId: "queued-second")
        let queuedConsumer = Task { for await _ in queuedStream {} }
        await bridge.backdateSubmissionForTesting(
            requestId: "queued-second", byMilliseconds: 100)

        let firstContinuation = try #require(engine.continuations.first)
        firstContinuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        firstContinuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: tokens.count, completionTokens: 1)))
        firstContinuation.finish()
        _ = await firstConsumer.value
        let isolatedAfterFirst = await bridge._testIsolatedPrefillTps()
        #expect(isolatedAfterFirst == 0)

        let queuedContinuation = try #require(engine.continuations.last)
        queuedContinuation.yield(.delta(text: "x", tokens: [12], logprobs: nil))
        queuedContinuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: tokens.count, completionTokens: 1)))
        queuedContinuation.finish()
        _ = await queuedConsumer.value

        #expect(await bridge._testIsolatedPrefillTps() == isolatedAfterFirst)
        #expect(await bridge.observedPrefillTpsEwma > 0)
    }

    @Test("active decode work disqualifies an isolated prefill sample")
    func isolatedRateExcludesDecodeContention() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [])
        let request = ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")])
        let tokens = Array(repeating: 7, count: 200)

        let decoder = await bridge.submitTokenized(
            promptTokens: tokens,
            request: request,
            requestId: "active-decoder")
        let decoderConsumer = Task { for await _ in decoder {} }
        let decoderContinuation = try #require(engine.continuations.first)
        decoderContinuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))

        let contended = await bridge.submitTokenized(
            promptTokens: tokens,
            request: request,
            requestId: "decode-contended-prefill")
        let contendedConsumer = Task { for await _ in contended {} }
        await bridge.backdateSubmissionForTesting(
            requestId: "decode-contended-prefill",
            byMilliseconds: 100)
        let contendedContinuation = try #require(engine.continuations.last)
        contendedContinuation.yield(.delta(text: "x", tokens: [12], logprobs: nil))
        contendedContinuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: tokens.count, completionTokens: 1)))
        contendedContinuation.finish()
        _ = await contendedConsumer.value

        #expect(await bridge._testIsolatedPrefillTps() == 0)
        #expect(await bridge.observedPrefillTpsEwma > 0)

        decoderContinuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: tokens.count, completionTokens: 1)))
        decoderContinuation.finish()
        _ = await decoderConsumer.value
    }

    @Test("multi-token first emission is excluded from decode throughput")
    func firstMTPBurstDoesNotInflateDecodeRate() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [])
        let request = ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")],
            max_tokens: 3)

        let stream = await bridge.submitTokenized(
            promptTokens: [1, 2, 3],
            request: request,
            requestId: "mtp-first-burst")
        let consumer = Task { for await _ in stream {} }
        let continuation = try #require(engine.continuations.last)
        continuation.yield(
            .delta(text: "abc", tokens: [11, 12, 13], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: 3, completionTokens: 3)))
        continuation.finish()
        _ = await consumer.value

        #expect(await bridge.observedDecodeTpsEwma == 0)
    }
}

// MARK: - Atomic first-token deadline admission

@Suite("EngineV2 atomic first-token deadline admission")
struct EngineV2FirstTokenDeadlineAdmissionTests {
    private let promptTokens = Array(repeating: 7, count: 200)

    private var request: ChatCompletionRequest {
        ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")],
            max_tokens: 1)
    }

    private func makeBridge(
        engine: PrefillScriptEngine,
        mode: PrefillDeadlineMode,
        budget: GlobalKVCacheBudget? = nil
    ) -> EngineV2Bridge {
        EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [],
            prefillDeadlineMode: mode,
            kvBytesPerToken: budget == nil ? 0 : 4_000,
            kvBudget: budget)
    }

    private func makeProductionBridge(
        engine: PrefillScriptEngine,
        configuredMode: PrefillDeadlineMode? = nil,
        environment: [String: String]
    ) throws -> EngineV2Bridge {
        try EngineV2Factory.makeBridge(
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [],
            prefillDeadlineMode: configuredMode,
            runtimePolicyEnvironment: environment,
            makeEngine: {
                EngineV2Factory.ProductionBuild(
                    engine: engine,
                    fixedRequestBytes: 0,
                    kvBackendKind: .contiguous,
                    kvBackendFallbackReason: nil)
            })
    }

    private func ampleBudget() -> GlobalKVCacheBudget {
        let gib: UInt64 = 1_073_741_824
        return GlobalKVCacheBudget(
            capFraction: 0.9,
            activationReserveBytes: 0,
            memorySnapshot: {
                .init(
                    total: 8 * gib,
                    active: 0,
                    cache: 0,
                    systemAvailable: 8 * gib)
            })
    }

    @discardableResult
    private func measureColdPrefillRate(
        bridge: EngineV2Bridge,
        engine: PrefillScriptEngine
    ) async throws -> Double {
        let stream = await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "measure-cold-prefill")
        let consumer = Task { for await _ in stream {} }
        await bridge.backdateSubmissionForTesting(
            requestId: "measure-cold-prefill",
            byMilliseconds: 1_000)
        let continuation = try #require(engine.continuations.last)
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(
                promptTokens: promptTokens.count,
                completionTokens: 1)))
        continuation.finish()
        _ = await consumer.value

        let measured = await bridge.observedPrefillTpsEwma
        #expect(measured > 0)
        #expect(await bridge._testIsolatedPrefillTps() == measured)
        return measured
    }

    private func finishLatestSubmission(
        _ stream: AsyncStream<GenerationEvent>,
        engine: PrefillScriptEngine
    ) async throws {
        let consumer = Task { for await _ in stream {} }
        let continuation = try #require(engine.continuations.last)
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(
                promptTokens: promptTokens.count,
                completionTokens: 0)))
        continuation.finish()
        _ = await consumer.value
    }

    private func deadline(
        budgetMilliseconds: Int64 = 60_000,
        elapsedMilliseconds: Int64 = 0
    ) -> FirstContentDeadline {
        FirstContentDeadline(
            relativeBudgetMilliseconds: budgetMilliseconds,
            receivedAt: ContinuousClock.now.advanced(
                by: .milliseconds(-elapsedMilliseconds)))
    }

    private func waitForDeadlineSubmission(
        _ engine: PrefillScriptEngine
    ) async -> Bool {
        for _ in 0 ..< 1_000 {
            if !engine.deadlineAdmissions.isEmpty {
                return true
            }
            await Task.yield()
        }
        return false
    }

    @Test("enforce mode carries absolute monotonic deadline and conservative phase rates")
    func enforceUsesAtomicAdmission() async throws {
        let engine = PrefillScriptEngine()
        let bridge = try makeProductionBridge(
            engine: engine,
            environment: [
                PrefillDeadlineMode.environmentKey: "enforce",
                EngineV2Factory.maxPartialPrefillsKey: "1",
            ])
        #expect(await bridge.prefillDeadlineMode == .enforce)
        #expect(await bridge.prefillDeadlineProjectionEnabled)
        let measured = try await measureColdPrefillRate(
            bridge: bridge,
            engine: engine)

        let committedAt = ContinuousClock.now.advanced(by: .milliseconds(-100))
        engine.setAdmittedAt(committedAt)
        let expectedDeadline = deadline(
            budgetMilliseconds: 10_000,
            elapsedMilliseconds: 1_000)
        let stream = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "atomic-admit",
            firstContentDeadline: expectedDeadline)

        let admission = try #require(engine.deadlineAdmissions.first)
        #expect(admission.deadline == expectedDeadline.instant)
        #expect(
            admission.conservativePrefillTokensPerSecond
                == measured * EngineV2Bridge.deadlineProjectionRateHaircut)
        #expect(admission.conservativeDecodeTokensPerSecond == nil)
        #expect(
            await bridge._testSubmissionInstant(requestId: "atomic-admit")
                == committedAt)
        #expect(engine.ordinarySubmissionCount == 1)
        #expect(await bridge._testLivePumpCount() == 1)
        try await finishLatestSubmission(stream, engine: engine)
    }

    @Test("cap zero bypasses atomic forecast but preserves serving and hard expiry")
    func capZeroUsesOrdinarySubmission() async throws {
        let engine = PrefillScriptEngine()
        let bridge = try makeProductionBridge(
            engine: engine,
            environment: [
                PrefillDeadlineMode.environmentKey: "enforce",
                EngineV2Factory.maxPartialPrefillsKey: "0",
            ])
        #expect(await bridge.prefillDeadlineMode == .enforce)
        #expect(!(await bridge.prefillDeadlineProjectionEnabled))
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.reject)

        let liveDeadline = deadline()
        let stream = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "cap-zero-serving-rollback",
            firstContentDeadline: liveDeadline)
        #expect(engine.deadlineAdmissions.isEmpty)
        #expect(engine.ordinarySubmissionCount == 2)
        try await finishLatestSubmission(stream, engine: engine)

        let expired = deadline(budgetMilliseconds: 0, elapsedMilliseconds: 1)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "cap-zero-expired",
                firstContentDeadline: expired)
        }
        #expect(engine.deadlineAdmissions.isEmpty)
        #expect(engine.ordinarySubmissionCount == 2)
    }

    @Test("deadline policy supplies independently observed decode rate")
    func enforceUsesSeparateDecodeRate() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)

        let decodeRequest = ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")],
            max_tokens: 3)
        let decodeStream = await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: decodeRequest,
            requestId: "measure-decode")
        let decodeConsumer = Task { for await _ in decodeStream {} }
        let decodeContinuation = try #require(engine.continuations.last)
        decodeContinuation.yield(.delta(text: "a", tokens: [11], logprobs: nil))
        try await Task.sleep(for: .milliseconds(20))
        decodeContinuation.yield(
            .delta(text: "bc", tokens: [12, 13], logprobs: nil))
        decodeContinuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(
                promptTokens: promptTokens.count,
                completionTokens: 3)))
        decodeContinuation.finish()
        _ = await decodeConsumer.value
        let measuredDecode = await bridge.observedDecodeTpsEwma
        #expect(measuredDecode > 0)

        let deadlineStream = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "atomic-with-decode-rate",
            firstContentDeadline: deadline())
        let admission = try #require(engine.deadlineAdmissions.last)
        #expect(
            admission.conservativeDecodeTokensPerSecond
                == measuredDecode * EngineV2Bridge.deadlineProjectionRateHaircut)
        try await finishLatestSubmission(deadlineStream, engine: engine)
    }

    @Test("deadline rejection releases resources and never starts a pump")
    func rejectionReleasesResourcesWithoutPump() async throws {
        let engine = PrefillScriptEngine()
        let budget = ampleBudget()
        let bridge = makeBridge(
            engine: engine,
            mode: .enforce,
            budget: budget)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.reject)

        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "atomic-reject",
                firstContentDeadline: deadline())
        }

        #expect(engine.deadlineAdmissions.count == 1)
        #expect(engine.continuations.count == 1)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testLivePumpCount() == 0)
        #expect(await bridge._testCounters().active == 0)
    }

    @Test("live off, missing deadline, unmeasured rate, and multimodal requests fail open")
    func failOpenCasesUseOrdinarySubmit() async throws {
        let offEngine = PrefillScriptEngine()
        let offBridge = try makeProductionBridge(
            engine: offEngine,
            configuredMode: .off,
            environment: [
                EngineV2Factory.maxPartialPrefillsKey: "1",
            ])
        #expect(await offBridge.prefillDeadlineMode == .off)
        #expect(await offBridge.prefillDeadlineProjectionEnabled)
        _ = try await measureColdPrefillRate(bridge: offBridge, engine: offEngine)
        offEngine.setDeadlineBehavior(.reject)
        let offStream = try await offBridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "mode-off",
            firstContentDeadline: deadline())
        #expect(offEngine.deadlineAdmissions.isEmpty)
        #expect(offEngine.ordinarySubmissionCount == 2)
        try await finishLatestSubmission(offStream, engine: offEngine)

        let missingEngine = PrefillScriptEngine()
        let missingBridge = makeBridge(engine: missingEngine, mode: .enforce)
        _ = try await measureColdPrefillRate(
            bridge: missingBridge,
            engine: missingEngine)
        missingEngine.setDeadlineBehavior(.reject)
        let missingStream = try await missingBridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "missing-deadline",
            firstContentDeadline: nil)
        #expect(missingEngine.deadlineAdmissions.isEmpty)
        #expect(missingEngine.ordinarySubmissionCount == 2)
        try await finishLatestSubmission(missingStream, engine: missingEngine)

        let unmeasuredEngine = PrefillScriptEngine()
        let unmeasuredBridge = makeBridge(
            engine: unmeasuredEngine,
            mode: .enforce)
        unmeasuredEngine.setDeadlineBehavior(.reject)
        let unmeasuredStream = try await unmeasuredBridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "unmeasured-rate",
            firstContentDeadline: deadline())
        #expect(unmeasuredEngine.deadlineAdmissions.isEmpty)
        #expect(unmeasuredEngine.ordinarySubmissionCount == 1)
        try await finishLatestSubmission(
            unmeasuredStream,
            engine: unmeasuredEngine)

        let mediaEngine = PrefillScriptEngine()
        let mediaBridge = makeBridge(engine: mediaEngine, mode: .enforce)
        _ = try await measureColdPrefillRate(
            bridge: mediaBridge,
            engine: mediaEngine)
        mediaEngine.setDeadlineBehavior(.reject)
        let mediaStream = try await mediaBridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "multimodal",
            multimodal: CBv2MultimodalInput(
                spans: [],
                embeddings: { [] }),
            firstContentDeadline: deadline())
        #expect(mediaEngine.deadlineAdmissions.isEmpty)
        #expect(mediaEngine.ordinarySubmissionCount == 2)
        try await finishLatestSubmission(mediaStream, engine: mediaEngine)
    }

    @Test("expired requests never ordinary-submit through fail-open branches")
    func expiredRequestsNeverFailOpen() async throws {
        let expired = deadline(budgetMilliseconds: 0, elapsedMilliseconds: 1)

        let offEngine = PrefillScriptEngine()
        let offBridge = makeBridge(engine: offEngine, mode: .off)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await offBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-off",
                firstContentDeadline: expired)
        }
        #expect(offEngine.ordinarySubmissionCount == 0)

        let unmeasuredEngine = PrefillScriptEngine()
        let unmeasuredBridge = makeBridge(
            engine: unmeasuredEngine,
            mode: .enforce)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await unmeasuredBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-unmeasured",
                firstContentDeadline: expired)
        }
        #expect(unmeasuredEngine.ordinarySubmissionCount == 0)

        let mediaEngine = PrefillScriptEngine()
        let mediaBridge = makeBridge(engine: mediaEngine, mode: .enforce)
        _ = try await measureColdPrefillRate(
            bridge: mediaBridge,
            engine: mediaEngine)
        let ordinaryBeforeMedia = mediaEngine.ordinarySubmissionCount
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await mediaBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-multimodal",
                multimodal: CBv2MultimodalInput(
                    spans: [],
                    embeddings: { [] }),
                firstContentDeadline: expired)
        }
        #expect(mediaEngine.ordinarySubmissionCount == ordinaryBeforeMedia)
    }

    @Test("pending submission guard blocks a reentrant duplicate ID")
    func pendingGuardBlocksDuplicate() async throws {
        let engine = PrefillScriptEngine()
        let budget = ampleBudget()
        let bridge = makeBridge(
            engine: engine,
            mode: .enforce,
            budget: budget)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.suspendThenReject)

        let first = Task { () -> PreContentDeadlineFailure? in
            do {
                _ = try await bridge.submitTokenized(
                    promptTokens: promptTokens,
                    request: request,
                    requestId: "duplicate-id",
                    firstContentDeadline: deadline())
                return nil
            } catch let failure as PreContentDeadlineFailure {
                return failure
            } catch {
                Issue.record("unexpected first submission error: \(error)")
                return nil
            }
        }

        #expect(await waitForDeadlineSubmission(engine))
        #expect(await bridge._testPendingSubmissionCount() == 1)
        #expect(await budget.outstandingReservedBytes() > 0)

        let duplicate = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "duplicate-id",
            firstContentDeadline: deadline())
        var duplicateMessage: String?
        for await event in duplicate {
            if case .error(let message) = event {
                duplicateMessage = message
            }
        }
        #expect(duplicateMessage == "token_budget_exhausted: duplicate request ID")
        #expect(engine.deadlineAdmissions.count == 1)

        engine.releaseSuspendedDeadlineSubmissions()
        #expect(await first.value == .deadlineUnreachable)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testLivePumpCount() == 0)
    }

    @Test("cancellation during suspended atomic admission releases every reservation")
    func cancellationDuringSuspendedAdmissionReleasesResources() async throws {
        let engine = PrefillScriptEngine()
        let budget = ampleBudget()
        let bridge = makeBridge(
            engine: engine,
            mode: .enforce,
            budget: budget)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.suspendThenReject)

        let submission = Task {
            try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "cancel-suspended-admission",
                firstContentDeadline: deadline())
        }
        #expect(await waitForDeadlineSubmission(engine))
        #expect(await bridge._testPendingSubmissionCount() == 1)
        #expect(await bridge._testPendingEngineIDCount() == 1)
        #expect(await budget.outstandingReservedBytes() > 0)

        submission.cancel()
        engine.releaseSuspendedDeadlineSubmissions()
        await #expect(throws: CancellationError.self) {
            _ = try await submission.value
        }

        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testPendingEngineIDCount() == 0)
        #expect(await bridge._testLivePumpCount() == 0)
        #expect(await bridge._testCounters().active == 0)
    }

    @Test("explicit provider cancel survives suspended atomic admission")
    func explicitCancelDuringSuspendedAdmissionIsAcknowledged() async throws {
        let engine = PrefillScriptEngine()
        let budget = ampleBudget()
        let bridge = makeBridge(
            engine: engine,
            mode: .enforce,
            budget: budget)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.suspendThenReject)
        let requestID = "explicit-cancel-suspended-admission"

        let submission = Task {
            try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: requestID,
                firstContentDeadline: deadline())
        }
        #expect(await waitForDeadlineSubmission(engine))
        await bridge.cancel(requestId: requestID)
        engine.releaseSuspendedDeadlineSubmissions()

        await #expect(throws: CancellationError.self) {
            _ = try await submission.value
        }
        #expect(engine.cancelledRequestIDs.count == 1)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testPendingEngineIDCount() == 0)
        #expect(await bridge._testLivePumpCount() == 0)
    }

    @Test("post-commit cancel transfers cleanup until engine retirement")
    func postCommitCancellationWaitsForRetirementAcknowledgement() async throws {
        let engine = PrefillScriptEngine()
        let budget = ampleBudget()
        let bridge = makeBridge(
            engine: engine,
            mode: .enforce,
            budget: budget)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        let retirementGate = PrefillRetirementGate()
        engine.setRetirement(retirementGate.retirement)
        engine.setDeadlineBehavior(.suspendThenAdmit)
        let requestID = "post-commit-retirement-ack"

        let submission = Task {
            try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: requestID,
                firstContentDeadline: deadline())
        }
        #expect(await waitForDeadlineSubmission(engine))
        await bridge.cancel(requestId: requestID)
        engine.releaseSuspendedDeadlineSubmissions()

        // The first cancel reaches the suspended admission; the second is the
        // bridge acknowledging that admission committed despite that cancel.
        for _ in 0 ..< 1_000 where engine.cancelledRequestIDs.count < 2 {
            await Task.yield()
        }
        #expect(engine.cancelledRequestIDs.count == 2)
        #expect(
            await budget.outstandingReservedBytes() > 0,
            "consumer terminal alone must not release provider-global KV")

        await #expect(throws: CancellationError.self) {
            _ = try await submission.value
        }
        #expect(await bridge._testPendingSubmissionCount() == 1)
        #expect(await bridge._testPendingEngineIDCount() == 1)
        #expect(await bridge._testMappedRequestCount() == 1)
        let duplicate = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: requestID,
            firstContentDeadline: deadline())
        var duplicateMessage: String?
        for await event in duplicate {
            if case .error(let message) = event {
                duplicateMessage = message
            }
        }
        #expect(duplicateMessage == "token_budget_exhausted: duplicate request ID")

        retirementGate.release()
        for _ in 0 ..< 100 {
            if await bridge._testPendingSubmissionCount() == 0 {
                break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testPendingEngineIDCount() == 0)
        #expect(await bridge._testMappedRequestCount() == 0)
        #expect(await bridge._testLivePumpCount() == 0)
    }

    @Test("concurrent identical seeded admissions reserve distinct engine IDs")
    func seededEngineIDsAreReservedAcrossAdmission() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.suspendThenReject)
        let seededRequest = ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")],
            max_tokens: 1,
            seed: 42)

        func submit(_ requestID: String) async -> PreContentDeadlineFailure? {
            do {
                _ = try await bridge.submitTokenized(
                    promptTokens: promptTokens,
                    request: seededRequest,
                    requestId: requestID,
                    firstContentDeadline: deadline())
                return nil
            } catch let failure as PreContentDeadlineFailure {
                return failure
            } catch {
                Issue.record("unexpected seeded submission error: \(error)")
                return nil
            }
        }

        let first = Task { await submit("seeded-a") }
        #expect(await waitForDeadlineSubmission(engine))
        let second = Task { await submit("seeded-b") }
        for _ in 0 ..< 1_000 where engine.deadlineAdmissions.count < 2 {
            await Task.yield()
        }

        #expect(engine.deadlineAdmissions.count == 2)
        #expect(Set(engine.deadlineRequestIDs).count == 2)
        #expect(await bridge._testPendingEngineIDCount() == 2)

        engine.releaseSuspendedDeadlineSubmissions()
        #expect(await first.value == .deadlineUnreachable)
        #expect(await second.value == .deadlineUnreachable)
        #expect(await bridge._testPendingEngineIDCount() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
    }

    @Test("typed deadline failure keeps retryable compatibility fields")
    func typedFailureMapping() {
        let failure = ProviderLoop.sanitizedInferenceFailure(
            from: PreContentDeadlineFailure.deadlineUnreachable,
            phase: .streamStart)

        #expect(failure.code == .capacity)
        #expect(failure.statusCode == 503)
        #expect(failure.errorReason == .deadlineUnreachable)
        #expect(failure.errorReason?.rawValue == "deadline_unreachable")
    }
}
