import Foundation
import MLXLMCommon
import Testing
@testable import ProviderCore

@Suite("Automatic model calibration", .serialized)
struct ModelCalibrationTests {
    private func fixture(budget: GlobalKVCacheBudget? = nil, gate: RecoveryStepGate? = nil,
        gateOnRequest: Int? = nil, deadlineProfile: DeadlinePerformanceProfile? = nil,
        posturePermitsWork: @escaping @Sendable () -> Bool = { true })
        throws -> (EngineV2Bridge, CBv2NativeBlockEngine, GlobalKVCacheBudget) {
        let tokenizer = ModelCalibrationTokenizer()
        let budget = budget ?? GlobalKVCacheBudget(capFraction: 0.9, activationReserveBytes: 0) {
            .init(total: 8 << 30, active: 0, cache: 0, systemAvailable: 8 << 30)
        }
        let sessionGate = ModelCalibrationSessionGate(gate: gate, requestNumber: gateOnRequest)
        let engine = try CBv2NativeBlockEngine(tokenizer: tokenizer, kvBytesCapacity: 1 << 20,
            maxConcurrentRequests: 4, shutdownGraceSeconds: 0,
            reservationForRequest: { _ in 1_024 }, makeSession: { request, cancellation in
                ModelCalibrationSession(request: request, cancellation: cancellation, gate: sessionGate.next())
            })
        let bridge = EngineV2Bridge(engine: engine, modelId: "mimo-calibration-fixture",
            tokenizer: TokenizerHandle(tokenizer), eosTokenIds: [], maxConcurrentRequests: 4,
            deadlineProfile: deadlineProfile, kvBytesPerToken: 1, kvBudget: budget,
            calibrationPosturePermitsWork: posturePermitsWork)
        return (bridge, engine, budget)
    }

