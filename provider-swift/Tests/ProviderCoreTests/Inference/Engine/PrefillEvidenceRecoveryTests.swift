import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Expired prefill evidence recovery", .serialized)
struct PrefillEvidenceRecoveryTests {
    private let prompt = Array(repeating: 1, count: 384)
    private let request = ChatCompletionRequest(model: "recovery-fixture", messages: [], max_tokens: 1)

    private func projectionEngine() -> EngineV2 {
        let model = DeadlineAdmissionFixtureModel()
        return EngineV2(model: model, layerKinds: model.kinds,
            backend: CBv2ContiguousKVBackend(config: .init(bytesCapacity: 1 << 20)),
            cacheProvider: CBv2LayerCacheBank(layerKinds: model.kinds),
            sampler: CBv2GreedySampler(), schedulerConfig: .init(
                maxConcurrentRequests: 1, maxBatchedTokensPerStep: 64,
                prefillChunkSize: 64, maxConcurrentPartialPrefills: 1,
                maxWaiting: 4, enablePrefixCache: false))
    }

    private func fixture(gate: RecoveryStepGate? = nil, watchdog: Bool = false,
        reservationDelay: Double = 0, reservationGate: RecoveryStepGate? = nil,
        decodeGate: RecoveryStepGate? = nil) throws
        -> (EngineV2Bridge, CBv2NativeBlockEngine, GlobalKVCacheBudget) {
        let tokenizer = PrefillStubTokenizer()
        let delay = RecoveryReservationDelay(seconds: reservationDelay, gate: reservationGate)
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 1 << 20,
            shutdownGraceSeconds: 0,
            loopConfig: .init(stepTimeout: watchdog ? 0.1 : 60, watchdogInterval: 0.01),
            reservationForRequest: { _ in
                delay.observe()
                return 1_024
            }, makeSession: { request, cancellation in
                RecoverySession(tokens: request.promptTokens.count, cancellation: cancellation,
                    gate: gate, decodeGate: decodeGate)
            })
        let budget = GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let bridge = EngineV2Bridge(engine: engine, modelId: "recovery-fixture",
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [],
            prefillDeadlineMode: .enforce, kvBytesPerToken: 1, kvBudget: budget)
        return (bridge, engine, budget)
    }

    private func drain(_ stream: AsyncStream<GenerationEvent>) async -> [String] {
        var errors = [String]()
        for await event in stream {
            if case .error(let error) = event { errors.append(error) }
        }
        return errors
    }

    private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(3)
        while !(await predicate()), ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(2)) }
        try #require(await predicate())
    }

    @Test("production-shaped idle M5 refusal recovers with an actual cold sample")
    func oldSlowRateDoesNotPermanentlyRejectShortPrompts() async throws {
        let (bridge, engine, budget) = try fixture()
        await bridge.seedExpiredRecoveryRate()
        // Device cleanup before engine submission must not permanently veto
        // recovery; the measured isolation interval starts after preparation.
        await bridge._testInstallPreSubmitGate {
            let activity = budget.serviceBudget.beginUnboundedActivity()
            activity.finish()
        }
        let original = FirstContentDeadline(relativeBudgetMilliseconds: 9_326)
        let profile = RequestProfileBuilder()
        // The former 6.103-TPS policy predicts 62.9 s and refuses this prompt.
        let oldEngine = projectionEngine()
        let denied = try await oldEngine.submit(.init(id: .init(99), promptTokens: prompt, maxTokens: 1),
            firstTokenDeadline: .init(deadline: original.instant,
                conservativePrefillTokensPerSecond: 6.103282279,
                conservativeDecodeTokensPerSecond: 61.59))
        guard case .deadlineUnreachable(.bounded(let work, let duration)) = denied else {
            await oldEngine.shutdown()
            Issue.record("old measured policy must refuse a bounded projection"); return
        }
        #expect(work.prefillTokens == 384 && duration > .seconds(62))
        await oldEngine.shutdown()
        #expect(engine.capacity().activeRequests == 0)

        let stream = try await bridge.submitTokenized(promptTokens: prompt, request: request,
            requestId: "recover", cacheEnabled: false, firstContentDeadline: original, profile: profile)
        let errors = await drain(stream)
        #expect(errors.isEmpty)
        try await eventually { budget.serviceBudget.count == 0 }
        let renewed = await bridge.backendSlotCapacity()
        let sample = try #require(renewed.performanceMeasurements?.isolatedPrefill)
        #expect(sample.sampleCount == 2)
        #expect(sample.tokensPerSecond > 100 && sample.tokensPerSecond <= 20_000)
        #expect(renewed.observedPrefillTps == sample.tokensPerSecond)
        #expect(await bridge._testIsolatedPrefillTps() == sample.tokensPerSecond)
        #expect(profile.wireObject().deadlineDecision?.prefillTps == nil)
        #expect(profile.wireObject().deadlineDecision?.verdict == .accepted)
        let next = try #require(await bridge.firstTokenDeadlineAdmission(
            deadline: original, isMultimodal: false))
        #expect(next.deadline == original.instant)
        #expect(next.conservativePrefillTokensPerSecond == sample.tokensPerSecond)
        let renewedEngine = projectionEngine()
        let accepted = try await renewedEngine.submit(.init(id: .init(100), promptTokens: prompt, maxTokens: 1),
            firstTokenDeadline: next)
        guard case .admitted(let events, .bounded(_, let duration), _, let retirement) = accepted else {
            await renewedEngine.shutdown()
            await bridge.shutdown()
            Issue.record("the real renewed policy must admit this original deadline"); return
        }
        #expect(duration < .seconds(4))
        for await _ in events {}
        await retirement.wait()
        await renewedEngine.shutdown()
        #expect(await budget.outstandingReservedBytes() == 0)
        await bridge.shutdown()
    }

    @Test("busy, loading, media, large and expired requests never get recovery")
    func recoveryKeepsItsAdmissionBounds() async throws {
        let (bridge, engine, budget) = try fixture()
        await bridge.seedExpiredRecoveryRate()
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 9_326)
        #expect(await bridge.canRecoverPrefillEvidence(promptTokens: 384, deadline: deadline, isMultimodal: false))
        #expect(await !bridge.canRecoverPrefillEvidence(promptTokens: 1_025, deadline: deadline, isMultimodal: false))
        #expect(await !bridge.canRecoverPrefillEvidence(promptTokens: 384, deadline: deadline, isMultimodal: true))
        #expect(await !bridge.canRecoverPrefillEvidence(promptTokens: 384, deadline: nil, isMultimodal: false))
        let ordinary = try #require(await bridge.firstTokenDeadlineAdmission(
            deadline: deadline, isMultimodal: false))
        #expect(ordinary.conservativePrefillTokensPerSecond == 6.103282279)
        #expect(ordinary.deadline == deadline.instant)

        #expect(budget.serviceBudget.acquire(ownerID: "another-model", concurrency: 4))
        #expect(!budget.serviceBudget.acquire(ownerID: "probe", concurrency: 1, requiresIdle: true))
        let busyProfile = RequestProfileBuilder()
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(promptTokens: prompt, request: request,
                requestId: "busy", firstContentDeadline: deadline, profile: busyProfile)
        }
        #expect(busyProfile.wireObject().deadlineDecision?.prefillTps == 6.103282279)
        #expect(await bridge.prefillEvidenceRecovery.owner == nil)
        budget.serviceBudget.release(ownerID: "another-model")
        let loading = budget.serviceBudget.beginUnboundedActivity()
        #expect(!budget.serviceBudget.acquire(ownerID: "probe", concurrency: 1, requiresIdle: true))
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(promptTokens: prompt, request: request,
                requestId: "loading", firstContentDeadline: deadline)
        }
        #expect(await bridge.prefillEvidenceRecovery.owner == nil)
        loading.finish()

        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 1_025),
                request: request, requestId: "large", firstContentDeadline: deadline)
        }
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(promptTokens: prompt, request: request,
                requestId: "expired", firstContentDeadline: .init(relativeBudgetMilliseconds: 0))
        }
        #expect(engine.capacity().activeRequests == 0)
        #expect(budget.serviceBudget.count == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge.prefillEvidenceRecovery.available(), "an already expired request never starts a recovery")
        await bridge.shutdown()
    }

    @Test("failed probe retains exclusivity through watchdog terminal and backs off after retirement")
    func watchdogTerminalCannotReleaseRecoveryOwnership() async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (bridge, engine, budget) = try fixture(gate: gate, watchdog: true)
        await bridge.seedExpiredRecoveryRate()
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 9_326)
        let stream = try await bridge.submitTokenized(promptTokens: prompt, request: request,
            requestId: "blocked", cacheEnabled: false, firstContentDeadline: deadline)
        let consumer = Task { await drain(stream) }
        try await eventually { gate.entered }
        _ = await consumer.value
        #expect(budget.serviceBudget.usedFraction == 1)
        #expect(await bridge.prefillEvidenceRecovery.owner == "blocked")
        #expect(!budget.serviceBudget.acquire(ownerID: "another-model", concurrency: 4))
        #expect(await budget.outstandingReservedBytes() > 0)
        gate.release()
        try await eventually { budget.serviceBudget.count == 0 }
        #expect(await bridge.prefillEvidenceRecovery.owner == nil)
        #expect(await !bridge.prefillEvidenceRecovery.available())
        #expect(await bridge.prefillEvidenceRecovery.available(at: .now + .seconds(121)))
        #expect(await bridge._testIsolatedPrefillTps() == 6.103282279)
        #expect(engine.capacity().kvBytesReserved == 0)
        #expect(await budget.outstandingReservedBytes() == 0)
        await bridge.shutdown()
    }

    @Test("submission elapsed time cannot restart a recovery request's deadline")
    func originalDeadlineSurvivesRecoverySubmission() async throws {
        let (bridge, _, budget) = try fixture(reservationDelay: 0.2)
        await bridge.seedExpiredRecoveryRate()
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 100)
        let profile = RequestProfileBuilder()
        let signal = EngineV2RequestUsageSignal()
        await #expect(throws: PreContentDeadlineFailure.deadlineUnreachable) {
            _ = try await bridge.submitTokenized(promptTokens: prompt, request: request,
                requestId: "expires-during-submit", cacheEnabled: true, usageSignal: signal,
                firstContentDeadline: deadline, profile: profile)
        }
        #expect(profile.wireObject().deadlineDecision?.continuation == .expired)
        try await eventually { budget.serviceBudget.count == 0 }
        #expect(await bridge.prefillEvidenceRecovery.owner == nil)
        #expect(await budget.outstandingReservedBytes() == 0)
        #expect(await bridge._testPendingSubmissionCount() == 0)
        #expect(signal.lookupResult?.outcome == .skippedCapacity)
        await bridge.shutdown()
    }

    @Test("device activity cannot race the final idle check and native registration")
    func idleCheckAndNativeRegistrationShareOneLock() async throws {
        let registration = RecoveryStepGate(), prefill = RecoveryStepGate()
        defer { registration.release(); prefill.release() }
        let (bridge, _, budget) = try fixture(gate: prefill, reservationGate: registration)
        await bridge.seedExpiredRecoveryRate()
        let submit = Task {
            try await bridge.submitTokenized(promptTokens: prompt, request: request,
                requestId: "atomic-idle", cacheEnabled: false,
                firstContentDeadline: .init(relativeBudgetMilliseconds: 9_326))
        }
        try await eventually { registration.entered }
        let attempt = RecoveryActivityAttempt()
        DispatchQueue.global().async {
            attempt.markAttempted()
            let activity = budget.serviceBudget.beginUnboundedActivity()
            attempt.markStarted()
            activity.finish()
        }
        try await eventually { attempt.attempted }
        #expect(!attempt.started, "activity must wait until native registration commits")
        registration.release()
        let stream = try await submit.value
        try await eventually { attempt.started && prefill.entered }
        prefill.release()
        _ = await drain(stream)
        try await eventually { budget.serviceBudget.count == 0 }
        #expect(await bridge._testIsolatedPrefillTps() == 6.103282279,
            "activity after commit still invalidates the isolated measurement")
        await bridge.shutdown()
    }

    @Test("a long completion restores ordinary concurrency after prefill while retaining retirement ownership")
    func completedPrefillDoesNotMonopolizeLongDecode() async throws {
        let decode = RecoveryStepGate()
        defer { decode.release() }
        let (bridge, _, budget) = try fixture(decodeGate: decode)
        await bridge.seedExpiredRecoveryRate()
        let longRequest = ChatCompletionRequest(model: "recovery-fixture", messages: [], max_tokens: 8_192)
        let stream = try await bridge.submitTokenized(promptTokens: prompt, request: longRequest,
            requestId: "long-output", cacheEnabled: false,
            firstContentDeadline: .init(relativeBudgetMilliseconds: 9_326))
        let consumer = Task { await drain(stream) }
        let ordinaryFraction = 1 / Double(ServingPerformanceProfiles.legacyWholeMacConcurrency)
        try await eventually { decode.entered && budget.serviceBudget.usedFraction == ordinaryFraction }
        #expect(budget.serviceBudget.count == 1)
        #expect(await bridge.prefillEvidenceRecovery.owner == "long-output")
        #expect(await budget.outstandingReservedBytes() > 0)
        #expect(budget.serviceBudget.acquire(ownerID: "other-model", concurrency: 4))
        budget.serviceBudget.release(ownerID: "other-model")
        await bridge.cancel(requestId: "long-output")
        #expect(budget.serviceBudget.count == 1, "cancellation cannot refund the blocked decode owner's lease")
        decode.release()
        _ = await consumer.value
        try await eventually { budget.serviceBudget.count == 0 }
        #expect(await budget.outstandingReservedBytes() == 0)
        await bridge.shutdown()
    }

    @Test("unbounded activity invalidates a recovery receipt rather than manufacturing isolated evidence")
    func interruptedRecoveryDoesNotTrainIsolatedRate() throws {
        let service = WholeMacServiceBudget()
        #expect(service.acquire(ownerID: "probe", concurrency: 1, requiresIdle: true))
        let guardValue = try #require(service.exclusiveEvidenceGuard(ownerID: "probe"))
        let receipt = EnginePrefillReceipt(activity: EngineMeasurementActivity(), model: "model",
            isolationGuard: guardValue)
        let loading = service.beginUnboundedActivity()
        loading.finish()
        #expect(!guardValue.isValid)
        receipt.complete(.init(promptTokens: 384, completionTokens: 0))
        #expect(try #require(receipt.take()).overlap.contended)
        receipt.end()
        service.release(ownerID: "probe")
    }

    @Test("loading at the final boundary withdraws recovery and keeps its receipt contended")
    func missingFinalGuardCannotLookIsolated() throws {
        let service = WholeMacServiceBudget()
        #expect(service.acquire(ownerID: "probe", concurrency: 1, requiresIdle: true))
        var recovery = PrefillEvidenceRecovery()
        recovery.acquire("probe", evidenceGuard: nil)
        let loading = service.beginUnboundedActivity()
        #expect(service.exclusiveEvidenceGuard(ownerID: "probe") == nil)
        recovery.bindEvidenceGuard(service.exclusiveEvidenceGuard(ownerID: "probe"), ownerID: "probe")
        let guardValue = try #require(recovery.evidenceGuard)
        #expect(!guardValue.isValid)
        var submitted = false
        let result = service.withExclusiveEvidence(ownerID: "probe", guardValue: guardValue) {
            submitted = true
            return true
        }
        #expect(result == nil && !submitted)
        let receipt = EnginePrefillReceipt(activity: EngineMeasurementActivity(), model: "model",
            isolationGuard: guardValue)
        loading.finish()
        receipt.complete(.init(promptTokens: 384, completionTokens: 0))
        #expect(try #require(receipt.take()).overlap.contended)
        receipt.end()
        service.release(ownerID: "probe")
    }

    @Test("a reused prefix does not clear recovery backoff or renew the cold estimate")
    func cachedWorkCannotRenewColdEvidence() async throws {
        let (bridge, _, _) = try fixture()
        await bridge.seedExpiredRecoveryRate()
        #expect(await bridge.acquireServiceAllowance(requestID: "cached", recoverPrefillEvidence: true))
        await bridge.beginRecoverySubmissionForTest("cached")
        let receipt = EnginePrefillReceipt(activity: EngineMeasurementActivity(), model: "recovery-fixture")
        var usage = CBv2Usage(promptTokens: 384, completionTokens: 0, prefixCacheOutcome: .hit,
            prefixCacheMatchedTokens: 256, prefixCachePrefillTokensSaved: 256)
        var timing = CBv2RequestTiming()
        timing.prefillFirstLaunchNanos = 1_000_000
        timing.promptComputedNanos = 101_000_000
        usage.timing = timing
        receipt.complete(usage)
        await bridge.consumePrefillReceipt(id: "cached", receipt: receipt)
        let snapshot = await bridge.backendSlotCapacity()
        #expect(snapshot.performanceMeasurements?.isolatedPrefill?.sampleCount == 1)
        #expect(await bridge._testIsolatedPrefillTps() == 6.103282279)
        #expect(snapshot.performanceMeasurements?.workloadBuckets.contains { $0.cacheState == "reused" } == true)
        await bridge.releaseServiceAllowance(requestID: "cached")
        #expect(await !bridge.prefillEvidenceRecovery.available())
        receipt.end()
        await bridge.shutdown()
    }
}

private extension EngineV2Bridge {
    func beginRecoverySubmissionForTest(_ id: String) { prefillEvidenceRecovery.beginSubmission(id) }

    func seedExpiredRecoveryRate() {
        let rate = 6.103282279
        updatePrefillTpsEwma(rate, isolated: true)
        updateDecodeTpsEwma(61.59)
        performanceMeasurements.observe("isolated_prefill", tps: rate, prompt: 384, context: 384,
            cache: "cold", overlap: .init(), at: .now - .seconds(1_200))
    }
}
