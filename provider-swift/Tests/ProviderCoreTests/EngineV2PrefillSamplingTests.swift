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
        /// Refuse with `.unbounded` (ledger `canGuarantee` failure, nil
        /// decode rate with decode work, multimodal peer — no finite
        /// projection exists).
        case rejectUnbounded
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
        case .rejectUnbounded:
            return .deadlineUnreachable(projectedWork: .unbounded)
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
        budget: GlobalKVCacheBudget? = nil,
        maxConcurrentRequests: Int = 4
    ) -> EngineV2Bridge {
        EngineV2Bridge(
            engine: engine,
            modelId: "gpt-oss-20b",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()),
            eosTokenIds: [],
            maxConcurrentRequests: maxConcurrentRequests,
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

    /// Number of isolated cold samples the bridge needs before it enforces
    /// deadline projection (the cold-start wedge floor).
    private let sampleFloor = EngineV2Bridge.isolatedPrefillSampleFloor

    /// Record one isolated cold prefill sample: submit while idle, backdate
    /// the submission by `prefillMilliseconds`, deliver a first token and a
    /// cold `.stop` terminal.
    private func recordIsolatedColdSample(
        bridge: EngineV2Bridge,
        engine: PrefillScriptEngine,
        requestId: String,
        prefillMilliseconds: Int64 = 1_000,
        completionTokens: Int = 1
    ) async throws {
        let stream = await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: requestId)
        let consumer = Task { for await _ in stream {} }
        await bridge.backdateSubmissionForTesting(
            requestId: requestId,
            byMilliseconds: prefillMilliseconds)
        let continuation = try #require(engine.continuations.last)
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(
                promptTokens: promptTokens.count,
                completionTokens: completionTokens)))
        continuation.finish()
        _ = await consumer.value
    }

    /// Seed the bridge past the enforcement floor with `sampleFloor`
    /// identical isolated cold samples (identical rates keep both prefill
    /// EWMAs equal to the measured value), so the next deadline-bearing
    /// submission is projected atomically.
    @discardableResult
    private func measureColdPrefillRate(
        bridge: EngineV2Bridge,
        engine: PrefillScriptEngine
    ) async throws -> Double {
        for index in 0 ..< sampleFloor {
            try await recordIsolatedColdSample(
                bridge: bridge,
                engine: engine,
                requestId: "measure-cold-prefill-\(index)")
        }

        let measured = await bridge.observedPrefillTpsEwma
        #expect(measured > 0)
        #expect(await bridge._testIsolatedPrefillTps() == measured)
        #expect(await bridge._testIsolatedPrefillSampleCount() == sampleFloor)
        return measured
    }

    /// Hold one ordinary (deadline-free) row open so the bridge has an
    /// active request; the caller finishes it via the returned handle.
    private func holdOpenRow(
        bridge: EngineV2Bridge,
        engine: PrefillScriptEngine,
        requestId: String,
        multimodal: CBv2MultimodalInput? = nil
    ) async -> (consumer: Task<Void, Never>, continuation: AsyncStream<CBv2Event>.Continuation) {
        let stream = await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: requestId,
            multimodal: multimodal)
        let consumer = Task { for await _ in stream {} }
        let continuation = engine.continuations.last!
        return (consumer, continuation)
    }

    private func finishHeldRow(
        _ row: (consumer: Task<Void, Never>, continuation: AsyncStream<CBv2Event>.Continuation)
    ) async {
        row.continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: promptTokens.count, completionTokens: 0)))
        row.continuation.finish()
        _ = await row.consumer.value
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
        #expect(engine.ordinarySubmissionCount == sampleFloor)
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
        #expect(engine.ordinarySubmissionCount == sampleFloor + 1)
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
        #expect(engine.ordinarySubmissionCount == sampleFloor + 1)
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
        #expect(engine.continuations.count == sampleFloor)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(await bridge._testLivePumpCount() == 0)
        #expect(await bridge._testCounters().active == 0)
        #expect(await bridge._testConsecutiveDeadlineRefusals() == 1)
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
        #expect(offEngine.ordinarySubmissionCount == sampleFloor + 1)
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
        #expect(missingEngine.ordinarySubmissionCount == sampleFloor + 1)
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
        #expect(mediaEngine.ordinarySubmissionCount == sampleFloor + 1)
        try await finishLatestSubmission(mediaStream, engine: mediaEngine)
    }

    // MARK: - Cold-start wedge (sample floor, refusal-driven probe, .unbounded postures)

    @Test("below the isolated-sample floor, deadline-bearing requests use ordinary submission")
    func belowSampleFloorUsesOrdinarySubmission() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        engine.setDeadlineBehavior(.reject)

        // One pathological seed — the post-load JIT/page-in request — must
        // not arm projection on its own. Keep recording until the floor.
        for index in 0 ..< sampleFloor - 1 {
            try await recordIsolatedColdSample(
                bridge: bridge,
                engine: engine,
                requestId: "seed-\(index)",
                prefillMilliseconds: 1_000_000)
            #expect(await bridge._testIsolatedPrefillTps() > 0)
            let ordinaryBefore = engine.ordinarySubmissionCount
            let stream = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "under-floor-\(index)",
                firstContentDeadline: deadline())
            #expect(engine.deadlineAdmissions.isEmpty)
            #expect(engine.ordinarySubmissionCount == ordinaryBefore + 1)
            try await finishLatestSubmission(stream, engine: engine)
        }
        #expect(await bridge._testIsolatedPrefillSampleCount() < sampleFloor)

        // The floor sample arms projection; the engine's refusal now reaches
        // the caller.
        try await recordIsolatedColdSample(
            bridge: bridge,
            engine: engine,
            requestId: "seed-floor",
            prefillMilliseconds: 1_000_000)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "at-floor",
                firstContentDeadline: deadline())
        }
        #expect(engine.deadlineAdmissions.count == 1)
    }

    @Test("a pathological seed cannot wedge the slot: the request after three refusals is admitted as an isolated probe")
    func refusalDrivenProbeHealsSlowSeed() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        // Seed the isolated rate with absurdly slow cold prefills
        // (200 tokens over 1,000 s ≈ 0.2 tok/s).
        for index in 0 ..< sampleFloor {
            try await recordIsolatedColdSample(
                bridge: bridge,
                engine: engine,
                requestId: "slow-seed-\(index)",
                prefillMilliseconds: 1_000_000)
        }
        let seededRate = await bridge._testIsolatedPrefillTps()
        #expect(seededRate > 0 && seededRate < 1)
        engine.setDeadlineBehavior(.reject)

        // K refusals: each is `deadline_unreachable`, records no sample, and
        // leaves nothing active — the wedge shape.
        let threshold = EngineV2Bridge.deadlineRefusalProbeThreshold
        for index in 0 ..< threshold {
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await bridge.submitTokenized(
                    promptTokens: promptTokens,
                    request: request,
                    requestId: "refused-\(index)",
                    firstContentDeadline: deadline(budgetMilliseconds: 9_000))
            }
            #expect(await bridge._testActiveRequestIds().isEmpty)
            #expect(await bridge._testConsecutiveDeadlineRefusals() == index + 1)
        }
        #expect(engine.deadlineAdmissions.count == threshold)
        #expect(await bridge._testIsolatedPrefillTps() == seededRate)
        let ordinaryBeforeProbe = engine.ordinarySubmissionCount

        // Request K+1 arrives while idle: ordinary submission (the probe),
        // NOT another atomic refusal, and the counter resets.
        let probe = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "probe",
            firstContentDeadline: deadline(budgetMilliseconds: 9_000))
        #expect(engine.deadlineAdmissions.count == threshold)
        #expect(engine.ordinarySubmissionCount == ordinaryBeforeProbe + 1)
        #expect(await bridge._testConsecutiveDeadlineRefusals() == 0)

        // The probe finishes with a realistic window and re-samples the
        // isolated rate (α = 0.3 moves it ≥ 30 % of the gap toward truth).
        let consumer = Task { for await _ in probe {} }
        await bridge.backdateSubmissionForTesting(
            requestId: "probe", byMilliseconds: 100)
        let continuation = try #require(engine.continuations.last)
        continuation.yield(.delta(text: "x", tokens: [11], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: promptTokens.count, completionTokens: 1)))
        continuation.finish()
        _ = await consumer.value

        let healedRate = await bridge._testIsolatedPrefillTps()
        // The probe's window is the 100 ms backdate plus whatever the test
        // scheduler added; bound the expected jump by a 1 s window so the
        // assertion is deterministic under load (α = 0.3 of the gap).
        let worstCaseTruth = Double(promptTokens.count) / 1.0
        #expect(healedRate - seededRate >= 0.3 * (worstCaseTruth - seededRate))
        #expect(await bridge._testIsolatedPrefillSampleCount() == sampleFloor + 1)

        // A probe is still a hard-expiry subject: an expired request never
        // fails open through the probe branch.
        for index in 0 ..< threshold {
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await bridge.submitTokenized(
                    promptTokens: promptTokens,
                    request: request,
                    requestId: "refused-again-\(index)",
                    firstContentDeadline: deadline(budgetMilliseconds: 9_000))
            }
        }
        #expect(await bridge._testConsecutiveDeadlineRefusals() == threshold)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "probe-expired",
                firstContentDeadline: deadline(budgetMilliseconds: 0, elapsedMilliseconds: 1))
        }
        #expect(engine.ordinarySubmissionCount == ordinaryBeforeProbe + 1)
    }

    @Test("the probe never fires at a non-isolated boundary: with a row running, refusals keep projecting")
    func probeRequiresIsolatedBoundary() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        // A decode rate exists, so a running row does not trip the
        // decode-nil fail-open; only the probe branch is under test.
        try await recordDecodeRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.reject)

        // A row is running for the whole refusal run (held open BEFORE the
        // refusals: any submission — including this ordinary one — resets
        // the counter by design, so it must precede them).
        let row = await holdOpenRow(bridge: bridge, engine: engine, requestId: "running-row")
        #expect(await bridge._testCounters().active == 1)
        let threshold = EngineV2Bridge.deadlineRefusalProbeThreshold
        for index in 0 ..< threshold {
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await bridge.submitTokenized(
                    promptTokens: promptTokens,
                    request: request,
                    requestId: "refused-\(index)",
                    firstContentDeadline: deadline())
            }
        }
        #expect(await bridge._testConsecutiveDeadlineRefusals() == threshold)

        // The K+1th arrival is NOT isolated (the row is still running), so it
        // is still projected (and refused) rather than probed.
        let admissionsBefore = engine.deadlineAdmissions.count
        let ordinaryBefore = engine.ordinarySubmissionCount
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "not-a-probe",
                firstContentDeadline: deadline())
        }
        #expect(engine.deadlineAdmissions.count == admissionsBefore + 1)
        #expect(engine.ordinarySubmissionCount == ordinaryBefore)
        #expect(await bridge._testConsecutiveDeadlineRefusals() == threshold + 1)
        await finishHeldRow(row)

        // Idle again: the probe fires now.
        let probe = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "probe",
            firstContentDeadline: deadline())
        #expect(engine.ordinarySubmissionCount == ordinaryBefore + 1)
        #expect(await bridge._testConsecutiveDeadlineRefusals() == 0)
        try await finishLatestSubmission(probe, engine: engine)
    }

    @Test("an admitted projection resets the refusal counter")
    func admissionResetsRefusalCounter() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.reject)
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "refused",
                firstContentDeadline: deadline())
        }
        #expect(await bridge._testConsecutiveDeadlineRefusals() == 1)

        engine.setDeadlineBehavior(.admit)
        let admitted = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "admitted",
            firstContentDeadline: deadline())
        #expect(engine.deadlineAdmissions.count == 2)
        #expect(await bridge._testConsecutiveDeadlineRefusals() == 0)
        try await finishLatestSubmission(admitted, engine: engine)
    }

    @Test("an unmeasured decode rate with rows running fails open instead of closed")
    func decodeRateNilWithRunningRowsFailsOpen() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        // Every seed emits exactly one token: the isolated prefill rate is
        // armed but the decode EWMA never initializes (no tokens after the
        // first emission).
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        #expect(await bridge.observedDecodeTpsEwma == 0)
        engine.setDeadlineBehavior(.reject)

        // With the engine idle the projection is bounded by prefill alone:
        // atomic admission still applies (and here refuses).
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "idle-refused",
                firstContentDeadline: deadline())
        }
        #expect(engine.deadlineAdmissions.count == 1)

        // A row is now running; its decode phase cannot be priced, so the
        // engine would return `.unbounded` and refuse every arrival. Fail
        // open: ordinary submission, no atomic call.
        let row = await holdOpenRow(bridge: bridge, engine: engine, requestId: "running-row")
        #expect(await bridge._testCounters().active == 1)
        let ordinaryBefore = engine.ordinarySubmissionCount

        let arrival = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "arrival-while-running",
            firstContentDeadline: deadline())
        #expect(engine.deadlineAdmissions.count == 1)
        #expect(engine.ordinarySubmissionCount == ordinaryBefore + 1)
        #expect(await bridge._testConsecutiveDeadlineRefusals() == 0)

        try await finishLatestSubmission(arrival, engine: engine)
        await finishHeldRow(row)
    }

    @Test("a running multimodal peer row fails the text arrival open (the engine cannot price its steps)")
    func multimodalPeerFailsOpen() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        try await recordDecodeRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.reject)

        // Image request A is active (its own submission fails open — media).
        let image = await holdOpenRow(
            bridge: bridge, engine: engine, requestId: "image-request",
            multimodal: CBv2MultimodalInput(spans: [], embeddings: { [] }))
        #expect(await bridge._testCounters().active == 1)
        let ordinaryBefore = engine.ordinarySubmissionCount

        // Text request B with a 9 s deadline: submitted ordinarily, not
        // refused within ~50 ms on an `.unbounded` verdict.
        let text = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "text-behind-image",
            firstContentDeadline: deadline(budgetMilliseconds: 9_000))
        #expect(engine.deadlineAdmissions.isEmpty)
        #expect(engine.ordinarySubmissionCount == ordinaryBefore + 1)
        try await finishLatestSubmission(text, engine: engine)
        await finishHeldRow(image)

        // Once the media row is gone, projection resumes.
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "text-alone",
                firstContentDeadline: deadline(budgetMilliseconds: 9_000))
        }
        #expect(engine.deadlineAdmissions.count == 1)
    }

    @Test("a full batch fails open: the request waits under the engine's admission lease instead of a projected refusal")
    func fullBatchFailsOpen() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce, maxConcurrentRequests: 1)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        try await recordDecodeRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.reject)

        let row = await holdOpenRow(bridge: bridge, engine: engine, requestId: "occupant")
        #expect(await bridge._testCounters().active == 1)
        let ordinaryBefore = engine.ordinarySubmissionCount
        let queued = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "queued-behind-full-batch",
            firstContentDeadline: deadline())
        #expect(engine.deadlineAdmissions.isEmpty)
        #expect(engine.ordinarySubmissionCount == ordinaryBefore + 1)
        try await finishLatestSubmission(queued, engine: engine)
        await finishHeldRow(row)

        // Batch has room again: projection resumes.
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "room-again",
                firstContentDeadline: deadline())
        }
        #expect(engine.deadlineAdmissions.count == 1)
    }

    /// Record one decode-rate sample (three tokens across a 20 ms window)
    /// so the decode EWMA is initialized and the decode-nil fail-open cannot
    /// mask the posture under test.
    private func recordDecodeRate(
        bridge: EngineV2Bridge,
        engine: PrefillScriptEngine
    ) async throws {
        let decodeRequest = ChatCompletionRequest(
            model: "gpt-oss-20b",
            messages: [ChatMessage(role: "user", content: "hi")],
            max_tokens: 3)
        let stream = await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: decodeRequest,
            requestId: "measure-decode-\(UUID().uuidString.prefix(6))")
        let consumer = Task { for await _ in stream {} }
        let continuation = try #require(engine.continuations.last)
        continuation.yield(.delta(text: "a", tokens: [11], logprobs: nil))
        try await Task.sleep(for: .milliseconds(20))
        continuation.yield(.delta(text: "bc", tokens: [12, 13], logprobs: nil))
        continuation.yield(.finished(
            reason: .stop,
            usage: CBv2Usage(promptTokens: promptTokens.count, completionTokens: 3)))
        continuation.finish()
        _ = await consumer.value
        #expect(await bridge.observedDecodeTpsEwma > 0)
    }

    @Test("expired requests never ordinary-submit through fail-open branches")
    func expiredRequestsNeverFailOpen() async throws {
        let expired = deadline(budgetMilliseconds: 0, elapsedMilliseconds: 1)

        // One explicit case per fail-open branch of
        // `firstTokenDeadlineAdmission`: the absolute expiry is enforced by
        // the caller before projection policy is even consulted.

        // Below the isolated-sample floor.
        let floorEngine = PrefillScriptEngine()
        let floorBridge = makeBridge(engine: floorEngine, mode: .enforce)
        try await recordIsolatedColdSample(
            bridge: floorBridge, engine: floorEngine, requestId: "one-seed")
        #expect(await floorBridge._testIsolatedPrefillSampleCount() < sampleFloor)
        let ordinaryBeforeFloor = floorEngine.ordinarySubmissionCount
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await floorBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-below-floor",
                firstContentDeadline: expired)
        }
        #expect(floorEngine.ordinarySubmissionCount == ordinaryBeforeFloor)

        // Probe due (three refusals at an isolated boundary).
        let probeEngine = PrefillScriptEngine()
        let probeBridge = makeBridge(engine: probeEngine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: probeBridge, engine: probeEngine)
        probeEngine.setDeadlineBehavior(.reject)
        for index in 0 ..< EngineV2Bridge.deadlineRefusalProbeThreshold {
            await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
                _ = try await probeBridge.submitTokenized(
                    promptTokens: promptTokens,
                    request: request,
                    requestId: "refused-\(index)",
                    firstContentDeadline: deadline())
            }
        }
        let ordinaryBeforeProbe = probeEngine.ordinarySubmissionCount
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await probeBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-probe",
                firstContentDeadline: expired)
        }
        #expect(probeEngine.ordinarySubmissionCount == ordinaryBeforeProbe)

        // Decode rate unmeasured with a row running.
        let decodeNilEngine = PrefillScriptEngine()
        let decodeNilBridge = makeBridge(engine: decodeNilEngine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: decodeNilBridge, engine: decodeNilEngine)
        let decodeNilRow = await holdOpenRow(
            bridge: decodeNilBridge, engine: decodeNilEngine, requestId: "row")
        let ordinaryBeforeDecodeNil = decodeNilEngine.ordinarySubmissionCount
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await decodeNilBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-decode-nil",
                firstContentDeadline: expired)
        }
        #expect(decodeNilEngine.ordinarySubmissionCount == ordinaryBeforeDecodeNil)
        await finishHeldRow(decodeNilRow)

        // Multimodal peer row running.
        let peerEngine = PrefillScriptEngine()
        let peerBridge = makeBridge(engine: peerEngine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: peerBridge, engine: peerEngine)
        let peerRow = await holdOpenRow(
            bridge: peerBridge, engine: peerEngine, requestId: "image-row",
            multimodal: CBv2MultimodalInput(spans: [], embeddings: { [] }))
        let ordinaryBeforePeer = peerEngine.ordinarySubmissionCount
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await peerBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-behind-image",
                firstContentDeadline: expired)
        }
        #expect(peerEngine.ordinarySubmissionCount == ordinaryBeforePeer)
        await finishHeldRow(peerRow)

        // Full batch.
        let fullEngine = PrefillScriptEngine()
        let fullBridge = makeBridge(engine: fullEngine, mode: .enforce, maxConcurrentRequests: 1)
        _ = try await measureColdPrefillRate(bridge: fullBridge, engine: fullEngine)
        let occupant = await holdOpenRow(bridge: fullBridge, engine: fullEngine, requestId: "occupant")
        let ordinaryBeforeFull = fullEngine.ordinarySubmissionCount
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await fullBridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "expired-full-batch",
                firstContentDeadline: expired)
        }
        #expect(fullEngine.ordinarySubmissionCount == ordinaryBeforeFull)
        await finishHeldRow(occupant)

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

    // MARK: - The refusal carries the engine's projection (T2-02)

    private func makeProfile() -> RequestProfileBuilder {
        let profile = RequestProfileBuilder()
        profile.update { f, now in f.mark(.dequeued, offsetUs: now) }
        profile.mark(.acceptedSent)
        return profile
    }

    @Test("a bounded refusal stamps projected_* and the remaining budget on the profile, never engine_admitted")
    func boundedRefusalStampsProjection() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.reject)
        let profile = makeProfile()

        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "bounded-refusal",
                firstContentDeadline: deadline(budgetMilliseconds: 9_000),
                profile: profile)
        }
        let wire = profile.wireObject()
        #expect(wire.deadlineMode == .projected)
        #expect(wire.engineSubmitUs != nil)
        #expect(wire.engineAdmittedUs == nil, "a refusal is not an admission")
        #expect(wire.projectedPrefillTokens == Int64(promptTokens.count))
        #expect(wire.projectedDecodeTokens == 0)
        #expect(wire.projectedServiceUs == 1_000, "the script's 1 ms projection")
        let remaining = try #require(wire.budgetRemainingAtAdmitUs)
        #expect(remaining >= 0 && remaining <= 9_000_000)
        #expect(wire.tokensAfterCancel == nil)
        // The bridge retains nothing for the refused request.
        #expect(await bridge._testPendingProfileCount() == 0)
        #expect(await bridge._testCounters().active == 0)
    }

    @Test("an unbounded refusal stamps only the remaining budget (no finite projection exists)")
    func unboundedRefusalStampsBudgetOnly() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        engine.setDeadlineBehavior(.rejectUnbounded)
        let profile = makeProfile()

        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(
                promptTokens: promptTokens,
                request: request,
                requestId: "unbounded-refusal",
                firstContentDeadline: deadline(budgetMilliseconds: 9_000),
                profile: profile)
        }
        let wire = profile.wireObject()
        #expect(wire.deadlineMode == .projected)
        #expect(wire.engineAdmittedUs == nil)
        #expect(wire.projectedPrefillTokens == nil)
        #expect(wire.projectedDecodeTokens == nil)
        #expect(wire.projectedServiceUs == nil)
        let remaining = try #require(wire.budgetRemainingAtAdmitUs)
        #expect(remaining >= 0 && remaining <= 9_000_000)
        #expect(await bridge._testConsecutiveDeadlineRefusals() == 1)
    }

    @Test("an admitted projection still stamps projected_* with engine_admitted (the #809 admit path is unchanged)")
    func admitStampsProjectionUnchanged() async throws {
        let engine = PrefillScriptEngine()
        let bridge = makeBridge(engine: engine, mode: .enforce)
        _ = try await measureColdPrefillRate(bridge: bridge, engine: engine)
        let profile = makeProfile()

        let stream = try await bridge.submitTokenized(
            promptTokens: promptTokens,
            request: request,
            requestId: "admitted-with-profile",
            firstContentDeadline: deadline(budgetMilliseconds: 9_000),
            profile: profile)
        let wire = profile.wireObject()
        #expect(wire.deadlineMode == .projected)
        let submit = try #require(wire.engineSubmitUs)
        let admitted = try #require(wire.engineAdmittedUs)
        #expect(submit <= admitted)
        #expect(wire.projectedPrefillTokens == Int64(promptTokens.count))
        #expect(wire.projectedDecodeTokens == 0)
        #expect(wire.projectedServiceUs == 1_000)
        #expect(wire.budgetRemainingAtAdmitUs != nil)
        try await finishLatestSubmission(stream, engine: engine)
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