    private func waitForEntry(_ gate: RecoveryStepGate) async throws {
        let until = ContinuousClock.now + .seconds(5)
        while !gate.entered && ContinuousClock.now < until {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(gate.entered)
        if !gate.entered { throw CancellationError() }
    }

    @Test("startup measurements seed heartbeats without billing/generation totals or warmup samples")
    func bootstrapUsesActualEngineReceipts() async throws {
        let (bridge, engine, budget) = try fixture()
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        await bridge.waitForCalibrationTest()
        let snapshot = await bridge.backendSlotCapacity()
        let measurements = try #require(snapshot.performanceMeasurements)
        #expect(measurements.isolatedPrefill?.sampleCount == 2)
        #expect(measurements.decode?.sampleCount == 2)
        #expect(measurements.workloadBuckets.contains { $0.phase == "prefill" && $0.promptTokenBucket == 1_024 })
        #expect(measurements.workloadBuckets.allSatisfy { $0.concurrentRequests == 1 })
        #expect(measurements.deliveredDecode == nil && measurements.endToEnd == nil)
        #expect(await bridge.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false,
            now: .now + .seconds(3_600))), "ordinary native models bootstrap once per loaded engine")
        await bridge.shutdown()
    }

    @Test("an early serving sample cannot suppress the first bounded bootstrap")
    func firstBootstrapRunsWithFreshServingRates() async throws {
        let (bridge, _, _) = try fixture()
        let stream = await bridge.submitTokenized(promptTokens: Array(repeating: 1, count: 512),
            request: ChatCompletionRequest(model: "early-job", messages: [], max_tokens: 32),
            requestId: "early-serving-sample", cacheEnabled: false)
        for await event in stream {
            if case .error(let error) = event { Issue.record("early request failed: \(error)") }
        }
        await bridge.waitForServingRetirementTest(requestId: "early-serving-sample")
        let before = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(before.isolatedPrefill != nil && before.decode != nil)
        let counters = await bridge.calibrationCountersTest()
        let started = await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)
        #expect(started)
        if started { await bridge.waitForCalibrationTest() }
        #expect(await bridge.calibrationRetryStateTest().0)
        #expect(await bridge.calibrationCountersTest() == counters)
        await bridge.shutdown()
    }

    @Test("a prefill callback consumed after cancelled-cell retirement remains calibration",
        arguments: [1, 2])
    func lateCancelledPrefillRetainsProvenance(requestNumber: Int) async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (bridge, engine, budget) = try fixture(gate: gate, gateOnRequest: requestNumber)
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        let (id, receipt) = try #require(await bridge.activeCalibrationReceiptTest())
        let task = await bridge.cancelModelCalibration()
        let until = ContinuousClock.now + .seconds(5)
        while !(await bridge.wasCalibrationInterruptedTest()), ContinuousClock.now < until {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await bridge.wasCalibrationInterruptedTest())
        gate.release()
        await task?.value
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        #expect(await bridge.pendingCalibrationEvidenceCountTest() == 0)
        let before = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        let counters = await bridge.calibrationCountersTest()

        // Deliver an unconsumed sample after cleanup to reproduce the ordering
        // seen when the callback's actor Task is delayed past retirement.
        var usage = CBv2Usage(promptTokens: 128, completionTokens: 0)
        usage.timing.prefillFirstLaunchNanos = 1_000_000
        usage.timing.promptComputedNanos = 21_000_000
        receipt.complete(usage)
        await bridge.consumePrefillReceipt(id: id, receipt: receipt)
        let after = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(after.isolatedPrefill?.sampleCount == before.isolatedPrefill?.sampleCount)
        #expect(after.contendedPrefill?.sampleCount == before.contendedPrefill?.sampleCount)
        #expect(after.workloadBuckets.count == before.workloadBuckets.count)
        #expect(await bridge.calibrationCountersTest() == counters)
        #expect(await bridge.pendingCalibrationEvidenceCountTest() == 0)
        await bridge.shutdown()
    }

    @Test("a final-cell posture change discards staged rates and permits a later bootstrap",
        arguments: [false, true])
    func finalCellPostureChangeDiscardsOnlyCalibration(servingEvidence: Bool) async throws {
        let posture = CalibrationPostureSwitch()
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (bridge, engine, budget) = try fixture(gate: gate, gateOnRequest: 3,
            posturePermitsWork: { posture.permitsWork })
        #expect(await bridge.startModelCalibrationIfNeeded())
        try await waitForEntry(gate)
        posture.setPermitsWork(false)
        if servingEvidence { await bridge.recordIndependentRateEvidenceTest() }
        let before = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(before.isolatedPrefill?.sampleCount == (servingEvidence ? 2 : 1))
        gate.release()
        await bridge.waitForCalibrationTest()
        let after = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(after.isolatedPrefill?.sampleCount == before.isolatedPrefill?.sampleCount)
        #expect(after.isolatedPrefill?.tokensPerSecond == before.isolatedPrefill?.tokensPerSecond)
        #expect(after.decode?.sampleCount == before.decode?.sampleCount)
        #expect(after.decode?.tokensPerSecond == before.decode?.tokensPerSecond)
        let (complete, retryAt) = await bridge.calibrationRetryStateTest()
        #expect(!complete)
        #expect(await bridge.pendingCalibrationEvidenceCountTest() == 0)
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        posture.setPermitsWork(true)
        #expect(await bridge.startModelCalibrationIfNeeded(now: try #require(retryAt)))
        await bridge.waitForCalibrationTest()
        #expect(await bridge.calibrationRetryStateTest().0)
        await bridge.shutdown()
    }

    @Test("MiMo calibration retains its wider bootstrap and later maintenance measurements")
    func continuousCalibrationKeepsWideEvidence() async throws {
        let (bridge, engine, budget) = try fixture()
        // Exercise the existing continuous plan under the same shared idle
        // owner, without fabricating a published MiMo native transaction.
        await bridge.runContinuousCalibrationTest(budget: budget)
        let first = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(first.workloadBuckets.contains { $0.promptTokenBucket == 4_096 })
        #expect(first.workloadBuckets.contains { ($0.concurrentRequests ?? 1) > 1 })
        let before = try #require(first.isolatedPrefill?.sampleCount)
        await bridge.runContinuousCalibrationTest(budget: budget)
        let second = try #require(await bridge.backendSlotCapacity().performanceMeasurements)
        #expect(second.isolatedPrefill?.sampleCount == before + 3)
        #expect(await bridge.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("legacy engines without native retirement never start background calibration")
    func legacyEngineIsExcluded() async throws {
        let engine = PrefillScriptEngine()
        let bridge = EngineV2Bridge(engine: engine, modelId: "legacy-fixture",
            tokenizer: TokenizerHandle(PrefillStubTokenizer()), eosTokenIds: [])
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        #expect(engine.ordinarySubmissionCount == 0)
        await bridge.shutdown()
    }

    @Test("deadline-profiled slots never let bounded probes qualify their reviewed timing envelope")
    func deadlineProfiledSlotIsExcluded() async throws {
        let (bridge, engine, budget) = try fixture(deadlineProfile: deadlineCalibrationProfileFixture())
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("requests on another model cancel calibration and wait for its actual native retirement")
    func foregroundPreemptsAcrossModels() async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (calibration, engine, budget) = try fixture(gate: gate)
        #expect(await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        await calibration.interruptModelCalibration(["calibration-already-retired"])
        #expect(!(await calibration.wasCalibrationInterruptedTest()))
        let (foreground, _, _) = try fixture(budget: budget)
        let observed = RecoveryActivityAttempt()
        let task = Task {
            let stream = await foreground.submitTokenized(promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: "other", messages: [], max_tokens: 8), requestId: "customer")
            for await event in stream {
                if case .error(let error) = event { Issue.record("foreground request failed: \(error)") }
            }
            observed.markStarted()
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!observed.started)
        #expect(engine.capacity().activeRequests > 0 && budget.serviceBudget.count == 1)
        gate.release()
        await task.value
        #expect(observed.started)
        #expect(await calibration.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(await foreground.calibrationCountersTest() == [3, 1, 8, 1])
        await calibration.shutdown()
        await foreground.shutdown()
    }

    @Test("an interrupted partial bootstrap retries at its backoff even with fresh rates")
    func partialBootstrapRetriesWithFreshEvidence() async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        // Finish the warmup and first measured request, then hold the second
        // measurement in actual engine work until foreground cancellation.
        let (calibration, engine, budget) = try fixture(gate: gate, gateOnRequest: 3)
        #expect(await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        let partial = try #require(await calibration.backendSlotCapacity().performanceMeasurements)
        #expect(partial.isolatedPrefill?.sampleCount == 1)
        #expect(partial.decode?.sampleCount == 1)

        let (foreground, _, _) = try fixture(budget: budget)
        let request = Task {
            let stream = await foreground.submitTokenized(promptTokens: [1, 2, 3],
                request: ChatCompletionRequest(model: "other", messages: [], max_tokens: 8),
                requestId: "interrupt-partial-bootstrap")
            for await event in stream {
                if case .error(let error) = event { Issue.record("foreground request failed: \(error)") }
            }
        }
        let until = ContinuousClock.now + .seconds(5)
        while !(await calibration.wasCalibrationInterruptedTest()), ContinuousClock.now < until {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(await calibration.wasCalibrationInterruptedTest())
        gate.release()
        await request.value
        await calibration.waitForCalibrationTest()
        let (complete, nextAttempt) = await calibration.calibrationRetryStateTest()
        #expect(!complete)
        let retryAt = try #require(nextAttempt)
        #expect(!(await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false,
            now: retryAt - .nanoseconds(1))))
        let restarted = await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false,
            now: retryAt)
        #expect(restarted, "partial fresh evidence must not postpone the scheduled retry")
        if restarted {
            await calibration.waitForCalibrationTest()
            let finished = try #require(await calibration.backendSlotCapacity().performanceMeasurements)
            #expect(finished.isolatedPrefill?.sampleCount == 3)
            #expect(finished.decode?.sampleCount == 3)
            #expect(await calibration.calibrationRetryStateTest().0)
            #expect(!(await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false,
                now: retryAt + .seconds(3_600))), "a completed ordinary bootstrap must not repeat")
        }
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        #expect(await calibration.calibrationCountersTest() == [0, 0, 0, 0])
        await calibration.shutdown()
        await foreground.shutdown()
    }

    @Test("native model startup calibration respects active work and shutdown")
    func admissionAndLifecycleBounds() async throws {
        let (bridge, _, budget) = try fixture()
        #expect(budget.serviceBudget.acquire(ownerID: "busy", concurrency: 24))
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        budget.serviceBudget.release(ownerID: "busy")
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        await bridge.stopModelCalibration()
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
        #expect(budget.serviceBudget.count == 0)
        await bridge.shutdown()
    }

    @Test("shutdown retains calibration's service charge until the native step completes")
    func shutdownWaitsForActualRetirement() async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (bridge, engine, budget) = try fixture(gate: gate)
        #expect(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        let completed = RecoveryActivityAttempt()
        let shutdown = Task { await bridge.shutdown(); completed.markStarted() }
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!completed.started)
        #expect(engine.capacity().activeRequests > 0 && budget.serviceBudget.count == 1)
        gate.release()
        await shutdown.value
        #expect(completed.started && budget.serviceBudget.count == 0)
        #expect(await bridge.calibrationCountersTest() == [0, 0, 0, 0])
        #expect(!(await bridge.startModelCalibrationIfNeeded(requireNominalPosture: false)))
    }

    @Test("calibration retirement preserves the original deadline and cancellation diagnostics", arguments: [false, true])
    func foregroundKeepsOriginalDeadline(cancel: Bool) async throws {
        let gate = RecoveryStepGate()
        defer { gate.release() }
        let (calibration, _, budget) = try fixture(gate: gate)
        #expect(await calibration.startModelCalibrationIfNeeded(requireNominalPosture: false))
        try await waitForEntry(gate)
        let (foreground, engine, _) = try fixture(budget: budget)
        let deadline = FirstContentDeadline(relativeBudgetMilliseconds: 10)
        let profile = RequestProfileBuilder()
        let request = Task { () -> DeadlineVerdict? in
            do {
                _ = try await foreground.submitTokenized(promptTokens: [1, 2, 3],
                    request: ChatCompletionRequest(model: "other", messages: [], max_tokens: 8),
                    requestId: "deadline-customer", firstContentDeadline: deadline, profile: profile)
                Issue.record("expired foreground request was admitted")
                return nil
            } catch is CancellationError {
                return .cancelled
            } catch is PreContentDeadlineFailure {
                return .expiredBeforeSubmit
            } catch {
                Issue.record("unexpected foreground failure: \(error)")
                return nil
            }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        if cancel { request.cancel() }
        gate.release()
        let expected: DeadlineVerdict = cancel ? .cancelled : .expiredBeforeSubmit
        #expect(await request.value == expected)
        #expect(profile.wireObject().deadlineDecision?.verdict == expected)
        #expect(profile.wireObject().deadlineDecision?.projectedServiceUs == nil)
        #expect(engine.capacity().activeRequests == 0 && budget.serviceBudget.count == 0)
        #expect(await foreground.calibrationCountersTest() == [0, 0, 0, 0])
        await calibration.shutdown()
        await foreground.shutdown()
    }

    @Test("prompt sizing keeps complete role framing and actual prepared token bounds")
    func completeTemplates() async throws {
        let (bridge, _, _) = try fixture()
        for target in [128, 512, 4_096] {
            let tokens = try await bridge.modelCalibrationPrompt(targetTokens: target, variant: 1)
            #expect(tokens.count <= target && tokens.count > target / 2)
            #expect(tokens.first == 1 && tokens.last == 2)
        }
        await bridge.shutdown()
    }

    @Test("prompt sizing returns the largest complete prompt within each target")
    func promptSizingIsMaximal() async throws {
        let (bridge, _, _) = try fixture()
        for variant in 0..<2 {
            var previous = 0
            for target in [128, 300, 512, 777, 1_024, 2_048, 4_096, 4_796, 6_000] {
                let count = try await bridge.modelCalibrationPrompt(targetTokens: target, variant: variant).count
                #expect(count <= target && count >= previous)
                // One fixture repetition is under 128 tokens; an exact fit is a fixed point.
                #expect(count > target - 128, "variant \(variant), target \(target): \(count)")
                let refit = try await bridge.modelCalibrationPrompt(targetTokens: count, variant: variant)
                #expect(refit.count == count)
                previous = count
            }
        }
        await bridge.shutdown()
    }
}

private extension EngineV2Bridge {
    func activeCalibrationReceiptTest() -> (String, EnginePrefillReceipt)? {
        guard let id = modelCalibration.requests.keys.first,
            let receipt = active[id]?.prefillReceipt else { return nil }
        return (id, receipt)
    }

    func recordIndependentRateEvidenceTest() {
        for phase in ["isolated_prefill", "decode"] {
            recordRateObservation(EngineRateObservation(phase: phase, tps: 4_321,
                prompt: 512, context: 544, cache: "cold", overlap: .init(), at: .now,
                postureEpoch: nil, aggregate: true), requestID: "independent-serving-evidence")
        }
    }

    func pendingCalibrationEvidenceCountTest() -> Int { modelCalibration.pendingObservations.count }

    func waitForServingRetirementTest(requestId: String) async {
        await pumpTasks[requestId]?.value
    }

    func runContinuousCalibrationTest(budget: GlobalKVCacheBudget) async {
        let task = budget.serviceBudget.idleCalibration.startIfIdle(isIdle: { budget.serviceBudget.isIdle }) {
            await self.runModelCalibration(continuous: true, requireNominalPosture: false)
        }
        #expect(task != nil)
        await task?.value
    }
    func waitForCalibrationTest() async { await modelCalibration.task?.value }
    func wasCalibrationInterruptedTest() -> Bool { modelCalibration.interrupted }
    func calibrationRetryStateTest() -> (Bool, ContinuousClock.Instant?) {
        (modelCalibration.bootstrapCompleted, modelCalibration.nextAttempt)
    }
    func calibrationCountersTest() -> [Int64] {
        [prefillTokensTotal, prefillRequestsTotal, generatedTokensTotal, generationRequestsTotal]
    }
}

private final class CalibrationPostureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    var permitsWork: Bool { lock.withLock { allowed } }
    func setPermitsWork(_ value: Bool) { lock.withLock { allowed = value } }
}
